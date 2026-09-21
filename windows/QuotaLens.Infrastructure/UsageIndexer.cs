using System.Security.Cryptography;
using System.Text.Json;
using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

public sealed class UsageIndexer(LocalDatabase database)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public event Action<string>? Progress;
    public async Task<ScanReport> ScanAsync(Provider provider, IEnumerable<string> roots, bool force = false, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        int discovered = 0, updated = 0, unchanged = 0, failed = 0; long events = 0; bool unpaired = false;
        try
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var root in roots.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    SecureFiles.RejectReparseChain(root);
                    if (!Directory.Exists(root)) continue;
                    foreach (var path in Directory.EnumerateFiles(root, "*.jsonl", new EnumerationOptions {
                        RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = FileAttributes.ReparsePoint,
                        MatchCasing = MatchCasing.CaseInsensitive }))
                    {
                        ct.ThrowIfCancellationRequested(); if (!seen.Add(path)) continue; discovered++;
                        if (discovered % 10 == 1) Progress?.Invoke($"{provider}: {discovered} files · {updated} updated");
                        try
                        {
                            var result = await ScanFileAsync(provider, path, force, ct).ConfigureAwait(false);
                            if (result.Changed) updated++; else unchanged++;
                            events += result.Events; unpaired |= result.Unpaired;
                        }
                        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidDataException or System.Text.DecoderFallbackException)
                        { failed++; }
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException) { failed++; }
            }
            var report = new ScanReport(discovered, updated, unchanged, failed, events, DateTimeOffset.UtcNow,
                failed > 0 ? "Some sources could not be read completely; their previous statistics were retained." :
                unpaired ? "Some corrected counters could not be paired. Unattributable usage was not invented." :
                discovered == 0 ? "No readable local session files were found. Cached history was retained." : null);
            await database.PutMetadataAsync("scan_" + provider, report, ct).ConfigureAwait(false);
            return report;
        }
        finally { Progress?.Invoke(""); gate.Release(); }
    }
    public Task<(bool Changed, long Events, bool Unpaired)> ScanFileAsync(Provider provider, string path, bool force = false, CancellationToken ct = default)
    {
        path = SecureFiles.RequireRegularFile(path);
        if (!path.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("JSONL source required.");
        string sourceId = provider.ToString().ToLowerInvariant() + "_" + UsageParser.Hash(path.ToUpperInvariant());
        return database.WriteAsync((connection, transaction) => {
            var info = new FileInfo(path); long length = info.Length, stamp = info.LastWriteTimeUtc.Ticks, created = info.CreationTimeUtc.Ticks;
            var old = LocalDatabase.Source(connection, transaction, sourceId);
            if (!force && old is not null && old.Length == length && old.LastWriteTicks == stamp && old.CreationTicks == created)
                return (false, 0L, false);
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, FileOptions.SequentialScan);
            bool reset = force || old is null || old.Offset > length || old.CreationTicks != created ||
                old.LastWriteTicks != stamp && length <= old.Length;
            if (!reset && old is not null)
                reset = Fingerprint(stream, 0, old.HeadLength) != old.HeadHash ||
                    Fingerprint(stream, Math.Max(0, old.Offset - 256), (int)Math.Min(256, old.Offset)) != old.TailHash;
            var state = reset ? new UsageParserState() : LocalDatabase.Decode<UsageParserState>(old!.ParserState);
            if (state.Schema != 1) { reset = true; state = new(); }
            if (reset && old is not null) LocalDatabase.RemoveSource(connection, transaction, sourceId);
            long offset = reset ? 0 : old!.Offset; long eventCount = 0; int completeLines = 0;
            foreach (var line in JsonlReader.Read(stream, offset, length, ct))
            {
                ct.ThrowIfCancellationRequested(); offset = line.NextOffset;
                if (string.IsNullOrWhiteSpace(line.Text)) continue; completeLines++;
                var parsed = UsageParser.Parse(line.Text, provider, sourceId, state); state = parsed.State;
                if (parsed.Event is { } item) { LocalDatabase.PutEvent(connection, transaction, item); eventCount++; }
            }
            if (completeLines > 0 && state.RecognizedRecords == 0) throw new InvalidDataException("Unrecognized session source format.");
            if (state.RecognizedRecords > 0)
                LocalDatabase.PutSession(connection, transaction, sourceId, state.SessionId.Length == 0 ? sourceId : state.SessionId,
                    provider, path, state.Project, state.UpdatedAt ?? new DateTimeOffset(info.LastWriteTimeUtc), state.Model);
            int headLength = (int)Math.Min(4096, offset);
            LocalDatabase.SaveSource(connection, transaction, new(sourceId, provider, path, offset, length, stamp, created, headLength,
                Fingerprint(stream, 0, headLength), Fingerprint(stream, Math.Max(0, offset - 256), (int)Math.Min(256, offset)), LocalDatabase.Encode(state)));
            return (true, eventCount, state.UnpairedCounters > 0);
        }, ct);
    }
    private static string Fingerprint(Stream stream, long offset, int count)
    {
        stream.Position = offset; byte[] bytes = new byte[count]; stream.ReadExactly(bytes);
        return Convert.ToHexStringLower(SHA256.HashData(bytes));
    }
    public Task<TranscriptPage> TranscriptAsync(SourceCheckpoint source, long offset = 0, int limit = 100, CancellationToken ct = default) => Task.Run(() => {
        if (source.Provider != Provider.Codex) throw new NotSupportedException("Only Codex conversation replay is enabled.");
        var path = SecureFiles.RequireRegularFile(source.Path); var rows = new List<TranscriptLine>(); string? previous = null;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        foreach (var line in JsonlReader.Read(stream, offset, stream.Length, ct))
        {
            if (string.IsNullOrWhiteSpace(line.Text)) continue;
            var message = UsageParser.Transcript(line.Text);
            if (message is null) continue;
            var signature = UsageParser.Hash(message.Role + "\n" + message.Text);
            if (signature == previous) continue; previous = signature; rows.Add(message);
            if (rows.Count >= Math.Clamp(limit, 1, 200)) return new TranscriptPage(rows, line.NextOffset);
        }
        return new TranscriptPage(rows, null);
    }, ct);
    public async Task<(IReadOnlyList<SearchHit> Hits, int Failed, bool Limited)> SearchAsync(string query, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(query) || query.Length > 200) throw new ArgumentException("Search text must contain 1–200 characters.");
        var sources = await database.SourcesAsync(Provider.Codex, ct).ConfigureAwait(false);
        return await Task.Run<(IReadOnlyList<SearchHit>, int, bool)>(() => {
            var hits = new List<SearchHit>(); int failed = 0;
            foreach (var source in sources.Reverse())
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    SecureFiles.RequireRegularFile(source.Path);
                    using var stream = new FileStream(source.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    string? previous = null;
                    foreach (var line in JsonlReader.Read(stream, 0, stream.Length, ct))
                    {
                        if (string.IsNullOrWhiteSpace(line.Text)) continue;
                        var item = UsageParser.Transcript(line.Text); if (item is null) continue;
                        string signature = UsageParser.Hash(item.Role + "\n" + item.Text);
                        if (signature == previous) continue; previous = signature;
                        int at = item.Text.IndexOf(query, StringComparison.OrdinalIgnoreCase); if (at < 0) continue;
                        int start = Math.Max(0, at - 100); string preview = item.Text.Substring(start, Math.Min(450, item.Text.Length - start));
                        var state = LocalDatabase.Decode<UsageParserState>(source.ParserState);
                        hits.Add(new(source.Id, state.SessionId, source.Path, preview, line.Offset));
                        if (hits.Count == 100) return (hits, failed, true);
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidDataException) { failed++; }
            }
            return (hits, failed, false);
        }, ct).ConfigureAwait(false);
    }
}
