# QuotaLens Windows 使用说明

[English](windows.md) · [项目介绍](../README.zh-CN.md)

## 系统与版本状态

Windows 端使用 C#、.NET 10、WinUI 3 和 Windows App SDK 原生实现，不是 HTML 套壳。初版目标是 **Windows 11 x64、本地普通文件、可交互桌面**。暂不宣称支持 Windows 10、ARM64、WSL、网络共享及带重解析点的来源目录。macOS 保持独立原生工程、本地加密文件凭据方案和 Sparkle 更新通道。

源码构建包是 Windows 预览版。CI 通过说明相应提交能够编译、通过合成数据回归并启动原生界面，不代表真实账号授权、全部上游内部接口、所有显示器配置或代码签名信誉都已验证。

## 运行与首次配置

从成功的 Windows Actions 运行下载 `QuotaLens-Windows-x64` 产物，将其中的 `QuotaLens-Windows-x64-vX.Y.Z.zip` **完整解压**到固定本地目录，然后运行 `QuotaLens.exe`。不要在压缩包内运行，不要只拷贝 EXE；DLL、XAML 资源、运行库等文件必须保持完整。这是自包含目录 ZIP，不是单文件程序或 MSIX 安装器。

使用 `Get-FileHash -Algorithm SHA256 <压缩包路径>` 对照 `.sha256` 文件。包内 `BUILD-INFO.json` 记录源码提交、版本、架构与隔离界面检查数量。同一个营销版本可能对应不同开发提交；新增 Windows 不会覆盖旧的正式标签。

首次启动默认跟随系统外观和语言，所有工具监控、本机登录自动发现均未开启。在“应用设置”启用需要监控的工具并保存，再到“账号管理”选择本机导入、文件/JSON/Token 导入或浏览器授权。新增账号必须通过服务端身份和额度验证才会保存。本机自动发现需要单独勾选。

## 三种身份严格区分

主窗口查询账号、已验证的本机工具身份、本机会话记录不是同一个选择器。主窗口切到 B，不会把实际登录 A 的 Codex 改成 B；托盘和挂件使用已验证的工具身份。本机历史不会因为查询账号切换而重新归属，也不是授权后可以获得的完整云端历史。

### Codex

优先使用设置中的 `CODEX_HOME`，然后环境变量，最后 `%USERPROFILE%\.codex`。读取 `auth.json` 及 `sessions`、`archived_sessions`。高级云端累计用量和浏览器登录需要原生 `codex.exe`；不要选择 `codex.cmd` 或 PowerShell 包装脚本。独立查询进程使用 QuotaLens 私有临时 `CODEX_HOME`，不改写原工具登录文件。

CLI 版本可能不提供所有可选 RPC 方法。未返回累计 Token 时预测等待观测；未返回重置卡、订阅到期时间或真实卡片 ID 时，不伪造数据或消费按钮。

### Claude

优先使用设置中的 `CLAUDE_CONFIG_DIR`，然后环境变量，最后 `%USERPROFILE%\.claude`，同时支持 `.config\claude` 备选路径。读取受支持的 `.credentials.json` 和 `projects` 记录，不扫描浏览器 Cookie，不提取系统凭据库。

导入的可续期凭据可能和原客户端共享刷新链：即使不改写原文件，刷新令牌轮换仍可能影响原客户端。界面会提示风险，适用时优先选择独立授权。

### Antigravity

默认查找 `%APPDATA%\Antigravity IDE\User\globalStorage\state.vscdb` 和 `%APPDATA%\Antigravity\User\globalStorage\state.vscdb`，也可在工具设置明确选择一个状态文件。

**本机导入仅读取访问令牌，不解码、保存或轮换原工具的刷新令牌。** 本地访问令牌到期后，由 Antigravity 自己更新登录；启用本机发现后，QuotaLens 再读取变化。多个配置同时存在时，本机登录导入要求选择具体状态文件，不猜测当前身份。活动汇总按来源配置分别保存。状态数据库以只读方式访问，不注入、不重启 IDE，不写回其数据库；未知格式会保留历史并提示。

独立 Google 浏览器授权与本机导入是两条路径。独立授权需要你自己的 **Desktop OAuth 客户端 JSON**，在工具设置中导入并加密保存。应用不内置、不重建、不下载第三方 OAuth 客户端密钥。服务端仍需允许该客户端和授权范围；有客户端配置并不意味着一定能访问内部额度接口。别的客户端签发的刷新令牌不能任意换一个客户端来续期。

## 功能与数据口径

原生页面包括统一概况、账号资源、使用分布；工具额度、历史、用量与会话；Codex 容量预测、订阅与重置卡；Antigravity 本机活动；账号管理、设置、托盘挂件、恢复中心及诊断。

额度池以真实返回窗口为准，显示已用/可用、重置时间、新鲜度及失败状态；数据缺失不显示为零，不把不同工具百分比相加。云端累计 Token 不与本机会话相加，Antigravity 任务/步骤不换算成 Token。

Codex 容量算法保留原 macOS 的周期切分、套餐阶段隔离、迟到计数处理、最低有效消耗门槛及保守的下一周期预测。两个实现读取同一个 `capacity-prediction.json` 共享测试数据；没有足够观测时显示等待，不按套餐名猜固定容量。它是观测估算，不是官方额度或已证实的服务器降额。

Codex/Claude JSONL 记录采用有界增量读取，未写完的尾行稍后重试，重复扫描和重复逻辑记录不重复计数，失败替换不会清空已提交事实。Codex 对话回放、全文搜索按需读取源文件，可取消并有分页/结果上限，正文不存入分析数据库。Claude、Antigravity 不提供伪造的 Codex 式对话回放。

### API 参考价值不是历史账单

Windows 使用从 macOS 实际价格目录生成的“标准短上下文参考价”，CI 会检查生成表是否与源目录一致，模型名称必须精确匹配明确别名，未知模型不套默认价格。

Windows 尚未重建完整的历史生效日期、Fast/Flex 服务层级、长上下文阶梯或不明确的缓存写入 TTL。无法确定计价的事件保持未计价，Token 与未计价数量仍保留。显示的是有价格记录的参考估算，不是订阅扣费、发票，也不代表已实现与 macOS 历史计价的完全一致。价格目录版本和估算说明保留在界面中。

### 托盘、挂件与恢复中心

托盘提供额度速览、刷新、暂停、设置和退出；关闭主窗口可继续留在托盘，退出应用则停止监控。开机启动需要用户设置。周额度恢复提醒基于实际观察到的状态变化，并持久化去重。

挂件是非激活原生窗口，支持前台工具跟随、固定工具、拖动和重置位置。终端多标签页可能无法可靠识别当前工具，存在歧义时需要手动固定。Windows 的窗口跟随不等于 macOS 辅助功能精确吸附到特定按钮。

**恢复中心是 QuotaLens 私有目录，不是 Windows 回收站。** 用户确认后移动单个 Codex 会话源文件并清理对应派生索引，操作有恢复日志；拒绝正在写入或跨卷来源。还原不覆盖原位置已有文件，不会静默退回永久删除。

## 本机存储与隐私

数据目录为 `%LOCALAPPDATA%\QuotaLens`，包含 `quotalens.sqlite`、加密凭据及私有运行/恢复数据。Windows 与 macOS 数据库独立，不支持直接复制正在使用的数据库跨系统同步。

凭据使用 AES-256-GCM、记录绑定的认证附加数据、当前 Windows 用户 DPAPI 保护的主密钥、用户专属 ACL 和原子写入。密钥丢失、不匹配或密文损坏时不自动换密钥覆盖旧数据。DPAPI 不是对同一用户下恶意进程的绝对隔离。macOS 仍用现有本地加密文件，**不要在此次跨平台维护中改为钥匙串**。

导出凭据会包含明文授权，需要警告和文件选择，不能当作诊断上传或提交到 Git。诊断只包含聚合计数，不含令牌、源路径或正文。移除凭据保留历史并排除自动发现。若异常退出后私有 Codex 临时目录里存在唯一的已轮换凭据，应保留并提示恢复，而不是为清理临时目录而丢失它。

## 构建与自动检查

参考构建环境是 GitHub `windows-2025` runner。开发机需要兼容的 .NET 10 SDK、Windows SDK 10.0.22621 及 Windows App SDK 原生桌面构建依赖。在仓库根目录 PowerShell 运行：

```powershell
dotnet run --project windows/QuotaLens.Core.Tests -c Release
dotnet run --project windows/QuotaLens.Providers.Tests -c Release
dotnet run --project windows/QuotaLens.Infrastructure.Tests -c Release
./windows/scripts/build.ps1
```

这些是可执行断言测试，不能只运行 `dotnet test` 后就认为全部执行。Core/Providers 也在 Linux 跑；Infrastructure 在 Windows 的临时目录测试 DPAPI、ACL、SQLite、索引、恢复和并发设置，不使用开发者真实凭据。

构建脚本复用原 ICNS 图标生成 ICO，编译自包含 x64 目录，直接启动**最终发布目录中的 EXE**进行隔离界面测试。缺少 XAML/PRI 资源、启动失败或检查失败会阻止打包。隔离模式使用合成数据，不请求真实服务；产出深浅色截图和 `smoke.json`。这不是在正式应用内注入演示账户。

Mac 维护者可运行 `python3 windows/scripts/export-price-catalog.py --check` 检查参考价格目录，或去掉 `--check` 重新生成后提交；`swift test --filter SharedCapacityContractTests` 执行共享预测契约。早期原型的 `QuotaLens.Tests` 已由 Core、Providers、Infrastructure 三组测试替代，避免同时维护两套 Windows 模型。

## 打包与更新

ZIP 包含原项目许可、可取得的上游依赖许可与版本清单、中英文说明、构建来源。分发时不要丢弃这些文件。CI 包未做 Authenticode 签名，不宣称 SmartScreen 信誉、MSI/MSIX 安装和静默自动升级。

更新检查会校验项目 Release 地址，并确认有 Windows 产物，再提供浏览器入口；不会下载执行未经签名验证的更新程序。手动更新前退出应用，再替换完整应用目录，本机数据目录独立保留。移动安装目录后重新登记启动项。签名安装和自动替换须独立验证后再启用。

## 仍需真实环境验收

以下项目不能用合成 CI 冒充完成。验收记录应包含构建提交、Windows 和工具版本：

- 三种工具的真实授权、到期、取消、内部接口兼容；主窗口 B 与实际工具 A 的身份隔离。连接测试不应发起模型调用或消耗重置卡。
- 真实额度与可选权益、企业代理、断网、403/429、睡眠恢复和长时间运行。
- Windows 11 的 100/125/150/200% 缩放、多显示器、全屏、终端标签页歧义、键盘/辅助功能与挂件不抢焦点。
- 使用一次性会话副本验证恢复、扫描时源文件变化、换目录更新和启动项恢复。
- 宣称稳定签名发行版之前的证书、安装器和干净机器安装验证。

Windows 初版界面为简体中文/英文，尚非 macOS 全十种语言；平台特定精确吸附、完整历史计价和签名自动更新不属于当前已验证范围。这些边界不得在后续文档中隐去。
