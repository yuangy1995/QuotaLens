using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

public sealed record UsageParserState
{
    public int Schema { get; init; } = 1;
    public string SessionId { get; init; } = "";
    public string Project { get; init; } = "";
    public string Model { get; init; } = "unknown";
    public string? Effort { get; init; }
    public TokenUsage? PreviousTotal { get; init; }
    public DateTimeOffset? UpdatedAt { get; init; }
    public int RecognizedRecords { get; init; }
    public int UnpairedCounters { get; init; }
}
public sealed record ParsedUsage(UsageParserState State, UsageEvent? Event);

public static class UsageParser
{
    public static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private static string? Text(JsonElement value, int maximum = 512) => value.Text() is { } text ? text[..Math.Min(text.Length, maximum)] : null;
    private static long Count(JsonElement value, string key, bool required = false)
    {
        var item = value.At(key);
        if (item.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        { if (required) throw new InvalidDataException("Required usage counter is missing."); return 0; }
        long? result = item.Integer();
        return result is >= 0 ? result.Value : throw new InvalidDataException("Usage counter has an incompatible format.");
    }
    public static ParsedUsage Parse(string line, Provider provider, string source, UsageParserState state)
    {
        var root = JsonTools.Parse(line);
        return provider switch { Provider.Codex => Codex(root, source, state), Provider.Claude => Claude(root, source, state),
            _ => throw new NotSupportedException("Antigravity activity uses its own adapter.") };
    }
    private static ParsedUsage Codex(JsonElement root, string source, UsageParserState state)
    {
        var type = root.At("type").Text(); var payload = root.At("payload");
        var at = root.At("timestamp").Date();
        if (type is "session_meta" or "turn_context" or "response_item" or "event_msg")
            state = state with { RecognizedRecords = state.RecognizedRecords + 1, UpdatedAt = at ?? state.UpdatedAt };
        if (type == "session_meta")
            return new(state with { SessionId = Text(payload.At("id")) ?? Text(payload.At("session_id")) ?? state.SessionId,
                Project = Text(payload.At("cwd"), 32768) ?? state.Project }, null);
        if (type == "turn_context")
            return new(state with { Model = Text(payload.At("model"), 256) ?? state.Model,
                Effort = Text(payload.At("effort"), 64) ?? Text(payload.At("reasoning_effort"), 64) ?? Text(payload.At("reasoning", "effort"), 64) ?? state.Effort }, null);
        if (type != "event_msg" || payload.At("type").Text() != "token_count") return new(state, null);
        var info = payload.At("info");
        if (info.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return new(state, null);
        var totalObject = info.At("total_token_usage"); var lastObject = info.At("last_token_usage");
        bool cumulative = totalObject.ValueKind == JsonValueKind.Object;
        var counters = cumulative ? totalObject : lastObject;
        if (counters.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Unrecognized Codex token counter schema.");
        var total = new TokenUsage(Count(counters, "input_tokens", true), Count(counters, "cached_input_tokens"), Count(counters, "output_tokens", true)).Validate();
        TokenUsage delta = total;
        if (cumulative && state.PreviousTotal is { } previous)
        {
            delta = new(total.Input - previous.Input, total.CachedInput - previous.CachedInput, total.Output - previous.Output);
            if (delta.Input < 0 || delta.CachedInput < 0 || delta.Output < 0 || delta.CachedInput > delta.Input)
                return new(state with { PreviousTotal = total, UnpairedCounters = state.UnpairedCounters + 1 }, null);
        }
        state = state with { PreviousTotal = cumulative ? total : state.PreviousTotal,
            Model = Text(info.At("model"), 256) ?? state.Model };
        if (delta.Total == 0) return new(state, null);
        if (at is null) throw new InvalidDataException("A usage event has no usable timestamp.");
        string session = state.SessionId.Length == 0 ? source : state.SessionId;
        string identity = Hash($"codex|{session}|{at:O}|{state.Model}|{total.Input}|{total.CachedInput}|{total.Output}");
        return new(state, new(identity, Provider.Codex, source, session, at.Value, state.Model, state.Effort, delta.Validate()));
    }
    private static ParsedUsage Claude(JsonElement root, string source, UsageParserState state)
    {
        var type = root.At("type").Text(); var at = root.At("timestamp").Date();
        if (type is "assistant" or "user" or "system" or "progress" or "summary")
            state = state with { RecognizedRecords = state.RecognizedRecords + 1,
                SessionId = Text(root.At("sessionId")) ?? state.SessionId, Project = Text(root.At("cwd"), 32768) ?? state.Project,
                UpdatedAt = at ?? state.UpdatedAt };
        if (type != "assistant") return new(state, null);
        var message = root.At("message"); var usage = message.At("usage");
        if (usage.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) return new(state, null);
        if (at is null) throw new InvalidDataException("A Claude usage event has no usable timestamp.");
        long cached = Count(usage, "cache_read_input_tokens");
        var tokens = new TokenUsage(checked(Count(usage, "input_tokens", true) + cached), cached,
            Count(usage, "output_tokens", true), Count(usage, "cache_creation_input_tokens")).Validate();
        state = state with { Model = Text(message.At("model"), 256) ?? state.Model };
        string session = state.SessionId.Length == 0 ? source : state.SessionId;
        var messageId = Text(message.At("id")) ?? Text(root.At("uuid"));
        if (messageId is null) throw new InvalidDataException("Claude usage has no stable message identity.");
        // Repeated assistant snapshots/duplicate files update the same logical fact, not another charge.
        string identity = Hash($"claude|{session}|{messageId}|{Text(root.At("requestId"))}");
        return new(state, new(identity, Provider.Claude, source, session, at.Value, state.Model, null, tokens));
    }
    public static TranscriptLine? Transcript(string line)
    {
        var root = JsonTools.Parse(line); var payload = root.At("payload");
        var type = root.At("type").Text(); var role = payload.At("role").Text(); string? text = null;
        if (type == "response_item" && payload.At("type").Text() == "message")
        {
            var content = payload.At("content");
            text = content.ValueKind == JsonValueKind.String ? content.GetString() : string.Join("\n", content.Items()
                .Where(item => item.At("type").Text() is "input_text" or "output_text" or "text")
                .Select(item => item.At("text").Text()).Where(value => value is not null));
        }
        else if (type == "event_msg" && payload.At("type").Text() is "user_message" or "agent_message")
        { role = payload.At("type").Text() == "user_message" ? "user" : "assistant"; text = payload.At("message").Text(); }
        if (string.IsNullOrWhiteSpace(text)) return null;
        if (text.Length > 131072) text = text[..131072] + "\n\n[Preview truncated at 128K characters. Open the source file to read the full message.]";
        return new(role ?? "message", text, root.At("timestamp").Date());
    }
}
