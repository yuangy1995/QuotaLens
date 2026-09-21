namespace QuotaLens.Core;

public sealed record SubscriptionInfo(string AccountKey, string? Plan, bool? Active, bool? WillRenew,
    DateTimeOffset? RenewsAt, DateTimeOffset? ExpiresAt, DateTimeOffset? CancelsAt, DateTimeOffset ObservedAt);
public sealed record ResetCredit(string Id, string? Status, DateTimeOffset? ExpiresAt, DateTimeOffset? GrantedAt)
{
    public bool Available(DateTimeOffset now) => Status == "available" && (ExpiresAt is null || ExpiresAt > now)
        && !string.IsNullOrWhiteSpace(Id) && !Id.StartsWith("reset_credit_", StringComparison.Ordinal);
}
public sealed record CodexExtendedSnapshot(QuotaSnapshot Quota, IReadOnlyList<ResetCredit> Credits, int? AvailableCredits,
    bool SupportsCredits, string? Warning = null);
public sealed record PendingRedemption(string AccountKey, string CreditId, string IdempotencyKey, DateTimeOffset CreatedAt,
    string State = "pending");
