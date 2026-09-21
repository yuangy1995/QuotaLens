using QuotaLens.Core;
using QuotaLens.Providers;

namespace QuotaLens.Windows;

internal static class OAuthUiAdapter
{
    internal static Task<Credential> WaitForGoogleAsync(this OAuthSession session, CancellationToken ct) => session.ReceiveGoogleAsync(ct);
}
