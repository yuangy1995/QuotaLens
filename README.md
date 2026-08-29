# QuotaLens

[简体中文](README.zh-CN.md)

QuotaLens is a native macOS menu bar app for tracking Codex, Claude Code, and ChatGPT quota and local usage. It presents quota usage, reset timing, subscription status, and reset-card availability in a compact desktop view.

## Features

- Menu bar overview with weekly used/remaining quota, reset countdown, subscription period, refresh state, and reset-card reserve.
- Native SwiftUI dashboard with light, dark, and system appearance modes.
- Local Codex account discovery from `~/.codex/auth.json`.
- Codex app-server snapshot reading via `codex app-server --stdio` for account and rate-limit data.
- Additional Codex model quotas plus cloud account totals, peak day, longest turn, activity streaks, and daily activity.
- Claude Code tracking is off by default. When enabled, it reads 5-hour, 7-day, and model-scoped weekly quotas and incrementally aggregates local usage from `~/.claude/projects` and `~/.config/claude/projects`.
- Sessions, History, and Dashboard can filter All, Codex, or Claude usage. The menu bar reading can show Codex, Claude, or both.
- Subscription entitlement refresh using the local ChatGPT access token, with renewal, ending, and scheduled-plan-change states.
- Reset-card expiry reminders with acknowledge and snooze controls.
- Local SQLite persistence under `~/Library/Application Support/QuotaLens/quotalens.sqlite`.
- Local Codex usage analytics from `~/.codex/sessions` and, when enabled, `~/.codex/archived_sessions`, including Sessions, History, Dashboard, model mix, cache hit rate, and token trend views.
- Pointer-following detail cards for usage bars and the annual heatmap. Hover feedback stays inside the chart overlay and never resizes or shifts the heatmap.
- Session rows include a right-click Delete action. Subagent details provide a Back to Main Session control, and the search toolbar uses one unambiguous filter/sort icon. After deletion confirmation, the selected session tree's Codex rollout files are moved to the macOS Trash and its derived local index rows are removed; files can be restored from the Trash.
- API equivalent value estimates marked as Beta. These use OpenAI API list prices for comparison only and are not ChatGPT/Codex subscription bills or actual charges.
- Minimal event ledger for local analytics: timestamp, model, token buckets, pricing status, source path, and byte offset. Conversation prompts and responses are not stored.
- Local index diagnostics for unknown models, unpriced events, timestamp fallbacks, parser version, active pricing catalog, rewritten files, and tombstoned sources, with a privacy-safe aggregate JSON export.
- Adjustable refresh interval, custom Codex CLI path, launch-at-login toggle, and pure menu-bar mode.
- Clicking the Dock icon focuses only the main window; the quota popover opens only from the menu bar status item.
- When the available quota reaches zero, the dashboard and menu bar show an exhausted/waiting-for-reset state and stop producing pace forecasts.
- The Codex window overlay is enabled by default and can be disabled independently from local analytics. It stays attached with click-through behavior while Codex is in the background, unlocks dragging after a long press, and reveals details on hover. Basic mode needs no Accessibility permission; precise snapping is an explicit opt-in that locates the Codex window and Help control without reading conversation content.
- Built-in localization for English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, German, French, Portuguese, and Brazilian Portuguese.
- The in-app changelog follows the selected interface language; its Simplified Chinese remote source cannot override other languages.

## Requirements

- macOS 14 or later.
- Swift 6 toolchain or Xcode with Swift 6 support.
- A working `codex` CLI installation.
- A signed-in local Codex/ChatGPT session, usually stored in `~/.codex/auth.json`.
- To use Claude quota and local history, sign in to Claude Code; Claude tracking can remain disabled.

## Build And Run

Run from the project root:

```bash
swift run QuotaLens
```

Build a release binary:

```bash
swift build -c release
```

Create an `.app`, `.zip`, and `.dmg` package:

```bash
./scripts/build_and_package.sh --arch universal
```

The packaging script uses ad-hoc signing.

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

QuotaLens looks for the Codex CLI in common installation paths, the ChatGPT/Codex app bundles, and the login shell `PATH`. When connected, it starts `codex app-server --stdio` and requests account, quota, and account-activity data. It also reads local Codex authentication metadata to identify the current account and, when possible, refreshes ChatGPT subscription entitlement details. When Claude tracking is enabled, QuotaLens reads Claude Code's local usage files and updates quota through the existing sign-in state. Refreshed sign-in data stays in QuotaLens private storage and never modifies Claude Code's sign-in files.

The app keeps its own local SQLite database for state, quota snapshots, local usage summaries, minimal usage event facts, pricing catalog metadata, and reconciliation metadata. Build outputs, packaged apps, temporary files, credentials, and local machine artifacts are intentionally excluded from the repository.

Local analytics can be turned off in Settings. The Settings page also provides **Scan Now**, **Re-index All**, and a privacy-safe diagnostics JSON export. Re-indexing clears derived Codex usage aggregates and rebuilds them from the current local Codex files; it does not delete account, subscription, or quota snapshots.

## Privacy Notes

QuotaLens is designed as a local desktop utility. It reads configuration and local usage files only for enabled sources and stores derived app data locally in SQLite. For usage analytics, QuotaLens stores token counts, model identifiers, timestamps, pricing status, source paths, and byte offsets. It does not store conversation text from prompts, answers, or tool output; Claude records do not offer conversation playback or deletion. Exported diagnostics contain aggregate counters only and omit source paths. Precise overlay snapping is opt-in and uses only Codex window and control metadata to locate the Help control; it does not read conversation content. The subscription entitlement refresh uses your existing local ChatGPT access token to call ChatGPT's account endpoint.

API equivalent value is a diagnostic comparison against API list prices. It is not a subscription bill, invoice, or actual amount charged. Unknown models remain unpriced and are surfaced in diagnostics instead of being silently mapped to a default model.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE); third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
