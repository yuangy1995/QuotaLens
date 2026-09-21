using System.Text;
using Microsoft.Data.Sqlite;
using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

/// <summary>Read-only adapter for the existing macOS trajectorySummaries schema.
/// Extracts only task IDs, step counts, timestamps and a workspace basename.
/// Neither the summary text nor conversation contents are returned or persisted.</summary>
public static class AntigravityActivityReader
{
    private const int MaximumBytes = 8 * 1024 * 1024;
    private const string SummaryKey = "antigravityUnifiedStateSync.trajectorySummaries";
    public static Task<IReadOnlyList<ActivitySummary>> ReadAsync(string path, CancellationToken ct) => Task.Run<IReadOnlyList<ActivitySummary>>(() => {
        path = SecureFiles.RequireRegularFile(path);
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder {
            DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 2
        }.ToString());
        connection.Open(); using var command = connection.CreateCommand();
        command.CommandText = "SELECT length(value), value FROM ItemTable WHERE key = $key LIMIT 1";
        command.Parameters.AddWithValue("$key", SummaryKey);
        using var cancellation = ct.Register(command.Cancel);
        ct.ThrowIfCancellationRequested(); using var reader = command.ExecuteReader();
        if (!reader.Read() || reader.IsDBNull(1)) throw new QuotaException(FailureKind.NotConnected, "No supported Antigravity activity summary was found. Previous activity was retained.");
        if (reader.GetInt64(0) > MaximumBytes * 2) throw new InvalidDataException("Antigravity activity summary exceeds the size limit.");
        var records = Parse(reader.GetString(1), ct); ct.ThrowIfCancellationRequested(); return records;
    }, ct);

    public static IReadOnlyList<ActivitySummary> Parse(string encoded, CancellationToken ct = default)
    {
        if (encoded.Length > MaximumBytes * 2) throw new InvalidDataException("Activity summary exceeds the size limit.");
        byte[] data;
        try { data = Convert.FromBase64String(encoded); } catch (FormatException) { throw Invalid(); }
        if (data.Length > MaximumBytes) throw Invalid();
        var result = new List<ActivitySummary>(); var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var field in Fields(data)) {
            ct.ThrowIfCancellationRequested(); if (field.Number != 1 || field.Wire != 2) continue;
            var entry = Fields(field.Bytes).ToArray();
            var id = StrictText(entry.SingleOrDefault(x => x.Number == 1 && x.Wire == 2).Bytes);
            var row = entry.SingleOrDefault(x => x.Number == 2 && x.Wire == 2).Bytes;
            if (string.IsNullOrWhiteSpace(id) || id.Length > 1024 || row.IsEmpty || !identities.Add(id)) throw Invalid();
            var wrapped = Fields(row).SingleOrDefault(x => x.Number == 1 && x.Wire == 2);
            byte[] summary;
            try { summary = Convert.FromBase64String(StrictText(wrapped.Bytes)); } catch (FormatException) { throw Invalid(); }
            int? steps = null; DateTimeOffset? at = null; string project = ""; bool recognized = false;
            foreach (var value in Fields(summary)) {
                switch (value.Number) {
                    case 1: break;
                    case 2 when value.Wire == 0:
                        if (value.Scalar > int.MaxValue) throw Invalid(); steps = (int)value.Scalar; recognized = true; break;
                    case 3 or 7 or 10 when value.Wire == 2:
                        var time = Timestamp(value.Bytes); if (time is not null && (at is null || time > at)) at = time;
                        recognized = true; break;
                    case 9 when value.Wire == 2:
                        project = WorkspaceBasename(value.Bytes); recognized = true; break;
                }
            }
            if (!recognized) throw Invalid();
            result.Add(new ActivitySummary(id, "windows-local", project, at, steps));
            if (result.Count > 100_000) throw Invalid();
        }
        if (data.Length != 0 && result.Count == 0) throw Invalid();
        return result;
    }
    internal readonly record struct Field(int Number, int Wire, ulong Scalar, ReadOnlyMemory<byte> Bytes);
    internal static IEnumerable<Field> Fields(ReadOnlyMemory<byte> data)
    {
        int offset = 0;
        while (offset < data.Length) {
            ulong tag = Varint(data, ref offset); int number = checked((int)(tag >> 3)), wire = (int)(tag & 7);
            if (number == 0) throw Invalid();
            if (wire == 0) { yield return new(number, wire, Varint(data, ref offset), default); continue; }
            int length = wire switch { 1 => 8, 5 => 4, 2 => checked((int)Varint(data, ref offset)), _ => throw Invalid() };
            if (length < 0 || length > data.Length - offset) throw Invalid();
            yield return new(number, wire, 0, data.Slice(offset, length)); offset += length;
        }
    }
    private static ulong Varint(ReadOnlyMemory<byte> data, ref int offset)
    {
        ulong value = 0;
        for (int shift = 0; shift < 70; shift += 7) {
            if (offset >= data.Length) throw Invalid(); byte next = data.Span[offset++];
            if (shift == 63 && next > 1) throw Invalid(); value |= (ulong)(next & 127) << shift;
            if ((next & 128) == 0) return value;
        }
        throw Invalid();
    }
    internal static string StrictText(ReadOnlyMemory<byte> value) => new UTF8Encoding(false, true).GetString(value.Span);
    internal static DateTimeOffset? Timestamp(ReadOnlyMemory<byte> data)
    {
        var fields = Fields(data).ToArray(); var seconds = fields.FirstOrDefault(x => x.Number == 1 && x.Wire == 0);
        if (seconds.Number == 0) return null;
        var nanos = fields.FirstOrDefault(x => x.Number == 2 && x.Wire == 0).Scalar;
        if (seconds.Scalar > 253402300799UL || nanos >= 1_000_000_000) throw Invalid();
        return DateTimeOffset.FromUnixTimeSeconds((long)seconds.Scalar).AddTicks((long)nanos / 100);
    }
    private static string WorkspaceBasename(ReadOnlyMemory<byte> data)
    {
        var value = new StringBuilder();
        string Candidate() {
            if (!Uri.TryCreate(value.ToString(), UriKind.Absolute, out var uri) || !uri.IsFile) return "";
            return Uri.UnescapeDataString(uri.AbsolutePath.TrimEnd('/').Split('/').LastOrDefault() ?? "");
        }
        foreach (byte next in data.Span) {
            if (next >= 32 && next < 127) { if (value.Length < 8192) value.Append((char)next); }
            else { var candidate = Candidate(); if (candidate.Length > 0) return candidate; value.Clear(); }
        }
        return Candidate();
    }
    private static InvalidDataException Invalid() => new("Antigravity activity format was not recognized. Previous activity was retained.");
}
