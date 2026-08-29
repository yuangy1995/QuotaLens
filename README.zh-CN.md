# QuotaLens

[English](README.md)

QuotaLens 是一个原生 macOS 菜单栏应用，用来监测 Codex、Claude Code、Antigravity 与 ChatGPT 的额度和本地用量。它以紧凑桌面视图展示额度消耗、重置倒计时、订阅状态和重置卡可用情况。

## 功能

- 菜单栏概览：显示本周已用/剩余额度、重置倒计时、订阅周期、刷新状态和重置卡储备。
- 原生 SwiftUI 仪表盘：支持浅色、深色、跟随系统三种外观。
- 从 `~/.codex/auth.json` 自动发现本地 Codex 账号身份。
- 通过 `codex app-server --stdio` 读取账号与 rate-limit 服务端快照。
- 展示 Codex 额外模型额度，以及云端账户累计 Token、峰值日、最长任务、连续活跃天数和每日活动。
- Claude Code 追踪默认关闭；启用后读取 5 小时、7 天和模型周额度，并增量汇总 `~/.claude/projects` 与 `~/.config/claude/projects` 的本地用量。
- Antigravity 追踪默认关闭；启用后读取本机登录状态，显示 Gemini 与 Claude/GPT 模型组的 5 小时、7 天额度，并统计本机任务活动。
- 菜单栏弹窗和窗口悬浮挂件会根据当前前台的 Codex、Claude 或 Antigravity 自动切换显示内容。
- Sessions、History 和 Dashboard 支持全部、Codex、Claude 三种来源筛选；菜单栏读数可选择 Codex、Claude 或同时显示。
- 使用本地 ChatGPT access token 补齐订阅权益信息，识别自动续订、即将结束、计划变更等状态。
- 重置卡到期提醒，支持确认和稍后提醒。
- 本地 SQLite 持久化，数据库位于 `~/Library/Application Support/QuotaLens/quotalens.sqlite`。
- 从 `~/.codex/sessions` 以及可选的 `~/.codex/archived_sessions` 解析本地 Codex 用量，提供 Sessions、History、Dashboard、模型构成、缓存命中率和 Token 趋势视图。
- 用量柱状图和年度热力图的明细卡会跟随鼠标并自动避开边缘；悬浮反馈只绘制在覆盖层中，不会再改变热力图尺寸或引起跳动。
- 会话列表支持右键「删除」；子代理详情提供「返回主会话」按钮，搜索工具栏只保留一个含义明确的筛选/排序图标。确认删除后会把所选会话树对应的 Codex rollout 源文件移到 macOS 废纸篓，并清理本地派生索引；源文件可从废纸篓恢复。
- API 等价价值估算标记为 Beta，仅按 OpenAI API 官方列表价做对比，不是 ChatGPT/Codex 订阅账单或实际扣款。
- 本地分析只保存最小事件事实：时间、模型、Token 分桶、计价状态、来源路径和字节偏移，不保存 prompt、回答或工具输出正文。
- 本地索引诊断：未知模型、未计价事件、时间戳兜底、Parser 版本、当前价格目录、文件重写和 tombstone 源，并可导出隐私安全的聚合诊断 JSON。
- 支持调整刷新频率、自定义 Codex CLI 路径、开机自启动、隐藏 Dock 图标的纯菜单栏模式。
- 点击 Dock 图标只会聚焦主窗口；额度浮窗只会由菜单栏状态图标打开。
- 当可用额度降为 0 时，主页和菜单栏会显示「已用尽、等待重置」状态，并停止生成额度节奏预测。
- Codex 窗口悬浮挂件默认开启，也可独立关闭而不影响本地用量分析。Codex 位于后台时挂件保持附着并允许点击穿透；长按后可拖动，悬停可查看详情。基础模式无需辅助功能权限；精确吸附由用户主动开启，用于识别 Codex 窗口和帮助按钮的位置，不读取对话内容。
- 内置多语言：英文、简体中文、繁体中文、日文、韩文、西班牙文、德文、法文、葡萄牙文、巴西葡萄牙文。
- 应用内更新日志跟随所选界面语言；远端简体中文日志不会再覆盖其他语言。

## 运行要求

- macOS 14 或更高版本。
- Swift 6 工具链，或带 Swift 6 支持的 Xcode。
- 可用的 `codex` CLI。
- 已在本机登录 Codex/ChatGPT，通常凭据位于 `~/.codex/auth.json`。
- 如需 Claude 额度与本地历史，请先在 Claude Code 中登录；此功能可保持关闭。

## 构建和运行

在项目根目录运行：

```bash
swift run QuotaLens
```

构建 Release 二进制：

```bash
swift build -c release
```

生成 `.app`、`.zip` 和 `.dmg` 安装包：

```bash
./scripts/build_and_package.sh --arch universal
```

打包脚本使用 ad-hoc 本地签名。

构建不同架构的下载包：

```bash
./scripts/build_and_package.sh --arch apple-silicon
./scripts/build_and_package.sh --arch intel
./scripts/build_and_package.sh --arch universal
```

## 版本号与发布

初始版本是 `v1.0.0`。项目根目录的 [`VERSION`](VERSION) 是版本号的唯一来源。发布版本时：

```bash
git tag -a v1.0.0 -m "QuotaLens v1.0.0"
git push origin main
git push origin v1.0.0
```

推送匹配的 `vX.Y.Z` tag 后，GitHub Actions 会自动构建并发布 Release，上传 Apple Silicon、Intel 和 Universal 三种 macOS 下载包。支持在线升级的版本可以在 App 内检查并安装新版本。完整流程见 [docs/releasing.md](docs/releasing.md)。

## 工作方式

QuotaLens 会在常见安装路径、ChatGPT/Codex App 和登录 Shell 的 `PATH` 中查找 Codex CLI。连接时，它会启动 `codex app-server --stdio`，请求账号、额度和账户活动。应用也会读取本地 Codex 登录元数据来识别当前账号，并在可用时刷新 ChatGPT 订阅权益信息。启用 Claude 后，应用会读取 Claude Code 的本地用量文件，并通过现有登录状态更新额度；启用 Antigravity 后，应用会读取其本地登录状态和活动摘要，并通过对应登录状态更新额度。刷新后的登录数据只保存在 QuotaLens 私有目录，不会修改第三方工具的登录文件。

应用使用自己的本地 SQLite 数据库保存状态、额度快照、本地用量汇总、最小用量事件事实、价格目录元数据和对账元数据。构建产物、打包后的应用、本地临时文件、凭据和机器相关文件都不会纳入仓库。

你可以在设置中关闭本地用量分析。设置页也提供「立即扫描」「重新建立索引」和隐私安全的诊断 JSON 导出。重新建立索引会清除 Codex 用量派生聚合，并从当前本地 Codex 文件重新生成；不会删除账号、订阅或额度快照。

## 隐私说明

QuotaLens 是一个本地桌面工具。它会读取你 Mac 上已启用来源的配置和本地用量文件，并把派生出的应用数据保存在本地 SQLite 中。用量分析只保存 Token 数量、模型标识、时间戳、计价状态、来源路径和字节偏移，不保存 prompt、回答或工具输出正文；Claude 记录不会提供对话回放或删除入口。导出的诊断文件只含聚合计数，不含来源路径；精确悬浮吸附只使用 Codex 窗口和控件信息定位帮助按钮，不读取对话内容。订阅权益刷新会使用你本机已有的 ChatGPT access token 调用 ChatGPT 账号接口。

API 等价价值只是按 API 列表价做出的诊断对比，不是订阅账单、发票或实际扣款。未知模型会保持未计价并进入诊断统计，不会被静默映射到默认模型。

## 授权

本项目使用 Apache License, Version 2.0 授权。详见 [LICENSE](LICENSE)；第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
