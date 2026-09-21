using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using QuotaLens.Core;
using QuotaLens.Infrastructure;
using QuotaLens.Windows.Platform;
using QuotaLens.Windows.UI;

namespace QuotaLens.Windows;

public sealed partial class MainWindow
{
    private int sessionOffset;
    private string sessionSearch = "";

    private async Task<UIElement> SessionsPageAsync(Provider? provider, CancellationToken ct)
    {
        var search = new TextBox { Header = T("搜索会话或项目", "Search sessions or projects"), Text = sessionSearch, MaxLength = 300, MinWidth = 300 };
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, Height = 440,
            HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var records = await engine.Database.SessionsAsync(provider, sessionSearch, sessionOffset, 100, ct);
        foreach (var session in records) {
            list.Items.Add(new ListViewItem { Tag = session, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Content = Ui.Stack(Ui.Heading(string.IsNullOrEmpty(session.Project) ? session.Id : session.Project, 15),
                    Ui.Text(session.Provider + " · " + session.Model + " · " + Ui.Number(session.Tokens) + " tokens · " + Ui.Date(session.UpdatedAt), 12, true),
                    Ui.Text(session.Id, 11, true)) });
        }
        SessionSummary? Selected() => (list.SelectedItem as ListViewItem)?.Tag as SessionSummary;
        var actions = Ui.Row(Ui.Button(T("在资源管理器显示", "Show in Explorer"), () => {
            try { if (Selected() is { } session) DesktopActions.RevealFile(session.Path); } catch (Exception error) { ShowError(error); }
        }));
        if (provider is null or Provider.Codex) {
            actions.Children.Add(Ui.Button(T("打开对话", "Open conversation"), () => StartAction(async token => {
                if (Selected() is not { Provider: Provider.Codex } session) { ShowNotice(T("请选择一条 Codex 会话", "Select a Codex session")); return; }
                var source = (await engine.Database.SourcesAsync(Provider.Codex, token)).FirstOrDefault(x => x.Id == session.SourceId);
                if (source is not null) await TranscriptAsync(source, 0, token);
            })));
            actions.Children.Add(Ui.Button(T("移至恢复中心", "Move to recovery"), () => StartAction(async token => {
                if (Selected() is not { Provider: Provider.Codex } session) { ShowNotice(T("请选择一条 Codex 会话", "Select a Codex session")); return; }
                if (!await ConfirmAsync(T("移走会话源文件？", "Move the source file?"),
                    T("将此会话的单个源文件移入 QuotaLens 本机恢复中心，并移除对应派生索引。原工具将不能在原位置找到它。不会永久删除，可在恢复中心还原；正在写入或跨磁盘的来源会拒绝操作。", "Moves this session's source file into QuotaLens's local recovery folder and removes its derived index. The original tool will no longer find it at that path. This is recoverable, not permanent deletion. Active or cross-volume sources are rejected."), token)) return;
                var source = (await engine.Database.SourcesAsync(Provider.Codex, token)).FirstOrDefault(x => x.Id == session.SourceId);
                if (source is not null) await engine.Recovery.MoveAsync(source, token);
            })));
        }
        var content = Ui.Stack(Ui.Heading(T("本机会话明细", "Local sessions"), 28),
            Ui.Text(T("这里是本机已解析的记录，不会随主窗口查询账号改变归属。正文不写入分析数据库。", "These are parsed local records; changing the viewing account does not reassign them. Conversation bodies are not stored in the analytics database."), 13, true),
            search, Ui.Row(Ui.Button(T("搜索", "Search"), () => { sessionSearch = search.Text.Trim(); sessionOffset = 0; _ = RenderPageAsync(); }),
                Ui.Button(T("重新扫描", "Rescan"), () => StartAction(async token => {
                    foreach (var tool in engine.Settings.EnabledTools.Where(p => p != Provider.Antigravity && (provider is null || p == provider)))
                        await engine.ScanAsync(tool, true, token);
                }))), list, actions,
            Ui.Row(Ui.Button(T("上一页", "Previous"), () => { sessionOffset = Math.Max(0, sessionOffset - 100); _ = RenderPageAsync(); }),
                Ui.Text((sessionOffset / 100 + 1).ToString()), Ui.Button(T("下一页", "Next"), () => { if (records.Count == 100) { sessionOffset += 100; _ = RenderPageAsync(); } })));
        if (records.Count == 0) content.Children.Add(Ui.Empty(T("暂无匹配的会话", "No matching sessions"), T("检查工具设置中的本机目录，或重新扫描。", "Check the local directory in Tool settings or rescan.")));
        if (provider is null or Provider.Codex) content.Children.Add(Ui.Button(T("按需全文搜索 Codex 源文件", "Search Codex source text on demand"), () => StartAction(SearchTranscriptAsync)));
        return Ui.Scroll(content);
    }
    private async Task TranscriptAsync(SourceCheckpoint source, long offset, CancellationToken ct)
    {
        long? next = offset;
        while (next is { } at) {
            var result = await engine.Indexer.TranscriptAsync(source, at, 100, ct);
            var content = Ui.Stack(Ui.Text(T("仅按需读取原始文件，本窗口关闭后不持久化正文。", "Reads the original source on demand. Text is not persisted after this window closes."), 12, true));
            foreach (var line in result.Lines) content.Children.Add(Ui.Card(Ui.Stack(
                Ui.Text(line.Role + " · " + Ui.Date(line.At), 12, true), Ui.Text(line.Text))));
            if (result.Lines.Count == 0) content.Children.Add(Ui.Text(T("此段没有可回放消息", "No replayable messages in this segment")));
            var answer = await DialogAsync(T("Codex 对话", "Codex conversation"),
                new ScrollViewer { Content = content, MaxHeight = 480, MinWidth = 400 },
                result.NextOffset is null ? null : T("继续读取", "Read next segment"), ct);
            next = answer == ContentDialogResult.Primary ? result.NextOffset : null;
        }
    }
    private async Task SearchTranscriptAsync(CancellationToken ct)
    {
        var query = await PromptAsync(T("全文搜索", "Full-text search"), T("只扫描已索引 Codex 的原始文件，可取消；结果最多显示 100 项。", "Searches indexed Codex source files on demand, with cancellation and a 100-result limit."), "", ct);
        if (string.IsNullOrWhiteSpace(query)) return;
        var result = await engine.Indexer.SearchAsync(query.Trim(), ct);
        var list = new ListView { Height = 360, SelectionMode = ListViewSelectionMode.Single, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        foreach (var hit in result.Hits) list.Items.Add(new ListViewItem { Tag = hit, Content = Ui.Stack(Ui.Text(hit.SessionId, 12, true), Ui.Text(hit.Preview)), HorizontalContentAlignment = HorizontalAlignment.Stretch });
        var answer = await DialogAsync(T("搜索结果", "Search results"), Ui.Stack(
            Ui.Text(result.Hits.Count + T(" 项 · 无法读取 ", " results · unreadable ") + result.Failed + (result.Limited ? T(" · 已达到结果上限", " · result limit reached") : ""), 12, true), list),
            result.Hits.Count == 0 ? null : T("打开所选", "Open selected"), ct);
        if (answer == ContentDialogResult.Primary && (list.SelectedItem as ListViewItem)?.Tag is SearchHit hitSelected) {
            var source = (await engine.Database.SourcesAsync(Provider.Codex, ct)).FirstOrDefault(x => x.Id == hitSelected.SourceId);
            if (source is not null) await TranscriptAsync(source, hitSelected.Offset, ct);
        }
    }
    private async Task<UIElement> RecoveryPageAsync(CancellationToken ct)
    {
        var entries = await engine.Database.TrashAsync(ct);
        var content = Ui.Stack(Ui.Heading(T("本机恢复中心", "Local recovery center"), 28),
            Ui.Text(T("这是 QuotaLens 私有的可恢复目录，不是 Windows 回收站。还原不会覆盖原位置已有文件。", "This is QuotaLens's private recovery folder, not the Windows Recycle Bin. Restoring never overwrites an existing source file."), 13, true));
        foreach (var entry in entries) content.Children.Add(Ui.Card(Ui.Stack(Ui.Heading(entry.SessionId, 16),
            Ui.Text(entry.State + " · " + Ui.Date(entry.CreatedAt), 12, true),
            Ui.Text(entry.OriginalPath, 12, true), Ui.Button(T("还原源文件", "Restore source file"), () => StartAction(async token => {
                if (await ConfirmAsync(T("还原会话？", "Restore session?"), T("将源文件放回原位置，并重新建立本地用量索引。", "Returns the source file to its original location and rebuilds its usage index."), token)) await engine.Recovery.RestoreAsync(entry.Id, token);
            })))));
        if (entries.Count == 0) content.Children.Add(Ui.Empty(T("没有待恢复文件", "No files to restore"), T("从会话页面移走的源文件会出现在这里。", "Sources moved from the Sessions page appear here.")));
        return Ui.Scroll(content);
    }
    private async Task RefreshActivitiesAsync(CancellationToken ct)
    {
        // Manual and background refresh must share profile identity and transactional replacement.
        await engine.ScanAsync(Provider.Antigravity, ct: ct);
    }
}
