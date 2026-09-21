using System.Text;

namespace QuotaLens.Infrastructure;

public sealed record JsonlLine(long Offset, long NextOffset, string Text);
public static class JsonlReader
{
    public const int MaximumLineBytes = 8 * 1024 * 1024;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    public static IEnumerable<JsonlLine> Read(Stream stream, long offset, long snapshotLength, CancellationToken ct)
    {
        if (!stream.CanSeek || offset < 0 || offset > snapshotLength) throw new InvalidDataException("Invalid source checkpoint.");
        stream.Position = offset; long lineStart = offset;
        byte[] buffer = new byte[65536]; using var line = new MemoryStream();
        while (stream.Position < snapshotLength)
        {
            ct.ThrowIfCancellationRequested(); long blockStart = stream.Position;
            int count = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, snapshotLength - stream.Position));
            if (count == 0) throw new IOException("The source changed while it was being read.");
            int start = 0;
            for (int i = 0; i < count; i++)
            {
                if (buffer[i] != 10) continue;
                if (line.Length + i - start > MaximumLineBytes) throw new InvalidDataException("A source line exceeds the supported 8 MB limit.");
                line.Write(buffer, start, i - start);
                var text = Utf8.GetString(line.GetBuffer(), 0, checked((int)line.Length)).TrimEnd('\r');
                if (lineStart == 0) text = text.TrimStart('\uFEFF');
                long next = blockStart + i + 1;
                yield return new(lineStart, next, text);
                line.SetLength(0); lineStart = next; start = i + 1;
            }
            if (line.Length + count - start > MaximumLineBytes) throw new InvalidDataException("A source line exceeds the supported 8 MB limit.");
            line.Write(buffer, start, count - start);
        }
        // An unfinished final line belongs to the writer. Never checkpoint past it.
    }
}
