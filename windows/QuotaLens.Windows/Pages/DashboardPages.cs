using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using QuotaLens.Core;
using QuotaLens.Infrastructure;
using QuotaLens.Windows.UI;

namespace QuotaLens.Windows;

public sealed partial class MainWindow
{
    private int rangeDays = 7, historyOffset;
    private async Task RenderPageAsync()
    {
        if (!ready || closing) return;
        long generation = ++pageGeneration;
        pageCancellation.Cancel(); pageCancellation.Dispose();
        pageCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var ct = pageCancellation.Token;
        Provider? provider = SelectedProvider; string? key = SelectedKey; string destination = page;
        try {
            UIElement content = destination switch {
                "summary" => await OverviewPageAsync(ct),
                "distribution" => await UsagePageAsync(null, ct),
                "quota" when provider is { } p => QuotaPage(p, key),
                "forecast" when key is not null && provider == Provider.Codex => await ForecastPageAsync(key, ct),
                "usage" => provider == Provider.Antigravity ? await ActivitiesPageAsync(ct) : await UsagePageAsync(provider, ct),
                "history" when key is not null => await HistoryPageAsync(key, ct),
                "sessions" => provider == Provider.Antigravity ? await ActivitiesPageAsync(ct) : await SessionsPageAsync(provider, ct),
                "credits" when key is not null && provider == Provider.Codex => await CreditsPageAsync(key, ct),
                "accounts" => AccountsPage(provider),
                "settings" or "tool-settings" => SettingsPage(destination == "tool-settings" ? provider : null),
                "desktop" => DesktopPage(),
                "recovery" => await RecoveryPageAsync(ct),
                "about" => AboutPage(),
                _ => Ui.Scroll(Ui.Stack(Ui.Empty(T("请先添加并验证账号", "Add and verify an account first"), T("未读取到额度时不会显示为零。", "Missing quota is never shown as zero.")), Ui.Button(T("管理账号", "Manage accounts"), () => Navigate("accounts"))))
            };
            ct.ThrowIfCancellationRequested();
            if (generation == pageGeneration && !closing) pageHost.Content = content;
        } catch (OperationCanceledException) { }
        catch (Exception error) {
            if (generation == pageGeneration && !closing) {
                ShowError(error); pageHost.Content = Ui.Scroll(Ui.Empty(T("暂时无法读取此页面", "This page is temporarily unavailable"), SafeErrors.Describe(error).Message));
            }
        }
    }
    private UIElement AccountSelector(Provider provider, string? key)
    {
        var picker = new ComboBox { Header = T("当前查询账号", "Viewing account"), MinWidth = 250, MaxWidth = 560 };
        foreach (var view in engine.Accounts.Views.Where(x => x.Account.Provider == provider))
            picker.Items.Add(new ComboBoxItem { Content = view.Account.DisplayName, Tag = view.Account.Key });
        picker.SelectedItem = picker.Items.OfType<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == key);
        picker.SelectionChanged += (_, _) => {
            if (picker.SelectedItem is ComboBoxItem selected) { historyOffset = 0; sessionOffset = 0; StartAction(ct => engine.SelectAccountAsync(provider, (string)selected.Tag, ct)); }
        };
        return Ui.Stack(picker, Ui.Text(T("仅切换查询身份，不改变工具登录；本机历史仍独立统计。", "Changes only the query identity, not the tool login. Local history remains separate."), 12, true));
    }
    private Border QuotaCard(Provider provider, string? key, bool link = false)
    {
        var view = engine.Accounts.View(key);
        var content = Ui.Stack(Ui.Heading(provider.ToString(), 20));
        if (!engine.Settings.EnabledTools.Contains(provider)) {
            content.Children.Add(Ui.Text(T("监控未启用", "Monitoring disabled"), 14, true));
        } else if (view is null) {
            content.Children.Add(Ui.Text(T("尚未添加已验证的账号", "No verified account yet"), 14, true));
            content.Children.Add(Ui.Button(T("添加账号", "Add account"), () => { context = provider.ToString(); Navigate("accounts"); }));
        } else {
            content.Children.Add(Ui.Text(view.Account.DisplayName + "  ·  " + (view.Quota?.Plan ?? T("套餐未提供", "Plan not supplied")), 12, true));
            if (view.Quota is { } snapshot) {
                bool stale = DateTimeOffset.UtcNow - snapshot.ObservedAt > TimeSpan.FromSeconds(engine.Settings.RefreshSeconds * 2);
                content.Children.Add(Ui.Text((stale || view.Status.Failure is not null ? T("缓存快照 · ", "Cached snapshot · ") : T("更新时间 · ", "Updated · ")) + Ui.Date(snapshot.ObservedAt), 12, true));
                foreach (var pool in snapshot.Pools) content.Children.Add(Ui.Pool(pool, provider, engine.Settings.ShowRemaining, snapshot.ObservedAt));
            } else content.Children.Add(Ui.Text(T("暂无已验证额度数据", "No verified quota data available"), 14, true));
            if (view.Status.Message is { Length: > 0 } status) content.Children.Add(Ui.Text(status, 12, true));
        }
        if (link) content.Children.Add(Ui.Button(T("查看详情 →", "View details →"), () => { context = provider.ToString(); Navigate("quota"); }));
        return Ui.Card(content);
    }
    private async Task<UIElement> OverviewPageAsync(CancellationToken ct)
    {
        var content = Ui.Stack(Ui.Heading(T("概况", "At a glance"), 28),
            Ui.Text(T("先看各工具可用额度，再看这台电脑上的使用情况。", "Check each tool's quota, then this computer's activity."), 14, true));
        if (engine.Settings.EnabledTools.Length == 0) {
            content.Children.Add(Ui.Empty(T("欢迎使用 QuotaLens", "Welcome to QuotaLens"), T("请在应用设置中启用需要监控的工具。未启用的工具不会被扫描或查询。", "Enable the tools you use in App settings. Disabled tools are not scanned or queried.")));
            content.Children.Add(Ui.Button(T("设置监控工具", "Set up monitoring"), () => Navigate("settings")));
        } else {
            content.Children.Add(Ui.Text(T("各工具额度独立，不合并百分比。", "Quota pools stay separate; percentages are never combined."), 12, true));
            content.Children.Add(Ui.Columns(engine.Settings.EnabledTools.Select(tool => (UIElement)QuotaCard(tool, engine.ViewingKey(tool), true))));
        }
        var today = new DateTimeOffset(DateTime.Today); var now = DateTimeOffset.UtcNow;
        var report = await engine.Database.UsageAsync(null, today, now, engine.Prices, ct);
        content.Children.Add(Metrics(report, T("今日已索引本机", "Indexed locally today")));
        var week = await engine.Database.UsageAsync(null, today.AddDays(-6), now, engine.Prices, ct);
        content.Children.Add(Ui.Buckets(T("近 7 天本机 Token", "Local tokens · last 7 days"), week.Days));
        content.Children.Add(Ui.Card(Ui.Stack(Ui.Heading(T("需要关注", "Attention"), 17),
            Ui.Text(T("云端累计 Token 不与本机会话相加。Antigravity 任务数、步骤数不换算为 Token。", "Cloud lifetime counters are not added to local sessions. Antigravity task and step counts are not tokens."), 13, true),
            Ui.Button(T("管理账号", "Manage accounts"), () => Navigate("accounts")))));
        return Ui.Scroll(content);
    }
    private UIElement Metrics(UsageReport report, string prefix) => Ui.Columns(new UIElement[] {
        Ui.Card(Ui.Stack(Ui.Text(prefix + " Token", 12, true), Ui.Heading(Ui.Number(report.Tokens), 28))),
        Ui.Card(Ui.Stack(Ui.Text(T("本机会话", "Local sessions"), 12, true), Ui.Heading(report.Sessions.ToString("N0"), 28))),
        Ui.Card(Ui.Stack(Ui.Text(T("API 参考价值 · 估算", "API reference value · estimate"), 12, true), Ui.Heading(report.ApiValue is { } price ? "$" + price.ToString("N2") : "—", 28),
            Ui.Text(T("标准参考价，非账单；未计价记录 ", "Standard reference, not a bill; unpriced: ") + report.UnpricedEvents, 11, true)))
    });
    private UIElement QuotaPage(Provider provider, string? key)
    {
        var content = Ui.Stack(Ui.Heading(T("额度概览", "Quota overview"), 28), AccountSelector(provider, key), QuotaCard(provider, key));
        if (provider == Provider.Codex && key is not null) {
            var subscription = engine.Accounts.View(key)?.Subscription;
            var detail = Ui.Stack(Ui.Heading(T("ChatGPT 订阅", "ChatGPT subscription"), 18));
            if (subscription is not null) {
                detail.Children.Add(Ui.Text((subscription.Plan ?? "—") + "  ·  " + (subscription.Active is true ? T("有效", "Active") : subscription.Active is false ? T("未激活", "Inactive") : T("状态未提供", "Status not supplied"))));
                detail.Children.Add(Ui.Text(T("续期：", "Renewal: ") + Ui.Date(subscription.RenewsAt) + T("  到期：", "  Expiry: ") + Ui.Date(subscription.ExpiresAt), 13, true));
                detail.Children.Add(Ui.Text(T("权益更新时间：", "Entitlements updated: ") + Ui.Date(subscription.ObservedAt), 12, true));
            } else detail.Children.Add(Ui.Text(T("仅展示接口实际返回的订阅权益；没有数据时不推测到期日。", "Only returned subscription entitlements are shown. Missing expiry dates are not inferred."), 13, true));
            detail.Children.Add(Ui.Button(T("刷新订阅权益", "Refresh subscription"), () => StartAction(async ct => { await engine.Accounts.SubscriptionAsync(key, ct); })));
            content.Children.Add(Ui.Card(detail));
        }
        return Ui.Scroll(content);
    }
    private async Task<UIElement> UsagePageAsync(Provider? provider, CancellationToken ct)
    {
        var selector = new ComboBox { Header = T("时间范围", "Time range"), MinWidth = 160 };
        foreach (int days in new[] { 1, 7, 30, 90 }) selector.Items.Add(new ComboBoxItem { Content = days + T(" 天", " days"), Tag = days });
        selector.SelectedItem = selector.Items.OfType<ComboBoxItem>().First(x => (int)x.Tag == rangeDays);
        selector.SelectionChanged += (_, _) => { if (selector.SelectedItem is ComboBoxItem item) { rangeDays = (int)item.Tag; _ = RenderPageAsync(); } };
        var from = new DateTimeOffset(DateTime.Today).AddDays(1 - rangeDays);
        var report = await engine.Database.UsageAsync(provider, from, DateTimeOffset.UtcNow, engine.Prices, ct);
        var content = Ui.Stack(Ui.Heading(T("用量分析", "Usage analytics"), 28), selector,
            Ui.Text(T("数据范围：本机已解析记录，与查询账号选择无关。缺失来源不补零。", "Scope: parsed local records, independent of the viewing account. Missing sources are not filled with zero."), 13, true), Metrics(report, T("本机", "Local")));
        content.Children.Add(Ui.Columns(new[] { Ui.Buckets(T("用量趋势", "Usage trend"), report.Days), Ui.Buckets(T("模型构成", "Model distribution"), report.Models) }, 2));
        content.Children.Add(Ui.Columns(new UIElement[] {
            Ui.Card(Ui.Stack(Ui.Heading(T("缓存与输出", "Cache & output"), 17),
                Ui.Text(T("输入：", "Input: ") + Ui.Number(report.Input)), Ui.Text(T("缓存命中：", "Cache hits: ") + Ui.Number(report.Cached)),
                Ui.Text(T("输出：", "Output: ") + Ui.Number(report.Output)), Ui.Text(T("缓存写入：", "Cache writes: ") + Ui.Number(report.CacheWrite)))),
            Ui.Buckets(T("推理级别", "Reasoning effort"), report.Efforts)
        }, 2));
        content.Children.Add(Ui.Text(T("API 参考价值使用内置目录的标准短上下文参考价，不是历史账单、Fast/Flex 价格或订阅扣费；未知模型和不明确的缓存写入保持未计价。", "API reference value uses bundled standard short-context rates, not historical bills, Fast/Flex rates or subscription charges. Unknown models and ambiguous cache writes remain unpriced.") + " · " + StandardPriceCatalog.Version, 12, true));
        return Ui.Scroll(content);
    }
    private async Task<UIElement> ForecastPageAsync(string key, CancellationToken ct)
    {
        var windows = await engine.Database.ForecastAsync(key, ct);
        var content = Ui.Stack(Ui.Heading(T("额度预测 · 观测估算", "Quota forecast · observational estimate"), 28), AccountSelector(Provider.Codex, key),
            Ui.Text(T("只使用同一已验证账号的云端累计 Token 与额度观测；不是官方容量或降额结论。", "Uses verified cloud lifetime tokens and quota observations for the same account. This is not an official capacity or throttling assessment."), 13, true));
        foreach (var window in windows) {
            var current = window.Current;
            var card = Ui.Stack(Ui.Heading(window.Minutes == 300 ? T("5 小时窗口", "5-hour window") : T("7 天窗口", "7-day window"), 20),
                Ui.Text(T("本周期估算容量：", "Estimated cycle capacity: ") + (current?.Capacity is { } capacity ? Ui.Number(capacity) + " tokens" : T("等待有效观测", "Waiting for valid observations"))),
                Ui.Text(T("当前剩余估算：", "Estimated remaining: ") + (window.Available && current?.RemainingTokens is { } left ? Ui.Number(left) + " tokens" : "—")),
                Ui.Text(T("下一周期估算：", "Next cycle estimate: ") + (window.Prediction is { } prediction ? Ui.Number(prediction.Tokens) + T(" · 周期样本 ", " · cycle samples ") + prediction.SampleCount : "—")));
            if (current?.AwaitingCloudUsage == true) card.Children.Add(Ui.Text(T("等待云端用量更新；保留上次有效估算。", "Waiting for cloud usage; keeping the last valid estimate."), 13, true));
            foreach (var cycle in window.Cycles.TakeLast(10).Reverse()) card.Children.Add(Ui.Text(
                Ui.Date(DateTimeOffset.FromUnixTimeSeconds(cycle.StartAt)) + "  ·  " + (cycle.Capacity is { } value ? Ui.Number(value) : "—") + "  ·  " + (cycle.EndReason ?? T("进行中", "Current")), 12, true));
            content.Children.Add(Ui.Card(card));
        }
        if (windows.Count == 0) content.Children.Add(Ui.Empty(T("正在等待观测", "Waiting for observations"), T("配置 codex.exe 并刷新额度以采集云端累计用量；至少积累 10 个百分点的有效配对消耗才显示容量。", "Configure codex.exe and refresh quota to collect cloud counters. At least 10 percentage points of paired consumption are required to show capacity.")));
        return Ui.Scroll(content);
    }
    private async Task<UIElement> HistoryPageAsync(string key, CancellationToken ct)
    {
        var values = await engine.Database.QuotaHistoryAsync(key, historyOffset, 100, ct);
        var content = Ui.Stack(Ui.Heading(T("额度快照历史", "Quota snapshot history"), 28), AccountSelector(engine.Accounts.View(key)!.Account.Provider, key));
        foreach (var snapshot in values) content.Children.Add(Ui.Card(Ui.Stack(Ui.Heading(Ui.Date(snapshot.ObservedAt), 16),
            Ui.Text(string.Join("\n", snapshot.Pools.Select(pool => pool.Title + " · " + T("已用 ", "Used ") + pool.UsedPercent.ToString("0.#") + "% · " + Ui.Date(pool.ResetsAt))), 13, true))));
        if (values.Count == 0) content.Children.Add(Ui.Empty(T("暂无历史快照", "No historical snapshots"), T("成功查询后会自动保存在本机。", "Successful queries are saved locally.")));
        content.Children.Add(Ui.Row(Ui.Button(T("上一页", "Previous"), () => { historyOffset = Math.Max(0, historyOffset - 100); _ = RenderPageAsync(); }),
            Ui.Text((historyOffset / 100 + 1).ToString()), Ui.Button(T("下一页", "Next"), () => { if (values.Count == 100) { historyOffset += 100; _ = RenderPageAsync(); } })));
        return Ui.Scroll(content);
    }
    private async Task<UIElement> CreditsPageAsync(string key, CancellationToken ct)
    {
        var view = engine.Accounts.View(key)!;
        var content = Ui.Stack(Ui.Heading(T("重置卡", "Reset cards"), 28), AccountSelector(Provider.Codex, key),
            Ui.Text(T("使用重置卡会消耗实际权益，每次操作都需要确认；查询和后台刷新不会自动使用。", "Redeeming a reset consumes a real entitlement and requires confirmation. Queries and background refresh never redeem credits."), 13, true),
            Ui.Button(T("刷新重置卡", "Refresh reset cards"), () => StartAction(async token => { await engine.Accounts.LoadCreditsAsync(key, token); })));
        if (view.Extended is { } extra) {
            content.Children.Add(Ui.Heading(T("可用数量：", "Available: ") + (extra.AvailableCredits?.ToString() ?? T("未提供", "Not supplied"))));
            content.Children.Add(Ui.Text(T("数据时间：", "Observed: ") + Ui.Date(extra.Quota.ObservedAt), 12, true));
            foreach (var credit in extra.Credits) {
                var card = Ui.Stack(Ui.Heading(credit.Status ?? T("状态未提供", "Status not supplied"), 16), Ui.Text(T("到期：", "Expires: ") + Ui.Date(credit.ExpiresAt), 13, true));
                if (credit.Available(DateTimeOffset.UtcNow)) card.Children.Add(Ui.Button(T("使用此重置卡", "Redeem this reset"), () => StartAction(token => RedeemAsync(key, credit.Id, false, token))));
                content.Children.Add(Ui.Card(card));
            }
        } else content.Children.Add(Ui.Empty(T("尚未读取重置卡详情", "Reset details have not been fetched"), T("需要支持此接口的 codex.exe；没有真实卡片标识时不提供消费按钮。", "Requires a codex.exe version supporting this API. No redeem action is offered without a real credit identifier.")));
        foreach (var request in await engine.Database.RedemptionsAsync(key, ct)) {
            var detail = Ui.Stack(Ui.Text(request.State + " · " + Ui.Date(request.CreatedAt), 13, true));
            if (request.State is "uncertain" or "pending") detail.Children.Add(Ui.Button(T("核查并重试此请求", "Check and retry this request"), () => StartAction(token => RedeemAsync(key, request.CreditId, true, token))));
            content.Children.Add(Ui.Card(detail));
        }
        content.Children.Add(Ui.Button(T("查看服务端使用历史", "View server reset history"), () => StartAction(token => ShowResetHistoryAsync(key, token))));
        return Ui.Scroll(content);
    }
    private async Task<UIElement> ActivitiesPageAsync(CancellationToken ct)
    {
        var values = await engine.Database.ActivitiesAsync(ct);
        var content = Ui.Stack(Ui.Heading(T("Antigravity 本机活动", "Antigravity local activity"), 28),
            Ui.Text(T("任务与步骤单独统计，不转换为 Token。只读取受支持的聚合记录，不复制对话正文。", "Tasks and steps are counted separately, never converted to tokens. Only supported aggregate records are read; conversation bodies are not copied."), 13, true),
            Ui.Button(T("刷新本机活动", "Refresh local activity"), () => StartAction(ct2 => RefreshActivitiesAsync(ct2))));
        foreach (var item in values.Take(300)) content.Children.Add(Ui.Card(Ui.Stack(Ui.Heading(item.Project.Length == 0 ? item.Id : item.Project, 16),
            Ui.Text(item.Profile + " · " + Ui.Date(item.At) + " · " + T("步骤：", "Steps: ") + (item.Steps?.ToString() ?? "—"), 12, true))));
        if (values.Count == 0) content.Children.Add(Ui.Empty(T("暂无已解析的活动记录", "No parsed activity records"), T("自动检查本机 Antigravity 配置，也可在工具设置指定状态文件；未知格式不会覆盖已有历史。", "Local Antigravity profiles are discovered automatically; Tool settings can override the state file. Unrecognized formats retain existing history.")));
        return Ui.Scroll(content);
    }
}
