# QuotaLens

[English](README.md)

QuotaLens 是一个原生 macOS 菜单栏应用，用来监测 Codex 与 ChatGPT 的额度遥测信息。它会读取本机 Codex 登录状态，连接 Codex app server，并以桌面 HUD 的形式展示额度消耗、重置倒计时、订阅状态和重置卡可用情况。

## 功能

- 菜单栏 HUD：显示本周已用/剩余额度、重置倒计时、订阅周期、刷新状态和重置卡储备。
- 原生 SwiftUI 仪表盘：支持浅色、深色 HUD、跟随系统三种外观。
- 从 `~/.codex/auth.json` 自动发现本地 Codex 账号身份。
- 通过 `codex app-server --stdio` 读取账号与 rate-limit 服务端快照。
- 使用本地 ChatGPT access token 补齐订阅权益信息，识别自动续订、即将结束、计划变更等状态。
- 重置卡到期提醒，支持确认和稍后提醒。
- 本地 SQLite 持久化，数据库位于 `~/Library/Application Support/QuotaLens/quotalens.sqlite`。
- 扫描 `~/.codex/sessions` 建立本地会话基线，用于后续归因与对账。
- 支持调整刷新频率、自定义 Codex CLI 路径、开机自启动、隐藏 Dock 图标的纯菜单栏模式。
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
./scripts/build_and_package.sh
```

打包脚本默认使用 ad-hoc 本地签名。如果需要使用 Developer ID 证书签名，可以在执行前设置 `DEVELOPER_ID_APPLICATION`：

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" ./scripts/build_and_package.sh
```

## 工作方式

QuotaLens 会在常见安装路径和 `PATH` 中查找 Codex CLI。连接时，它会启动一个短生命周期的 `codex app-server --stdio` 进程，请求账号与额度快照。应用也会读取本地 Codex 登录元数据来识别当前账号，并在可用时刷新 ChatGPT 订阅权益信息。

应用使用自己的本地 SQLite 数据库保存状态、额度快照、本地用量基线和对账元数据。构建产物、打包后的应用、本地临时文件、凭据和机器相关文件都不会纳入仓库。

## 隐私说明

QuotaLens 是一个本地桌面工具。它会读取你 Mac 上的 Codex 配置和会话文件，并把派生出的应用数据保存在本地 SQLite 中。项目不会把凭据、打包二进制、日志或本地数据库提交到源码仓库。订阅权益刷新会使用你本机已有的 ChatGPT access token 调用 ChatGPT 账号接口。

## 授权

本项目使用 Apache License, Version 2.0 授权。详见 [LICENSE](LICENSE)。
