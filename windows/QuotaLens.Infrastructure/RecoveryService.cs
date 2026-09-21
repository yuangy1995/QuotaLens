using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

/// <summary>Explicit recoverable moves, not permanent deletion and not a simulated Windows Recycle Bin.
/// A durable intent record is written before the file move. Cross-volume and linked paths are refused.</summary>
public sealed class RecoveryService(LocalDatabase database, UsageIndexer indexer)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public string Root => Path.Combine(database.Root, "Recovery");
    public async Task<TrashEntry> MoveAsync(SourceCheckpoint requested, CancellationToken ct)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (requested.Provider != Provider.Codex) throw new NotSupportedException("Only Codex source-file recovery is supported.");
            var source = (await database.SourcesAsync(Provider.Codex, ct).ConfigureAwait(false)).FirstOrDefault(x => x.Id == requested.Id);
            if (source is null || !string.Equals(source.Path, requested.Path, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The selected source is no longer indexed.");
            string original = SecureFiles.RequireRegularFile(source.Path);
            if (!original.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("A JSONL source is required.");
            if (!string.Equals(Path.GetPathRoot(original), Path.GetPathRoot(Root), StringComparison.OrdinalIgnoreCase))
                throw new QuotaException(FailureKind.Storage, "This source is on another volume. It was not moved; no permanent-delete fallback is used.");
            var info = new FileInfo(original);
            if (info.Length != source.Length || info.LastWriteTimeUtc.Ticks != source.LastWriteTicks ||
                DateTime.UtcNow - info.LastWriteTimeUtc < TimeSpan.FromSeconds(10))
                throw new QuotaException(FailureKind.Storage, "The source is active or changed since indexing. Close the session and rescan before moving it.");
            SecureFiles.CreateDirectory(Root);
            string id = Guid.NewGuid().ToString("N");
            var state = LocalDatabase.Decode<UsageParserState>(source.ParserState);
            var entry = new TrashEntry(id, source.Id, state.SessionId, original, Path.Combine(Root, id + ".jsonl"), DateTimeOffset.UtcNow, "prepared");
            await database.SaveTrashAsync(entry, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            // Deny existing/new readers and writers, but allow our atomic rename while holding the handle.
            using (var file = new FileStream(original, FileMode.Open, FileAccess.ReadWrite, FileShare.Delete))
            {
                if (file.Length != source.Length) throw new IOException("The source changed before it could be moved.");
                File.Move(original, entry.StoredPath, overwrite: false);
            }
            await database.ForgetSourceAsync(source.Id, CancellationToken.None).ConfigureAwait(false);
            entry = entry with { State = "stored" };
            await database.SaveTrashAsync(entry, CancellationToken.None).ConfigureAwait(false);
            return entry;
        }
        finally { gate.Release(); }
    }
    private void Validate(TrashEntry entry)
    {
        if (!Guid.TryParseExact(entry.Id, "N", out _) || !SecureFiles.IsWithin(entry.StoredPath, Root) ||
            !string.Equals(Path.GetFileName(entry.StoredPath), entry.Id + ".jsonl", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The recovery entry has an invalid private path.");
        SecureFiles.LocalPath(entry.OriginalPath);
        if (!entry.OriginalPath.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Path.GetPathRoot(entry.OriginalPath), Path.GetPathRoot(Root), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The original source path is not supported.");
        if (entry.SourceId != "codex_" + UsageParser.Hash(Path.GetFullPath(entry.OriginalPath).ToUpperInvariant()))
            throw new InvalidDataException("The recovery identity does not match its source path.");
    }
    public async Task RestoreAsync(string id, CancellationToken ct)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var entry = (await database.TrashAsync(ct).ConfigureAwait(false)).FirstOrDefault(x => x.Id == id)
                ?? throw new InvalidDataException("Recovery entry not found.");
            Validate(entry);
            if (entry.State is not ("stored" or "conflict" or "restoring")) throw new InvalidDataException("This entry cannot currently be restored.");
            SecureFiles.RequireRegularFile(entry.StoredPath); SecureFiles.RejectReparseChain(Path.GetDirectoryName(entry.OriginalPath)!);
            if (!Directory.Exists(Path.GetDirectoryName(entry.OriginalPath))) throw new DirectoryNotFoundException("The original source directory is unavailable.");
            if (File.Exists(entry.OriginalPath) || Directory.Exists(entry.OriginalPath))
                throw new QuotaException(FailureKind.Storage, "A file already exists at the original location. It will not be overwritten.");
            await database.SaveTrashAsync(entry with { State = "restoring" }, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested(); File.Move(entry.StoredPath, entry.OriginalPath, overwrite: false);
            await database.SaveTrashAsync(entry with { State = "restored" }, CancellationToken.None).ConfigureAwait(false);
            await indexer.ScanFileAsync(Provider.Codex, entry.OriginalPath, true, ct).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }
    public async Task RecoverAsync(CancellationToken ct)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            foreach (var entry in await database.TrashAsync(ct).ConfigureAwait(false))
            {
                if (entry.State is not ("prepared" or "restoring")) continue;
                Validate(entry);
                bool original = File.Exists(entry.OriginalPath), stored = File.Exists(entry.StoredPath);
                string state;
                if (entry.State == "prepared" && stored && !original)
                {
                    SecureFiles.RequireRegularFile(entry.StoredPath);
                    await database.ForgetSourceAsync(entry.SourceId, ct).ConfigureAwait(false); state = "stored";
                }
                else if (entry.State == "prepared" && original && !stored) state = "cancelled";
                else if (entry.State == "restoring" && original && !stored)
                {
                    SecureFiles.RequireRegularFile(entry.OriginalPath);
                    await indexer.ScanFileAsync(Provider.Codex, entry.OriginalPath, true, ct).ConfigureAwait(false); state = "restored";
                }
                else if (entry.State == "restoring" && stored && !original) state = "stored";
                else state = "conflict";
                await database.SaveTrashAsync(entry with { State = state }, ct).ConfigureAwait(false);
            }
        }
        finally { gate.Release(); }
    }
}
