# QuotaLens

[English](README.md)

QuotaLens 是一个面向 Codex、Claude 与 Antigravity 的原生 macOS 菜单栏看板。它把跨工具额度、用量分析、重置预测、恢复提醒和随前台工具切换的窗口挂件集中到一处，同时展示 Codex 账号对应的 ChatGPT 订阅与重置卡状态。

## 功能

### 跨工具额度与预测

- 可分别启用 Codex、Claude 和 Antigravity，并在统一总览与各工具的独立空间之间切换。
- 按工具展示可用的 5 小时、7 天、周度及模型额度池，支持已用/可用视角、重置时间和数据新鲜度状态。
- 自动找出最吃紧的额度池，对比当前消耗速度与可持续节奏，预测耗尽或重置结果，并给出可执行建议。
- 周额度完全恢复时显示悬浮提醒；Codex 空间还会展示 ChatGPT 订阅状态、重置卡余量和到期时间。

### 用量与活动分析

- Codex 将云端账户活动与本机 Sessions、History、Dashboard 结合，展示 Token、模型构成、推理级别、缓存命中率、趋势和 API 等价价值估算。
- Codex 对话回放和全文搜索只在需要时读取原始 rollout 文件；删除会话会把对应源文件树移到 macOS 废纸篓，并清理派生索引。
- Claude 展示 5 小时、7 天和模型周额度，并从 `~/.claude/projects` 与 `~/.config/claude/projects` 增量汇总本机会话和用量。
- Antigravity 展示额度池趋势、模型余量、节奏预测，以及不同本机配置下的任务数、步骤数、活跃天数和项目活动。
- 本地记录、额度快照、趋势历史与诊断信息保存在 `~/Library/Application Support/QuotaLens/quotalens.sqlite`。

### 菜单栏与窗口挂件

- 菜单栏和悬浮挂件会跟随前台的 Codex、Claude 或 Antigravity，自动切换到对应的额度与活动视图。
- 每个工具的窗口挂件都可独立开关、拖动和重置位置。Claude 也可在终端、iTerm 或 VS Code 中自动识别；Codex 精确吸附可按需开启辅助功能权限。
- 支持切换已用/可用额度、调整刷新频率、开机自启动、隐藏 Dock 图标，以及浅色、深色和跟随系统外观。
- 内置英文、简体中文、繁体中文、日文、韩文、西班牙文、德文、法文、葡萄牙文和巴西葡萄牙文，并支持应用内更新和本地化更新日志。

## 运行要求

- macOS 14 或更高版本。
- 从源码构建需要 Swift 6 工具链，或带 Swift 6 支持的 Xcode。
- 监控 Codex 需要可用的 `codex` CLI，以及已登录的本机 Codex/ChatGPT 会话，凭据通常位于 `~/.codex/auth.json`。
- 监控 Claude 需要已登录的 Claude Code。
- 监控 Antigravity 需要已登录的本机 Antigravity。

Codex、Claude 与 Antigravity 均可独立启用或关闭。

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
./scripts/build_and_package.sh
```

打包脚本会自动识别当前 Mac 是 Apple 芯片还是 Intel，只生成对应的单架构安装包，并使用 ad-hoc 本地签名。
本地 ad-hoc 打包会复用对应架构的 Swift 构建缓存，并采用增量优化编译。首次构建仍可能较慢，但未改代码或只有少量修改时会明显加快。需要丢弃缓存时使用 `--clean`；需要复现正式发布的整模块优化时使用 `--full-optimization`。

手动指定构建架构：

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

QuotaLens 只读取你启用的工具。对于 Codex，它会定位 CLI、启动 `codex app-server --stdio`，并读取账号、额度、活动、本机会话和 ChatGPT 订阅权益；对于 Claude，它会使用现有的 Claude Code 登录状态和本地项目记录；对于 Antigravity，它会读取可用的本机登录配置、模型额度组和聚合任务活动。

额度快照及其本地历史会用于生成统一的消耗节奏、耗尽、重置和恢复分析。刷新后的登录数据只保存在 QuotaLens 私有目录，不会修改第三方工具的登录文件。

应用使用自己的本地 SQLite 数据库保存状态、额度快照、本地用量汇总、最小用量事件事实、价格目录元数据和对账元数据。构建产物、打包后的应用、本地临时文件、凭据和机器相关文件都不会纳入仓库。

你可以在设置中分别启用或关闭每个工具。Codex 与 Claude 的本地记录可单独重新扫描，Antigravity 活动也可独立刷新。重新建立 Codex 索引只会清除其派生用量聚合，并从当前本地 rollout 文件重新生成；不会删除账号、订阅或额度快照。设置页还提供隐私安全的聚合诊断 JSON 导出。

## 隐私说明

QuotaLens 是一个本地桌面工具。它只读取已启用工具的配置和本地记录，并把派生数据保存在本机 SQLite 中。用量分析保存 Token 数量、模型标识、时间戳、计价状态、来源路径、字节偏移和 Antigravity 聚合任务信息，而不是对话正文。

只有在打开 Codex 对话或执行全文搜索时，应用才会直接读取原始 rollout 文件；对话内容不会复制到 QuotaLens 的分析数据库。Claude 与 Antigravity 视图不提供对话回放。导出的诊断文件只含聚合计数，不含来源路径。窗口挂件使用应用和窗口位置；可选的 Codex 精确吸附只使用窗口与控件信息定位帮助按钮，不读取对话内容。额度与订阅权益刷新会使用各已启用工具现有的本机登录状态。

API 等价价值只是按 API 列表价做出的诊断对比，不是订阅账单、发票或实际扣款。未知模型会保持未计价并进入诊断统计，不会被静默映射到默认模型。

## 授权

本项目使用 Apache License, Version 2.0 授权。详见 [LICENSE](LICENSE)；第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
