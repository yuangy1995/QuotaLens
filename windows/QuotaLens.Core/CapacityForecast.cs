namespace QuotaLens.Core;

public sealed record CapacityObservation(string AccountKey, long ObservedAt, long? LifetimeTokens, string? PlanType,
    string? SubscriptionPlan, IReadOnlyList<CapacitySample> Windows);
public sealed record CapacitySample(int Minutes, double UsedPercent, long ResetsAt);
public sealed record CapacityPrediction(double Tokens, double ChangePercent, bool FollowsTrend, int SampleCount);
public sealed class CapacityCycle
{
    public required int Minutes { get; init; }
    public required int Stage { get; init; }
    public required long StartAt { get; init; }
    public required long ExpectedEndAt { get; set; }
    public long? EndAt { get; set; }
    public string? EndReason { get; set; }
    public long ObservedThrough { get; set; }
    public double MeasuredTokens { get; set; }
    public double ConsumedPercent { get; set; }
    public double RemainingPercent { get; set; }
    public bool HasGap { get; set; }
    public bool HasPrecedingGap { get; init; }
    public int IntervalCount { get; set; }
    public bool AwaitingCloudUsage { get; set; }
    public double? Capacity => ConsumedPercent >= 10 && MeasuredTokens > 0 && double.IsFinite(MeasuredTokens * 100 / ConsumedPercent)
        ? MeasuredTokens * 100 / ConsumedPercent : null;
    public double? RemainingTokens => Capacity * RemainingPercent / 100;
}
public sealed record CapacityWindow(int Minutes, IReadOnlyList<CapacityCycle> Cycles, bool Available, CapacityPrediction? Prediction)
{
    public CapacityCycle? Current => Cycles.LastOrDefault() is { EndAt: null } c ? c : null;
}

/// <summary>Behavioral port of Core/Quota/CodexCapacityForecast.swift at 98e37a0.
/// Only verified cloud counters are accepted; local usage must never be supplied here.</summary>
public static class CapacityForecast
{
    public static IReadOnlyList<CapacityWindow> Analyze(IEnumerable<CapacityObservation> input, string accountKey, long now)
    {
        var ordered = input.Where(x => x.AccountKey == accountKey && x.ObservedAt <= now).OrderBy(x => x.ObservedAt).ToArray();
        var staged = new List<(CapacityObservation Observation, int Stage)>();
        var stage = 0;
        string? lastPlan = null, lastSubscription = null;
        foreach (var o in ordered)
        {
            bool coarseChanged = o.PlanType is not null && lastPlan is not null && o.PlanType != lastPlan;
            bool detailChanged = o.SubscriptionPlan is not null && lastSubscription is not null && o.SubscriptionPlan != lastSubscription;
            if (coarseChanged || detailChanged) stage++;
            if (coarseChanged) lastSubscription = null;
            lastPlan = o.PlanType ?? lastPlan;
            lastSubscription = o.SubscriptionPlan ?? lastSubscription;
            staged.Add((o, stage));
        }
        return new[] { 300, 10080 }.Select(m => Build(m, staged, now)).OfType<CapacityWindow>().ToArray();
    }

    private static CapacityWindow? Build(int minutes, List<(CapacityObservation Observation, int Stage)> staged, long now)
    {
        var cycles = new List<CapacityCycle>();
        CapacityCycle? current = null;
        CapacitySample? previousWindow = null;
        long? previousTime = null, previousTokens = null, unsettledResetCounter = null;
        (long Tokens, double Percent)? anchor = null;
        double pairedTokens = 0, pairedPercent = 0;
        bool available = false;
        foreach (var (o, stage) in staged)
        {
            if (previousTime is { } pt && o.ObservedAt <= pt) continue;
            previousTime = o.ObservedAt;
            var window = o.Windows.FirstOrDefault(w => w.Minutes == minutes);
            if (window is null || !double.IsFinite(window.UsedPercent) || window.UsedPercent is < 0 or > 100 || window.ResetsAt <= o.ObservedAt)
            {
                available = false; anchor = null; pairedTokens = pairedPercent = 0;
                if (current is not null) current.HasGap = true;
                continue;
            }
            available = true;
            string? reason = null;
            long boundary = o.ObservedAt;
            if (current is { } old && previousWindow is not null)
            {
                if (old.Stage != stage) reason = "planChanged";
                else if (Math.Abs(window.ResetsAt - old.ExpectedEndAt) > 60 &&
                    !(old.RemainingPercent == 100 && old.ConsumedPercent == 0 && old.ExpectedEndAt > o.ObservedAt))
                {
                    if (o.ObservedAt >= old.ExpectedEndAt) { reason = "natural"; boundary = old.ExpectedEndAt; }
                    else reason = "restored";
                }
                else if (previousWindow.UsedPercent - window.UsedPercent >= 5) reason = "restored";
            }
            if (reason is not null && current is not null)
            {
                double unmatched = anchor is { } a ? (previousWindow?.UsedPercent ?? a.Percent) - a.Percent - pairedPercent : 0;
                if (unmatched >= 2 || unsettledResetCounter is not null)
                    unsettledResetCounter = o.LifetimeTokens is { } t && t != previousTokens ? null : previousTokens;
                current.EndAt = boundary; current.EndReason = reason; cycles.Add(current);
                current = null; anchor = null; pairedTokens = pairedPercent = 0;
            }
            if (current is null)
            {
                long nominalStart = window.ResetsAt - minutes * 60L;
                current = new CapacityCycle { Minutes = minutes, Stage = stage,
                    StartAt = reason == "natural" ? Math.Max(boundary, nominalStart) : o.ObservedAt,
                    ExpectedEndAt = window.ResetsAt, ObservedThrough = o.ObservedAt, RemainingPercent = 100 - window.UsedPercent,
                    HasGap = window.UsedPercent > 0, HasPrecedingGap = reason == "natural" && nominalStart > boundary + 60 };
                anchor = o.LifetimeTokens is { } tokens && tokens >= 0 ? (tokens, window.UsedPercent) : null;
            }
            else if (o.LifetimeTokens is { } tokens && tokens >= 0)
            {
                if (unsettledResetCounter is { } pending)
                {
                    if (tokens != pending) { unsettledResetCounter = null; anchor = (tokens, window.UsedPercent); pairedTokens = pairedPercent = 0; current.HasGap = true; }
                }
                else if (anchor is { } basis)
                {
                    double drop = (previousWindow?.UsedPercent ?? basis.Percent) - window.UsedPercent;
                    if (tokens < basis.Tokens || previousTokens is { } prev && tokens < prev || drop > 0.001)
                    {
                        current.HasGap = true; anchor = (tokens, window.UsedPercent); pairedTokens = pairedPercent = 0;
                    }
                    else
                    {
                        double percent = window.UsedPercent - basis.Percent;
                        double delta = tokens - basis.Tokens;
                        if (percent >= 2 && delta > pairedTokens)
                        {
                            current.MeasuredTokens += delta - pairedTokens; current.ConsumedPercent += percent - pairedPercent;
                            current.IntervalCount++; pairedTokens = delta; pairedPercent = percent;
                        }
                    }
                }
                else anchor = (tokens, window.UsedPercent);
            }
            else current.HasGap = true;
            current.AwaitingCloudUsage = o.LifetimeTokens is null || unsettledResetCounter is not null ||
                anchor is { } value && window.UsedPercent - value.Percent - pairedPercent >= 2;
            if (o.LifetimeTokens is { } counter && counter >= 0) previousTokens = counter;
            current.RemainingPercent = 100 - window.UsedPercent;
            current.ObservedThrough = o.ObservedAt; current.ExpectedEndAt = window.ResetsAt;
            previousWindow = window;
        }
        if (current is not null)
        {
            if (current.ExpectedEndAt <= now) { current.EndAt = current.ExpectedEndAt; current.EndReason = "awaitingRefresh"; available = false; }
            cycles.Add(current);
        }
        if (cycles.Count == 0) return null;
        var eligible = new List<double>();
        int latestStage = staged.LastOrDefault().Stage;
        foreach (var cycle in cycles)
        {
            if (cycle.EndAt is null) continue;
            if (cycle.Stage != latestStage || cycle.EndReason == "planChanged" || cycle.Capacity is null) { eligible.Clear(); continue; }
            if (cycle.HasPrecedingGap) eligible.Clear();
            eligible.Add(cycle.Capacity.Value);
        }
        return new(minutes, cycles, available, Predict(eligible));
    }

    public static CapacityPrediction? Predict(IEnumerable<double> input)
    {
        var values = input.TakeLast(5).ToArray();
        if (values.Length == 0 || values.Any(v => !double.IsFinite(v) || v <= 0)) return null;
        var changes = values.Zip(values.Skip(1), (a, b) => (b - a) / a).ToArray();
        double rate = 0;
        if (changes.Length >= 2)
        {
            var sorted = changes.Order().ToArray();
            int middle = sorted.Length / 2;
            double median = sorted.Length % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
            if (changes.TakeLast(2).All(v => v > 0) && median > 0 || changes.TakeLast(2).All(v => v < 0) && median < 0) rate = median * 0.5;
        }
        double prediction = values[^1] * (1 + rate);
        return double.IsFinite(prediction) ? new(prediction, rate * 100, rate != 0, values.Length) : null;
    }
}
