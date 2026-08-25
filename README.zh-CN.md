# QuotaLens

[English](README.md)

QuotaLens 是一个原生 macOS 菜单栏应用，用来监测 Codex 与 ChatGPT 的额度使用情况。它会读取本机 Codex 登录状态，并以紧凑桌面视图展示额度消耗、重置倒计时、订阅状态和重置卡可用情况。

## 功能

- 菜单栏概览：显示本周已用/剩余额度、重置倒计时、订阅周期、刷新状态和重置卡储备。
- 原生 SwiftUI 仪表盘：支持浅色、深色、跟随系统三种外观。
- 从 `~/.codex/auth.json` 自动发现本地 Codex 账号身份。
- 通过 `codex app-server --stdio` 读取账号与 rate-limit 服务端快照。
- 使用本地 ChatGPT access token 补齐订阅权益信息，识别自动续订、即将结束、计划变更等状态。
- 重置卡到期提醒，支持确认和稍后提醒。
- 本地 SQLite 持久化，数据库位于 `~/Library/Application Support/QuotaLens/quotalens.sqlite`。
- 从 `~/.codex/sessions` 以及可选的 `~/.codex/archived_sessions` 解析本地 Codex 用量，提供 Sessions、History、Dashboard、模型构成、缓存命中率和 Token 趋势视图。
- API 等价价值估算标记为 Beta，仅按 OpenAI API 官方列表价做对比，不是 ChatGPT/Codex 订阅账单或实际扣款。
- 本地分析只保存最小事件事实：时间、模型、Token 分桶、计价状态、来源路径和字节偏移，不保存 prompt、回答或工具输出正文。
- 本地索引诊断：未知模型、未计价事件、时间戳兜底、Parser 版本、当前价格目录、文件重写和 tombstone 源，并可导出隐私安全的聚合诊断 JSON。
- 支持调整刷新频率、自定义 Codex CLI 路径、开机自启动、隐藏 Dock 图标的纯菜单栏模式。
- 可独立关闭窗口悬浮挂件，不影响本地用量分析。基础模式无需辅助功能权限；精确吸附由用户主动开启，仅读取目标窗口的位置、尺寸和最小化状态。
- 内置多语言：英文、简体中文、繁体中文、日文、韩文、西班牙文、德文、法文、葡萄牙文、巴西葡萄牙文。

## 运行要求

- macOS 14 或更高版本。
- Swift 6 工具链，或带 Swift 6 支持的 Xcode。
- 可用的 `codex` CLI。
- 已在本机登录 Codex/ChatGPT，通常凭据位于 `~/.codex/auth.json`。

## 构建和运行

在项目根目录运行：

```bash
swift run QuotaLens
```

构建 Release 二进制：

```bash
swift build -c release
```

生成已签名的 `.app`、`.zip` 和 `.dmg` 安装包：

```bash
./scripts/build_and_package.sh --arch universal
```

打包脚本默认使用 ad-hoc 本地签名。如果需要使用 Developer ID 证书签名，可以在执行前设置 `DEVELOPER_ID_APPLICATION`：

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" ./scripts/build_and_package.sh
```

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

QuotaLens 会在常见安装路径和 `PATH` 中查找 Codex CLI。连接时，它会启动一个短生命周期的 `codex app-server --stdio` 进程，请求账号与额度快照。应用也会读取本地 Codex 登录元数据来识别当前账号，并在可用时刷新 ChatGPT 订阅权益信息。

应用使用自己的本地 SQLite 数据库保存状态、额度快照、本地用量汇总、最小用量事件事实、价格目录元数据和对账元数据。构建产物、打包后的应用、本地临时文件、凭据和机器相关文件都不会纳入仓库。

你可以在设置中关闭本地用量分析。设置页也提供「立即扫描」「重新建立索引」和隐私安全的诊断 JSON 导出。重新建立索引会清除 Codex 用量派生聚合，并从当前本地 Codex 文件重新生成；不会删除账号、订阅或额度快照。

## 隐私说明

QuotaLens 是一个本地桌面工具。它会读取你 Mac 上的 Codex 配置和会话文件，并把派生出的应用数据保存在本地 SQLite 中。用量分析只保存 Token 数量、模型标识、时间戳、计价状态、来源路径和字节偏移，不保存 prompt、回答或工具输出正文。导出的诊断文件只含聚合计数，不含来源路径；精确悬浮吸附也不会读取窗口文本。订阅权益刷新会使用你本机已有的 ChatGPT access token 调用 ChatGPT 账号接口。

API 等价价值只是按 API 列表价做出的诊断对比，不是订阅账单、发票或实际扣款。未知模型会保持未计价并进入诊断统计，不会被静默映射到默认模型。

## 授权

本项目使用 Apache License, Version 2.0 授权。详见 [LICENSE](LICENSE)。
