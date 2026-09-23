# Changelog

All notable changes to QuotaLens are documented here. The complete original history through v1.1.1 is preserved without edits in [the historical changelog](docs/changelog-through-v1.1.1.md).

## [v1.2.0] - 2026-09-23 — Native Windows integration and model pricing

- Add a C#/.NET 10/WinUI 3 Windows 11 x64 client beside the existing macOS application: overview, tool spaces, accounts, quota, local analytics, sessions, Codex capacity/subscription/reset-credit views, Antigravity activity, settings, tray, overlays and recovery.
- Separate viewing identity from local-tool identity and local history. Verify identity and quota before saving an account; retain usable snapshots and historical facts when refresh or parsing fails.
- Add local encrypted credential storage with AES-256-GCM, current-user DPAPI key protection, ACLs, atomic writes and recovery of interrupted private Codex sessions. The macOS local encrypted-file scheme remains unchanged and is not moved to Keychain.
- Add consented Antigravity local access-token import without decoding or rotating the tool's refresh token, with explicit profile selection when local identities are ambiguous.
- Add bounded incremental Codex/Claude indexing, on-demand Codex transcript/search, transactional Antigravity aggregation and a private recoverable source-file center (not Windows Recycle Bin).
- Generate Windows standard reference rates from the actual Swift catalogs, with CI parity checks; unknown models and unsupported pricing classes remain unpriced. Reference value is not historical billing or actual subscription spend.
- Add GPT-6 Sol and Luna, plus Claude Opus 5.5, to the macOS price catalogs and generated Windows reference catalog using their published release dates and rates.
- Preserve shared Swift/C# forecast fixtures, replace the initial prototype test harness with Core/Providers/Infrastructure suites, and validate the final published native executable with isolated light/dark page, tray and non-activation checks.
- Package a self-contained directory ZIP with the original artwork, source provenance, checksum, English/Chinese guides and available upstream dependency notices. Update checks do not execute unsigned installers.

See [Windows changes](docs/windows-changelog.md), [English guide](docs/windows.md), and [简体中文说明](docs/windows.zh-CN.md) for support boundaries and manual acceptance.

## [v1.1.1] - 2026-09-15

- 恢复当前 Codex 账号的完整额度首页，保留账号切换、账号管理和备注。

## v1.1.0 and earlier

The complete original version-by-version entries, including the v1.1.0 encrypted-file credential migration notes, remain in [the historical changelog](docs/changelog-through-v1.1.1.md).
