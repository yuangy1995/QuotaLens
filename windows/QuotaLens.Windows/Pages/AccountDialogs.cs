using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using QuotaLens.Core;
using QuotaLens.Infrastructure;
using QuotaLens.Providers;
using QuotaLens.Windows.Platform;
using QuotaLens.Windows.UI;

namespace QuotaLens.Windows;

public sealed partial class MainWindow
{
    private readonly SemaphoreSlim dialogGate = new(1, 1);
    private async Task<ContentDialogResult> DialogAsync(string title, UIElement content, string? primary, CancellationToken ct)
    {
        await dialogGate.WaitAsync(ct);
        try {
            var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = title, Content = content,
                PrimaryButtonText = primary ?? "", CloseButtonText = T("关闭", "Close"), DefaultButton = ContentDialogButton.Close, RequestedTheme = root.RequestedTheme };
            using var registration = ct.Register(() => DispatcherQueue.TryEnqueue(dialog.Hide));
            ct.ThrowIfCancellationRequested(); var result = await dialog.ShowAsync(); ct.ThrowIfCancellationRequested(); return result;
        } finally { dialogGate.Release(); }
    }
    private async Task<bool> ConfirmAsync(string title, string explanation, CancellationToken ct) =>
        await DialogAsync(title, Ui.Text(explanation), T("确认", "Confirm"), ct) == ContentDialogResult.Primary;
    private async Task<string?> PromptAsync(string title, string detail, string initial, CancellationToken ct)
    {
        var input = new TextBox { Text = initial, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxLength = CredentialImport.MaximumBytes, MinWidth = 340, MaxHeight = 260 };
        try { return await DialogAsync(title, Ui.Stack(Ui.Text(detail, 13, true), input), T("继续", "Continue"), ct) == ContentDialogResult.Primary ? input.Text : null; }
        finally { input.Text = ""; }
    }
    private async Task AuthorizeAsync(Provider provider, CancellationToken ct)
    {
        Credential credential;
        if (provider == Provider.Codex) credential = await engine.Accounts.AuthorizeCodexAsync(DesktopActions.OpenBrowserAsync, ct);
        else {
            using var flow = new OAuthSession(provider, engine.Client);
            await DesktopActions.OpenBrowserAsync(flow.AuthorizationUri);
            if (provider == Provider.Claude) {
                var code = await PromptAsync(T("完成 Claude 授权", "Complete Claude authorization"), T("在浏览器授权后粘贴返回的授权码。此尝试仅有效 10 分钟。", "After browser authorization, paste the returned code. This attempt expires after 10 minutes."), "", ct);
                if (code is null) return;
                credential = await flow.ExchangeClaudeAsync(code, ct);
            } else credential = await flow.WaitForGoogleAsync(ct);
        }
        var result = await engine.Accounts.ImportAsync(credential, "independent", true, null, ct);
        ShowNotice(result.Message ?? T("账号已授权并验证", "Account authorized and verified"));
    }
    private static async Task<string> ReadBoundedAsync(string path, int maximumBytes, CancellationToken ct)
    {
        path = SecureFiles.RequireRegularFile(path);
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        if (stream.Length > maximumBytes) throw new InvalidDataException("File exceeds import limit.");
        using var bytes = new MemoryStream(); byte[] buffer = new byte[65536];
        try {
            int read;
            while ((read = await stream.ReadAsync(buffer, ct)) > 0) {
                if (bytes.Length + read > maximumBytes) throw new InvalidDataException("File exceeds import limit.");
                bytes.Write(buffer, 0, read);
            }
            return new UTF8Encoding(false, true).GetString(bytes.GetBuffer(), 0, (int)bytes.Length).TrimStart('\ufeff');
        } finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(buffer); System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes.GetBuffer()); }
    }
    private async Task ImportFileAsync(Provider provider, CancellationToken ct)
    {
        if (await DesktopActions.OpenFileAsync(Handle, ".json", ".txt") is not { } path) return;
        if (!await ConfirmAsync(T("导入查询凭据", "Import query credentials"), T("每项都会向对应服务验证。导入令牌可能与原客户端共享续期链；不会使用文件中的任意服务器地址。", "Each item will be verified with its service. Imported tokens can share the original client's renewal chain. Arbitrary server addresses in the file are ignored."), ct)) return;
        await ImportCandidatesAsync(provider, await ReadBoundedAsync(path, CredentialImport.MaximumBytes, ct), ct);
    }
    private async Task ImportTextAsync(Provider provider, CancellationToken ct)
    {
        var text = await PromptAsync(T("导入 JSON / Token", "Import JSON / token"), T("仅用于查询的 OAuth 凭据，不接受 API Key。导入令牌可能与原客户端共享续期链。不会保存此输入到日志。", "Query OAuth credentials only; API keys are not accepted. Imported tokens may share a renewal chain with another client. This input is not logged."), "", ct);
        if (text is not null) await ImportCandidatesAsync(provider, text, ct);
    }
    private async Task ImportCandidatesAsync(Provider provider, string text, CancellationToken ct)
    {
        var items = CredentialImport.Parse(text, provider); int saved = 0, unchanged = 0, failed = 0;
        var errors = new List<string>();
        for (int i = 0; i < items.Count; i++) {
            ct.ThrowIfCancellationRequested(); footer.Text = T("验证导入 ", "Validating import ") + (i + 1) + "/" + items.Count;
            if (items[i].Credential is not { } credential) { failed++; errors.Add((i + 1) + ": " + items[i].Error); continue; }
            try { var result = await engine.Accounts.ImportAsync(credential, "imported", true, null, ct); if (result.Changed) saved++; else unchanged++; }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) { failed++; errors.Add((i + 1) + ": " + SafeErrors.Describe(error).Message); }
        }
        ShowNotice(T("导入/更新 ", "Imported/updated ") + saved + T("，未变更 ", ", unchanged ") + unchanged + T("，失败 ", ", failed ") + failed + (errors.Count == 0 ? "" : "\n" + string.Join("\n", errors.Take(10))));
    }
    private async Task RenameAsync(Account account, CancellationToken ct)
    {
        var alias = await PromptAsync(T("账号备注", "Account name"), account.Name, account.Alias ?? "", ct);
        if (alias is not null) await engine.Accounts.RenameAsync(account.Key, alias, ct);
    }
    private async Task ExportAsync(string[] keys, CancellationToken ct)
    {
        if (!await ConfirmAsync(T("导出文件包含明文 Token", "Export contains plaintext tokens"), T("任何获得此文件的人都可能使用你的账号授权。请勿上传到仓库、聊天或共享目录。导出不包含本地主密钥，也不会触发续期。", "Anyone with this file may use your authorization. Do not upload it to a repository, chat or shared directory. The local master key is excluded and export does not renew tokens."), ct)) return;
        if (await DesktopActions.SaveFileAsync(Handle, "QuotaLens-credentials", ".json", "JSON") is not { } path) return;
        string json = await engine.Accounts.ExportAsync(keys, ct);
        await Task.Run(() => SecureFiles.AtomicWrite(path, Encoding.UTF8.GetBytes(json)), ct); ShowNotice(T("凭据已导出，请妥善保管", "Credentials exported; keep the file secure"));
    }
    private async Task RedeemAsync(string key, string credit, bool retry, CancellationToken ct)
    {
        string name = engine.Accounts.View(key)?.Account.DisplayName ?? key;
        if (!await ConfirmAsync(T("确认消耗重置权益？", "Confirm reset redemption?"), name + "\n" + (retry ? T("前次结果不确定。本次只重试同一持久化请求标识，不创建新的消费请求。", "The previous result is uncertain. This retries the same durable idempotency key, not a new redemption.") : T("这将消耗此账号的一张实际重置卡，不能撤销。", "This consumes one real reset credit for this account and cannot be undone.")), ct)) return;
        string outcome = await engine.Accounts.ConsumeCreditAsync(key, credit, retry, ct);
        ShowNotice(T("服务端结果：", "Server result: ") + outcome);
        await engine.Accounts.LoadCreditsAsync(key, ct);
    }
    private async Task ShowResetHistoryAsync(string key, CancellationToken ct)
    {
        string? cursor = null;
        do {
            var result = await engine.Accounts.ResetHistoryAsync(key, cursor, ct);
            var content = Ui.Stack(Ui.Text(T("数据截止：", "As of: ") + Ui.Date(result.AsOf), 12, true));
            foreach (var row in result.Events) content.Children.Add(Ui.Text(Ui.Date(row.OccurredAt) + " · " + row.Kind));
            if (result.Events.Count == 0) content.Children.Add(Ui.Text(T("此窗口暂无记录", "No events in this window")));
            var answer = await DialogAsync(T("服务端重置历史", "Server reset history"), new ScrollViewer { Content = content, MaxHeight = 480 }, result.NextCursor is null ? null : T("下一页", "Next page"), ct);
            cursor = answer == ContentDialogResult.Primary ? result.NextCursor : null;
        } while (cursor is not null);
    }
}
