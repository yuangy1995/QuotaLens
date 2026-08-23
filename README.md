# QuotaLens

[简体中文](README.zh-CN.md)

QuotaLens is a native macOS menu bar app for tracking Codex and ChatGPT quota usage. It reads the local Codex sign-in state and presents quota usage, reset timing, subscription status, and reset-card availability in a compact desktop view.

## Features

- Menu bar overview with weekly used/remaining quota, reset countdown, subscription period, refresh state, and reset-card reserve.
- Native SwiftUI dashboard with light, dark, and system appearance modes.
- Local Codex account discovery from `~/.codex/auth.json`.
- Codex app-server snapshot reading via `codex app-server --stdio` for account and rate-limit data.
- Subscription entitlement refresh using the local ChatGPT access token, with renewal, ending, and scheduled-plan-change states.
- Reset-card expiry reminders with acknowledge and snooze controls.
- Local SQLite persistence under `~/Library/Application Support/QuotaLens/quotalens.sqlite`.
- Local session baseline scanning from `~/.codex/sessions` for later attribution and reconciliation.
- Adjustable refresh interval, custom Codex CLI path, launch-at-login toggle, and pure menu-bar mode.
- Built-in localization for English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, German, French, Portuguese, and Brazilian Portuguese.

## Requirements

- macOS 14 or later.
- Swift 6 toolchain or Xcode with Swift 6 support.
- A working `codex` CLI installation.
- A signed-in local Codex/ChatGPT session, usually stored in `~/.codex/auth.json`.

## Build And Run

Run from the project root:

```bash
swift run QuotaLens
```

Build a release binary:

```bash
swift build -c release
```

Create a signed `.app`, `.zip`, and `.dmg` package:

```bash
./scripts/build_and_package.sh --arch universal
```

By default, the packaging script uses ad-hoc signing. To sign with a Developer ID certificate, set `DEVELOPER_ID_APPLICATION` before running it:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" ./scripts/build_and_package.sh
```

Build architecture-specific downloads:

```bash
./scripts/build_and_package.sh --arch apple-silicon
./scripts/build_and_package.sh --arch intel
./scripts/build_and_package.sh --arch universal
```

## Versioning And Releases

The initial version is `v1.0.0`. The source of truth is the root [`VERSION`](VERSION) file. To publish a release:

```bash
git tag -a v1.0.0 -m "QuotaLens v1.0.0"
git push origin main
git push origin v1.0.0
```

Pushing a matching `vX.Y.Z` tag starts the GitHub Actions release workflow. It uploads Apple Silicon, Intel, and Universal macOS downloads to GitHub Releases. Update-capable builds can check for and install new versions in the app. See [docs/releasing.md](docs/releasing.md) for the full process.

## How It Works

QuotaLens looks for the Codex CLI in common installation paths and in `PATH`. When connected, it starts a short-lived `codex app-server --stdio` process and requests account and rate-limit snapshots. It also reads local Codex authentication metadata to identify the current account and, when possible, refreshes ChatGPT subscription entitlement details.

The app keeps its own local SQLite database for state, quota snapshots, local usage baselines, and reconciliation metadata. Build outputs, packaged apps, temporary files, credentials, and local machine artifacts are intentionally excluded from the repository.

## Privacy Notes

QuotaLens is designed as a local desktop utility. It reads local Codex configuration and session files on your Mac and stores derived app data locally in SQLite. It does not require committing credentials, packaged binaries, logs, or local databases to source control. The subscription entitlement refresh uses your existing local ChatGPT access token to call ChatGPT's account endpoint.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
