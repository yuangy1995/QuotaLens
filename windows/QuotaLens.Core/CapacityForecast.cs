namespace QuotaLens.Core;

public sealed record CapacityObservation(string AccountKey, long ObservedAt, long? LifetimeTokens,
    string? PlanType, string? SubscriptionPlan, IReadOnlyList<CapacityWindowSample> Windows);
public sealed record CapacityWindowSample(int Minutes, double UsedPercent, long ResetsAt);
public enum CapacityCycleEnd { Natural, Restored, PlanChanged, AwaitingRefresh }
public sealed record CapacityCycle
{
    public required string Id { get; init; }
    public int Minutes { get; init; }
    public int Stage { get; init; }
    public long StartAt { get; init; }
    public long ExpectedEndAt { get; internal set; }
    public long? EndAt { get; internal set; }
    public CapacityCycleEnd? EndReason { get; internal set; }
    public long ObservedThrough { get; internal set; }
    public double MeasuredTokens { get; internal set; }
    public double ConsumedPercent { get; internal set; }
    public double RemainingPercent { get; internal set; }
    public bool HasGap { get; internal set; }
    public bool HasPrecedingGap { get; init; }
    public int IntervalCount { get; internal set; }
    public bool AwaitingCloudUsage { get; internal set; }
    public double? Capacity => ConsumedPercent >= 10 && MeasuredTokens > 0 && double.IsFinite(MeasuredTokens * 100 / ConsumedPercent)
        ? MeasuredTokens * 100 / ConsumedPercent : null;
    public double? RemainingTokens => Capacity * RemainingPercent / 100;
}
public sealed record CapacityPrediction(double Tokens, double ChangePercent, bool FollowsTrend, int SampleCount);
public sealed record CapacityWindow(int Minutes, IReadOnlyList<CapacityCycle> Cycles, bool IsAvailable, CapacityPrediction? Prediction)
{
    public CapacityCycle? Current => Cycles.LastOrDefault() is { EndAt: null } last ? last : null;
}

/// <summary>Behavioral port of Core/Quota/CodexCapacityForecast.swift at 98e37a0.
/// Only identity-confirmed cloud counters are accepted; never local session totals.</summary>
public static class CapacityForecast
{
    public static CapacityObservation FromSnapshot(QuotaSnapshot value) => new(value.AccountKey,
        value.CapturedAt.ToUnixTimeSeconds(), value.LifetimeTokens is >= 0 ? value.LifetimeTokens : null,
        value.Plan, value.Subscription?.Plan,
        value.Pools.Where(x => x.Group == "codex" && x.WindowMinutes is 300 or 10080 && x.ResetsAt != null)
            .Select(x => new CapacityWindowSample(x.WindowMinutes!.Value, x.UsedPercent, x.ResetsAt!.Value.ToUnixTimeSeconds())).ToArray());

    public static IReadOnlyList<CapacityWindow> Analyze(IEnumerable<CapacityObservation> input, string accountKey, long now)
    {
        var observations = input.Where(x => x.AccountKey == accountKey && x.ObservedAt <= now).OrderBy(x => x.ObservedAt);
        int stage = 0;
        string? lastPlan = null, lastSubscription = null;
        var staged = new List<(CapacityObservation Observation, int Stage)>();
        foreach (var observation in observations)
        {
            bool coarseChanged = observation.PlanType != null && lastPlan != null && lastPlan != observation.PlanType;
            bool detailChanged = observation.SubscriptionPlan != null && lastSubscription != null && lastSubscription != observation.SubscriptionPlan;
            if (coarseChanged || detailChanged) stage++;
            if (coarseChanged) lastSubscription = null;
            if (observation.PlanType != null) lastPlan = observation.PlanType;
            if (observation.SubscriptionPlan != null) lastSubscription = observation.SubscriptionPlan;
            staged.Add((observation, stage));
        }
        return new[] { 300, 10080 }.Select(minutes => Build(minutes, staged, accountKey, now))
            .OfType<CapacityWindow>().ToArray();
    }

    private sealed record Anchor(long Tokens, double Percent);
    private static CapacityWindow? Build(int minutes, IReadOnlyList<(CapacityObservation Observation, int Stage)> staged,
        string accountKey, long now)
    {
        var cycles = new List<CapacityCycle>();
        CapacityCycle? current = null;
        CapacityWindowSample? previousWindow = null;
        long? previousTime = null, previousTokens = null, unsettledResetCounter = null;
        Anchor? anchor = null;
        double pairedTokens = 0, pairedPercent = 0;
        bool available = false;
        foreach (var (observation, currentStage) in staged)
        {
            if (previousTime != null && observation.ObservedAt <= previousTime) continue;
            previousTime = observation.ObservedAt;
            var window = observation.Windows.FirstOrDefault(x => x.Minutes == minutes);
            if (window == null || !double.IsFinite(window.UsedPercent) || window.UsedPercent is < 0 or > 100 || window.ResetsAt <= observation.ObservedAt)
            {
                available = false; anchor = null; pairedTokens = pairedPercent = 0;
                if (current != null) current.HasGap = true;
                continue;
            }
            available = true;
            CapacityCycleEnd? reason = null;
            long boundary = observation.ObservedAt;
            if (current != null && previousWindow != null)
            {
                if (current.Stage != currentStage) reason = CapacityCycleEnd.PlanChanged;
                else if (Math.Abs(window.ResetsAt - current.ExpectedEndAt) > 60 &&
                    !(current.RemainingPercent == 100 && current.ConsumedPercent == 0 && current.ExpectedEndAt > observation.ObservedAt))
                {
                    if (observation.ObservedAt >= current.ExpectedEndAt)
                    { reason = CapacityCycleEnd.Natural; boundary = current.ExpectedEndAt; }
                    else reason = CapacityCycleEnd.Restored;
                }
                else if (previousWindow.UsedPercent - window.UsedPercent >= 5) reason = CapacityCycleEnd.Restored;
            }
            if (reason != null && current != null)
            {
                double unmatchedPercent = anchor == null ? 0 : (previousWindow?.UsedPercent ?? anchor.Percent) - anchor.Percent - pairedPercent;
                if (unmatchedPercent >= 2 || unsettledResetCounter != null)
                {
                    bool advanced = observation.LifetimeTokens != null && observation.LifetimeTokens != previousTokens;
                    unsettledResetCounter = advanced ? null : previousTokens;
                }
                current.EndAt = boundary; current.EndReason = reason;
                cycles.Add(current with { }); current = null; anchor = null; pairedTokens = pairedPercent = 0;
            }
            if (current == null)
            {
                long nominalStart = window.ResetsAt - minutes * 60L;
                current = new CapacityCycle
                {
                    Id = $"{accountKey}:{minutes}:{observation.ObservedAt}:{currentStage}", Minutes = minutes, Stage = currentStage,
                    StartAt = reason == CapacityCycleEnd.Natural ? Math.Max(boundary, nominalStart) : observation.ObservedAt,
                    ExpectedEndAt = window.ResetsAt, ObservedThrough = observation.ObservedAt,
                    RemainingPercent = 100 - window.UsedPercent, HasGap = window.UsedPercent > 0,
                    HasPrecedingGap = reason == CapacityCycleEnd.Natural && nominalStart > boundary + 60
                };
                anchor = observation.LifetimeTokens is { } initial ? new(initial, window.UsedPercent) : null;
            }
            else if (observation.LifetimeTokens is >= 0)
            {
                long tokens = observation.LifetimeTokens.Value;
                if (unsettledResetCounter is { } pending)
                {
                    if (tokens != pending)
                    { unsettledResetCounter = null; anchor = new(tokens, window.UsedPercent); pairedTokens = pairedPercent = 0; current.HasGap = true; }
                }
                else if (anchor is { } baseline)
                {
                    double drop = (previousWindow?.UsedPercent ?? baseline.Percent) - window.UsedPercent;
                    if (tokens < baseline.Tokens || previousTokens != null && tokens < previousTokens || drop > 0.001)
                    { current.HasGap = true; anchor = new(tokens, window.UsedPercent); pairedTokens = pairedPercent = 0; }
                    else
                    {
                        double percent = window.UsedPercent - baseline.Percent, delta = (double)tokens - baseline.Tokens;
                        if (percent >= 2 && delta > pairedTokens)
                        {
                            current.MeasuredTokens += delta - pairedTokens;
                            current.ConsumedPercent += percent - pairedPercent;
                            current.IntervalCount++; pairedTokens = delta; pairedPercent = percent;
                        }
                    }
                }
                else anchor = new(tokens, window.UsedPercent);
            }
            else current.HasGap = true;
            bool pendingUpdate = anchor != null && window.UsedPercent - anchor.Percent - pairedPercent >= 2;
            current.AwaitingCloudUsage = observation.LifetimeTokens == null || unsettledResetCounter != null || pendingUpdate;
            if (observation.LifetimeTokens is >= 0) previousTokens = observation.LifetimeTokens;
            current.RemainingPercent = 100 - window.UsedPercent;
            current.ObservedThrough = observation.ObservedAt;
            current.ExpectedEndAt = window.ResetsAt;
            previousWindow = window;
        }
        if (current != null)
        {
            if (current.ExpectedEndAt <= now)
            { current.EndAt = current.ExpectedEndAt; current.EndReason = CapacityCycleEnd.AwaitingRefresh; available = false; }
            cycles.Add(current with { });
        }
        if (cycles.Count == 0) return null;
        var eligible = new List<double>();
        int? latestStage = staged.Count == 0 ? null : staged[^1].Stage;
        foreach (var cycle in cycles)
        {
            if (cycle.EndAt == null) continue;
            if (cycle.Stage != latestStage || cycle.EndReason == CapacityCycleEnd.PlanChanged || cycle.Capacity == null)
            { eligible.Clear(); continue; }
            if (cycle.HasPrecedingGap) eligible.Clear();
            eligible.Add(cycle.Capacity.Value);
        }
        return new(minutes, cycles, available, Predict(eligible));
    }

    public static CapacityPrediction? Predict(IEnumerable<double> input)
    {
        var values = input.TakeLast(5).ToArray();
        if (values.Length == 0 || values.Any(x => !double.IsFinite(x) || x <= 0)) return null;
        var changes = values.Zip(values.Skip(1), (a, b) => (b - a) / a).ToArray();
        double rate = 0;
        if (changes.Length >= 2)
        {
            var sorted = changes.Order().ToArray(); int middle = sorted.Length / 2;
            double median = sorted.Length % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
            var recent = changes.TakeLast(2).ToArray();
            if (recent.All(x => x > 0) && median > 0 || recent.All(x => x < 0) && median < 0) rate = median * 0.5;
        }
        double result = values[^1] * (1 + rate);
        return double.IsFinite(result) ? new(result, rate * 100, rate != 0, values.Length) : null;
    }
}
