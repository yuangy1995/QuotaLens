# QuotaLens

[简体中文](README.zh-CN.md)

**Native macOS and Windows dashboards for Codex, Claude, and Antigravity quota tracking, local usage analytics, forecasts, and desktop overlays.**

QuotaLens separates cloud quota, the account selected for a query, the identity currently used by a local tool, and local session history. Selecting another account does not switch the tool's login or reassign local history.

## Platforms

| | macOS | Windows |
|---|---|---|
| Interface | SwiftUI / AppKit | C# / WinUI 3, not a browser wrapper |
| Target | macOS 14+, Apple Silicon and Intel | Windows 11 x64 |
| Distribution | `.app`, `.dmg`, `.zip` | Self-contained folder `.zip` from Windows CI |
| Status | Existing macOS release line | Initial native client; live-account and hardware acceptance remains separate from CI |
| Desktop | Menu bar and tool-following overlays | Notification-area icon, quick panel and optional non-activating overlay |

The Windows implementation lives under [`windows/`](windows/). Existing macOS source layout, local credential design and Sparkle updates are retained. Windows 10, ARM64, WSL and network-share data sources are outside the initial support claim.

## Features

- Enable Codex, Claude and Antigravity independently. Inspect actual quota windows, reset times, verified accounts and cache freshness. Missing data is not zero quota; unrelated percentages are never summed.
- Manage multiple query accounts with verified imports and explicit browser authorization. Imported refresh tokens can share a renewal chain with another client; renewal may affect that client even though QuotaLens never rewrites its files.
- Persist local quota history. Codex capacity forecasts use verified cloud cumulative counters and matched quota observations, not local-session totals or a guessed subscription allowance.
- Incrementally analyze Codex and Claude local sessions. Codex replay and full-text search read source files only on demand; conversation bodies are not copied into the analytics database.
- Keep Antigravity quota groups separate from individual model allowances, and supported local task/step aggregates separate from token usage.
- Show Codex subscription/reset-credit details when returned upstream. Redemption requires confirmation and a real credit identifier; uncertain retries retain a durable idempotency key.
- Use system/light/dark themes, privacy-safe diagnostics, background refresh and pause. Initial Windows localization is English and Simplified Chinese; macOS retains its ten languages.

See the [Windows guide](docs/windows.md), [macOS account design](docs/query-accounts.md), [forecast rules](docs/quota-capacity-forecast.md), and [pricing audit](docs/model-pricing-audit.md).

## Windows: run and build

Download `QuotaLens-Windows-x64` from a successful **Windows** Actions run. Extract the inner `QuotaLens-Windows-x64-vX.Y.Z.zip` to a stable local directory and run **`QuotaLens.exe`**. Keep every extracted file together; the EXE alone is not a single-file portable application. CI archives are unsigned; no signing certificate or SmartScreen reputation is implied.

First launch has monitoring disabled. Enable tools in **App settings**, then import or authorize in **Accounts**. Local-login discovery is a separate opt-in. A queried account does not automatically become the tool identity used by the tray and overlay.

Build on Windows with a compatible .NET 10 SDK and Windows SDK:

```powershell
dotnet run --project windows/QuotaLens.Core.Tests -c Release
dotnet run --project windows/QuotaLens.Providers.Tests -c Release
dotnet run --project windows/QuotaLens.Infrastructure.Tests -c Release
./windows/scripts/build.ps1
```

The script builds the native app, launches an isolated UI smoke test, and creates the ZIP and SHA-256 sidecar under `windows/artifacts/`. Tests use an isolated temporary database, synthetic identities and no provider requests. Native light/dark renderings are written to `windows/validation/`. These checks do not replace real-account OAuth verification or Windows 11 multi-monitor hardware testing.

## macOS: run and build

Requires Swift 6 or an Xcode version providing that toolchain:

```bash
swift run QuotaLens
swift test
swift build -c release
./scripts/build_and_package.sh
```

Local packaging detects the current architecture and creates an ad-hoc-signed package. Override with `--arch apple-silicon`, `--arch intel` or `--arch universal`. Incremental caches are retained; `--clean` discards them and `--full-optimization` uses the whole-module release configuration.

Codex requires an available CLI and usable subscription login, typically `~/.codex/auth.json`. Claude and Antigravity require supported authorization for the enabled tool. Optional precise macOS Codex anchoring reads window/control geometry, not conversation text.

## Data and privacy

| Data | macOS | Windows |
|---|---|---|
| Analytics | `~/Library/Application Support/QuotaLens/quotalens.sqlite` | `%LOCALAPPDATA%\QuotaLens\quotalens.sqlite` |
| Credentials | Local AES-256-GCM, private master-key file and POSIX permissions; **no Keychain migration** | Local AES-256-GCM, current-user DPAPI-protected master key and user-specific ACLs |
| Recoverable source removal | macOS Trash | QuotaLens private **Recovery center**, not Windows Recycle Bin |

Possession of the macOS master key and ciphertext permits decryption. DPAPI is not absolute isolation from malicious software running as the same user. Key loss/mismatch never silently regenerates a key over old ciphertext. Interrupted private Codex runtime directories may retain authorization when cleanup would risk losing a rotated credential.

Diagnostic exports contain aggregate counts, not authorization tokens, source paths or conversation text. Explicit credential exports are different: they contain plaintext authorization and must not be uploaded to a repository or shared as diagnostics. Removing credentials preserves historical analytics.

API-equivalent values and capacity forecasts are estimates, not invoices, subscription charges or official quota limits. Unknown models and insufficient observations remain unpriced/unavailable. Internal upstream interfaces can change; failed refreshes retain the last valid snapshot and display an error rather than fabricating data.

## Versioning and release

[`VERSION`](VERSION) is the marketing-version source. Existing tags are not rewritten to add Windows. A Windows CI artifact from a newer commit is not automatically a new stable release, even with the same marketing version.

See [macOS release instructions](docs/releasing.md) and [Windows packaging and update policy](docs/windows.md#packaging-and-updates). Windows does not use Sparkle or execute an unsigned silent updater; update checks open a validated release page in the browser.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
