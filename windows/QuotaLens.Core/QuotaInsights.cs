namespace QuotaLens.Core;

public sealed record PoolInsight(string PoolId, double? PercentPerHour, DateTimeOffset? EstimatedExhaustion,
    double? SustainablePercentPerHour, bool IsAtRisk, int SampleCount);

public static class QuotaInsights
{
    public static PoolInsight Analyze(IEnumerable<QuotaSnapshot> history, QuotaSnapshot current, QuotaPool pool, DateTimeOffset now)
    {
        if (!pool.IsCurrent(now)) return new(pool.Id, null, null, null, false, 0);
        var rows = history.Where(x => x.AccountKey == current.AccountKey && x.Tool == current.Tool &&
                x.CapturedAt <= current.CapturedAt && x.CapturedAt >= current.CapturedAt.AddHours(-24))
            .OrderBy(x => x.CapturedAt).Select(x => (At: x.CapturedAt, Pool: x.Pools.FirstOrDefault(p => p.Id == pool.Id)))
            .Where(x => x.Pool is { IsValid: true }).ToArray();
        var continuous = new List<(DateTimeOffset At, QuotaPool Pool)>();
        foreach (var row in rows)
        {
            var value = row.Pool!;
            if (continuous.Count > 0)
            {
                var previous = continuous[^1];
                if (value.ResetsAt != previous.Pool.ResetsAt || value.UsedPercent < previous.Pool.UsedPercent ||
                    row.At - previous.At > TimeSpan.FromHours(2)) continuous.Clear();
            }
            continuous.Add((row.At, value));
        }
        double? sustainable = pool.ResetsAt > now ? pool.RemainingPercent / (pool.ResetsAt.Value - now).TotalHours : null;
        if (continuous.Count < 2 || (continuous[^1].At - continuous[0].At).TotalMinutes < 5)
            return new(pool.Id, null, null, sustainable, false, continuous.Count);
        double hours = (continuous[^1].At - continuous[0].At).TotalHours;
        double rate = (continuous[^1].Pool.UsedPercent - continuous[0].Pool.UsedPercent) / hours;
        DateTimeOffset? exhaustion = rate > 0.001 ? now.AddHours(Math.Min(pool.RemainingPercent / rate, 87600)) : null;
        return new(pool.Id, rate, exhaustion, sustainable, exhaustion != null && pool.ResetsAt != null && exhaustion < pool.ResetsAt, continuous.Count);
    }

    public static IReadOnlyList<string> RecoveryKeys(QuotaSnapshot? previous, QuotaSnapshot next)
    {
        if (previous == null || previous.AccountKey != next.AccountKey || previous.Tool != next.Tool || next.CapturedAt <= previous.CapturedAt)
            return [];
        return next.Pools.Where(pool => pool.WindowMinutes == 10080 && pool.IsCurrent(next.CapturedAt) && pool.UsedPercent <= 0.001 &&
            previous.Pools.Any(old => old.Id == pool.Id && old.IsValid && old.UsedPercent >= 1))
            .Select(pool => StableId.Hash($"{next.AccountKey}:{pool.Id}:{pool.ResetsAt?.ToUnixTimeSeconds()}"))
            .ToArray();
    }
}
