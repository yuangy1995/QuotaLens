# QuotaLens

[English](README.md)

**面向 Codex、Claude 与 Antigravity 的原生 macOS / Windows 额度看板，提供本机用量分析、额度预测与桌面挂件。**

云端额度、主窗口查询账号、工具当前登录身份与本机会话历史分别处理。切换查询账号不会改变第三方工具登录，也不会重新归属本机历史。

## 平台

| | macOS | Windows |
|---|---|---|
| 界面 | SwiftUI / AppKit | C# / WinUI 3，不是网页套壳 |
| 目标系统 | macOS 14+，Apple Silicon / Intel | Windows 11 x64 |
| 分发 | `.app`、`.dmg`、`.zip` | Windows CI 生成的自包含目录 ZIP |
| 状态 | 既有 macOS 发布线 | 新增原生客户端；真实账号与真机验收不等同于 CI |
| 桌面功能 | 菜单栏、工具跟随挂件 | 系统托盘、额度速览、可选的不抢焦点挂件 |

Windows 工程位于 [`windows/`](windows/)。新增平台不重写 macOS，不改变其本地加密凭据方案和 Sparkle 更新通道。初版不宣称支持 Windows 10、ARM64、WSL 或网络共享数据源。

## 功能

- 三种工具分别启用，按实际返回值展示额度池、已用／可用、重置时间与新鲜度。读取失败不显示为零，不合并不同工具的额度百分比。
- 多查询账号、服务端验证后导入、显式浏览器授权。导入令牌可能与原客户端共享续期链，即使不修改原工具文件，轮换也可能影响其后续刷新。
- SQLite 保存额度快照。Codex 预测配对同一已验证账号的云端累计 Token 与额度变化，不与本机会话相加，不按套餐名称猜测固定容量。
- 增量解析 Codex、Claude 本机会话。Codex 回放与全文搜索按需读取原始文件，对话正文不复制到分析数据库。
- Antigravity 额度组与模型额度分开；受支持的本机聚合任务与步骤不折算为 Token。
- Codex 订阅与重置卡以接口实际返回为准。使用必须确认并具备真实卡片标识；不确定结果重试同一持久化标识，避免重复消费。
- 跟随系统／浅色／深色、后台刷新与暂停、聚合诊断、桌面速览。Windows 提供简体中文与英文；macOS 保留原有十种语言。

见 [Windows 使用与验收说明](docs/windows.md)、[macOS 查询账号设计](docs/query-accounts.md)、[容量预测规则](docs/quota-capacity-forecast.md)与[价格审计](docs/model-pricing-audit.md)。

## Windows 使用与构建

从成功的 **Windows** GitHub Actions 运行下载 `QuotaLens-Windows-x64` 产物，将其中的 `QuotaLens-Windows-x64-vX.Y.Z.zip` 完整解压到固定本地目录，运行 **`QuotaLens.exe`**。必须保留全部同目录文件，不能只复制 EXE。CI 包未经代码签名，不代表具有签名证书或 SmartScreen 信誉。

首次启动默认不扫描、不查询任何工具。先在“应用设置”启用，再到“账号管理”授权或导入。本机登录自动发现单独开启；查询账号不自动成为托盘或挂件的工具身份。

在具有相应 .NET 10 SDK 与 Windows SDK 的 Windows 环境运行：

```powershell
dotnet run --project windows/QuotaLens.Core.Tests -c Release
dotnet run --project windows/QuotaLens.Providers.Tests -c Release
dotnet run --project windows/QuotaLens.Infrastructure.Tests -c Release
./windows/scripts/build.ps1
```

脚本编译原生程序、运行隔离界面启动检查，再生成 `windows/artifacts/` 下的 ZIP 与 SHA-256 文件。测试使用临时数据库和合成身份，不发送真实账号请求；原生深浅色渲染结果位于 `windows/validation/`。编译、自动检查和截图不替代真实账号授权及 Windows 11 多显示器真机验收。

## macOS 使用与构建

需要 Swift 6，或提供该工具链的 Xcode：

```bash
swift run QuotaLens
swift test
swift build -c release
./scripts/build_and_package.sh
```

本地打包自动识别架构并生成 ad-hoc 签名安装包。通过 `--arch apple-silicon`、`--arch intel`、`--arch universal` 指定架构。默认保留增量缓存，`--clean` 清理缓存，`--full-optimization` 使用整模块发布优化。

Codex 需要可用 CLI 和本机订阅登录，通常位于 `~/.codex/auth.json`。Claude、Antigravity 需要对应工具的可用授权。macOS 可选 Codex 精确吸附只读取窗口与控件几何信息，不读取对话内容。

## 数据与隐私

| 数据 | macOS | Windows |
|---|---|---|
| 分析数据库 | `~/Library/Application Support/QuotaLens/quotalens.sqlite` | `%LOCALAPPDATA%\QuotaLens\quotalens.sqlite` |
| 凭据 | AES-256-GCM 本地文件、主密钥与 POSIX 权限；**不改为钥匙串** | AES-256-GCM 本地文件、当前用户 DPAPI 保护主密钥与用户专属 ACL |
| 源文件恢复 | macOS 废纸篓 | QuotaLens 私有“恢复中心”，不是 Windows 回收站 |

macOS 中同时取得主密钥和密文即可解密；DPAPI 也不能绝对隔离同一用户下的恶意程序。密钥丢失或不匹配时不自动生成新密钥覆盖旧密文。异常中断后的 Codex 私有临时目录可能保留授权，避免删除唯一已轮换凭据。

诊断只导出聚合计数，不含授权 Token、源路径或对话正文。主动导出的凭据文件含明文授权，不能当作诊断文件上传到仓库或公开分享。移除凭据不删除历史数据。

API 等价价值不是账单或实际扣费，预测不是官方额度上限。未知模型、不能确定计价的记录与观测不足的周期保持未计价或等待状态。上游内部接口可能变化；失败时保留上次成功快照并说明原因，不伪造新数据。

## 版本与发布

根目录 [`VERSION`](VERSION) 是唯一营销版本来源。新增 Windows 不改写已有标签；使用当前版本号的新提交 CI 产物不等于新稳定版本。

见 [macOS 发布流程](docs/releasing.md)与 [Windows 打包和更新策略](docs/windows.md#packaging-and-updates)。Windows 不使用 Sparkle，不静默执行未验证的升级程序；更新检查只在浏览器打开经过校验的项目 Release。

## 授权

Apache License 2.0。详见 [LICENSE](LICENSE) 和[第三方许可](THIRD_PARTY_NOTICES.md)。
