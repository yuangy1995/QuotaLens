# QuotaLens for Windows

[简体中文](windows.zh-CN.md) · [Project overview](../README.md)

## Supported configuration

This is the initial native Windows client: C#/.NET 10, WinUI 3 and Windows App SDK, with no embedded browser UI. The initial target is **Windows 11 x64**, ordinary local files and an interactive desktop. Windows 10, ARM64, WSL, network shares and reparse-point source directories are not part of the support claim. macOS remains a separate native application; its source layout, encrypted-file credential store and Sparkle updates are unchanged.

A successful CI run verifies compilation, synthetic-data regressions and native UI startup. It does not establish live provider authorization, every upstream interface, every Windows hardware configuration or code-signing reputation. Treat source-built archives as a preview until the manual acceptance checks below have been completed.

## Run the application

Download the **QuotaLens-Windows-x64** artifact from a successful Windows Actions run. Extract its inner `QuotaLens-Windows-x64-vX.Y.Z.zip` into a fixed local directory and launch `QuotaLens.exe`. Keep all DLLs, XAML resources, runtime files and other extracted files together. This is a self-contained **folder**, not a single-file executable or an MSIX installer. Do not run it from inside the archive.

The archive has a SHA-256 sidecar. Compare it with `Get-FileHash -Algorithm SHA256 <archive>`. `BUILD-INFO.json` inside the package records the source commit, version, architecture and isolated UI check count. The marketing version alone does not identify a development build. Existing release tags are not rewritten to add Windows.

First launch defaults to system theme and language; no tool is enabled and no local login discovery occurs. In **App settings**, enable only the tools to monitor and save. In **Accounts**, explicitly import a local login, import JSON/a token, or begin browser authorization. A new account is saved only after provider identity and quota verification succeeds. Local discovery is a separate opt-in, not implied by enabling quota monitoring.

## Account and source boundaries

The main window's viewing account, the verified local tool identity, and local session history are separate. Selecting query account B must not change a CLI logged into A; tray and overlays continue to use the verified local identity. Local history is not reassigned when the account picker changes, nor is it presented as complete cloud history.

| Tool | Native Windows source | Important boundary |
|---|---|---|
| Codex | Configured `CODEX_HOME`, environment override, or `%USERPROFILE%\.codex`; `auth.json`, `sessions`, `archived_sessions` | Choose the native `codex.exe`, not `codex.cmd` or a PowerShell shim. Browser login and optional cloud counters use an isolated private `CODEX_HOME`. |
| Claude | Configured `CLAUDE_CONFIG_DIR`, environment override, or `%USERPROFILE%\.claude`; `.credentials.json` and `projects`; the `.config\claude` alternative is also checked | No browser cookies or OS credential-store extraction. Imported refresh tokens can share a renewal chain with the original client. |
| Antigravity | Configured `state.vscdb`, otherwise `%APPDATA%\Antigravity IDE\User\globalStorage\state.vscdb` and `%APPDATA%\Antigravity\User\globalStorage\state.vscdb` | Local login import decodes **only the access token**, never the tool's refresh token. Multiple available profiles require an explicit state-file selection for login import. |

Antigravity's own application remains responsible for renewing locally imported access. Open it and let it refresh its login; opt-in discovery can then observe the changed state. QuotaLens reads the database read-only, validates the supported format and does not inject into or restart the IDE. Local activity can be aggregated by profile independently of query authorization. Unknown formats retain prior facts instead of clearing history.

Independent Google authorization is different from local import: it requires the user's own **Desktop OAuth client** JSON configured in Tool settings. The configuration is encrypted locally. No third-party Google client secret is embedded, reconstructed or fetched. The provider must authorize that client and its requested scopes; merely supplying a client configuration does not guarantee access to internal quota APIs. Refresh tokens issued to another OAuth client are not interchangeable.

For Codex/Claude and explicit credential-file imports, refresh-token renewal can affect the original client's shared refresh chain even though its files are never rewritten. Prefer independent authorization where supported. Import failures, expiry, revoked authorization, forbidden requests, rate limits and network failures are distinct; a 403 is not automatically treated as token revocation.

## Implemented views and behavior

The native application provides global overview/account resources/local usage distribution; per-tool quota pages; Codex capacity forecasts, subscription details and reset credits; Codex/Claude local usage and sessions; quota snapshot history; Antigravity task activity; account management; settings; tray/overlay controls; recovery and aggregate diagnostics.

Quota cards use actual returned windows and reset times, distinguish stale/failed data from real zero, and never add unrelated percentages. Codex cloud cumulative counters are not added to local usage. Antigravity tasks and steps are not converted into tokens. Optional Codex RPC methods may be unavailable in a particular CLI build; a missing method does not create invented entitlements or capacity observations.

Codex capacity estimation ports the macOS observation algorithm: account/stage isolation, independent 300/10080-minute windows, resets, delayed counters, minimum paired consumption and cautious next-cycle estimation. See [forecast rules](quota-capacity-forecast.md). Both languages consume the retained `capacity-prediction.json` contract fixture. The earlier prototype `QuotaLens.Tests` project is superseded by the Core, Providers and Infrastructure executable test suites; there is only one active Windows domain model.

Usage is incrementally indexed from bounded JSONL reads. Incomplete trailing lines are retried, full rescans are idempotent, duplicate logical records are not counted twice, and malformed replacements retain committed facts. Codex conversation replay and full-text search read original sources only on demand, with cancellation and paging/limits. The analysis database stores counters and indexing metadata, not conversation text. Claude/Antigravity do not gain a fabricated Codex-style conversation replay.

### Reference pricing is not billing

Windows displays **API reference value** using bundled standard short-context rates generated from the actual macOS catalogs by `windows/scripts/export-price-catalog.py`. CI evaluates those Swift catalogs and rejects a stale generated C# table. Model matching uses explicit catalog names/aliases only.

This is not historical date/tier-aware billing parity: Fast/Flex pricing, historical price periods, long-context tiers and ambiguous cache-write TTLs are not reconstructed by the Windows importer. Events with unknown models or cache-write counts whose pricing cannot be established remain unpriced; their counts remain visible. Totals are estimates over priced records, never subscription charges or invoices. Regenerating the catalog is an explicit source change, not an automatic claim that market prices were checked today.

### Tray, overlays and recovery

The Windows notification-area icon opens a compact quota panel and a context menu. Closing the main window can leave monitoring in the tray; exiting stops it. Startup registration is user-controlled. A weekly recovery notification requires an observed eligible transition, with persistent deduplication.

The optional overlay is a non-activating native utility window. It follows recognized foreground tools or a manually pinned provider, can be dragged, and can have its position reset. Terminal process trees cannot always identify the active tab; ambiguous cases must not be represented as a verified tool identity. This is Windows window following, not macOS Accessibility-based exact help-button anchoring.

**Recovery center is a private QuotaLens folder, not Windows Recycle Bin.** Explicit confirmed removal moves a Codex source file and updates its derived index using a recovery journal. Active or cross-volume sources are rejected. Restore does not overwrite an existing source file. There is no silent fallback to irreversible deletion.

## Storage and privacy

State is under `%LOCALAPPDATA%\QuotaLens`: `quotalens.sqlite`, encrypted credentials and private runtime/recovery data. The Windows database is separate from macOS; do not copy a live database between machines or assume schema/file-path compatibility.

Credentials use AES-256-GCM with record-bound authentication, a current-user DPAPI-protected master key, restrictive user ACLs and atomic writes. A missing, mismatched or corrupted key does not silently overwrite existing encrypted records. DPAPI cannot provide absolute isolation from malicious processes under the same Windows user. The macOS encrypted-file scheme remains unchanged; do not replace it with Keychain as part of Windows maintenance.

Explicit credential export contains plaintext authorization and requires a warning and file selection. It is not a diagnostic export. Removing credentials leaves historical data and excludes automatic rediscovery. Diagnostics contain aggregate counts, not tokens, source paths or conversation text. Private Codex runtime recovery may retain a rotated credential if destroying it would lose the only usable copy; surface this condition rather than erasing it.

## Build and tests

Use a Windows build environment with .NET 10 SDK, Windows SDK 10.0.22621 and the native desktop prerequisites accepted by the pinned Windows App SDK. The GitHub `windows-2025` runner is the CI reference environment. Run from the repository root in PowerShell:

```powershell
dotnet run --project windows/QuotaLens.Core.Tests -c Release
dotnet run --project windows/QuotaLens.Providers.Tests -c Release
dotnet run --project windows/QuotaLens.Infrastructure.Tests -c Release
./windows/scripts/build.ps1
```

These are executable assertion suites; `dotnet test` alone is not a substitute. Core/Providers tests also run on Linux. Infrastructure tests exercise Windows DPAPI, ACLs, SQLite/indexing, recovery and settings concurrency in temporary directories. They do not read the developer's real accounts.

The build reuses the original ICNS artwork to generate an ICO, publishes a self-contained x64 folder, launches **that published executable** in isolated smoke mode and refuses to package a missing resource set or a failed launch. Smoke mode uses synthetic identities, no provider network calls, light/dark rendering, page coverage and native tray/non-activation checks. Screenshots and `smoke.json` are artifacts, not production demo data. `-SkipSmoke` is a local diagnostic option, not equivalent to CI acceptance.

Mac maintainers can regenerate/check the reference catalog with Python 3 and Swift 6:

```bash
python3 windows/scripts/export-price-catalog.py
python3 windows/scripts/export-price-catalog.py --check
swift test --filter SharedCapacityContractTests
```

## Packaging and updates

Archives contain application files, the original project license, third-party notices and resolved dependency metadata, English/Chinese guides and build provenance. Preserve these when redistributing. CI packages are unsigned: the project does not claim Authenticode signing, SmartScreen reputation, an MSI/MSIX installer or unattended signed upgrades.

Windows update checks verify the repository release URL and the presence of a Windows asset, then offer to open the release in the browser. They do not download or execute an unsigned updater. Quit the app before replacing its extracted application directory; application data is separate. Re-register startup if the executable's directory changes. Signed installation and automatic verified replacement require their own release validation and are not silently enabled.

## Manual acceptance still required

Record the build commit, Windows version, CLI/tool versions and result for each check. CI does not mark these complete:

- Real Codex/Claude/Antigravity authorization, access expiry, cancellation, internal API availability and account A/B separation; no model call or reset-card consumption merely to test connectivity.
- Real quota/reset/optional subscription data, proxy/enterprise network behavior, offline/403/429 recovery, sleep/resume and long-running polling.
- Windows 11 displays at 100/125/150/200% scaling, multiple monitors, terminal-tab ambiguity, fullscreen applications, keyboard/accessibility and non-stealing overlay focus.
- Recovery on user-owned disposable session copies, source changes while indexing, application-directory upgrade and startup re-registration.
- Signing/installer trust and end-user installation on a clean machine before advertising a stable signed Windows release.

Initial Windows localization is Simplified Chinese/English, not all ten macOS languages. Mac historical pricing and platform-specific exact overlay anchoring are not claimed to be fully reproduced. These boundaries are intentional and must remain visible in future documentation.
