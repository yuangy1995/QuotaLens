# QuotaLens

[简体中文](README.zh-CN.md)

QuotaLens is a native macOS menu bar dashboard for Codex, Claude, and Antigravity. It brings cross-tool quotas, usage analytics, reset forecasts, recovery alerts, and foreground-aware overlays into one place, while also surfacing ChatGPT subscription and reset-card status for Codex accounts.

## Features

### Cross-Tool Quotas And Forecasts

- Monitor Codex, Claude, and Antigravity independently, then switch between a unified overview and each tool's dedicated space.
- See every quota window exposed by a tool, including 5-hour, 7-day, weekly, and model pools, with used/available views, reset timing, and data freshness.
- Identify the tightest quota pool, compare current burn rate with a sustainable pace, forecast runout or reset outcomes, and get practical recommendations.
- Receive a floating alert when a weekly quota fully recovers. The Codex space also tracks ChatGPT subscription status and reset-card availability and expiry.

### Usage And Activity Analytics

- Codex combines cloud account activity with local Sessions, History, and Dashboard views for tokens, model mix, reasoning effort, cache hit rate, trends, and API-equivalent value estimates.
- Codex conversation playback and full-text search read the original rollout files only when requested. Deleting a session moves its source tree to the macOS Trash and clears the derived index.
- Claude reads 5-hour, 7-day, and model-scoped weekly quotas and incrementally aggregates local sessions and usage from `~/.claude/projects` and `~/.config/claude/projects`.
- Antigravity shows quota-pool trends, model availability, pace forecasts, and local task, step, active-day, and project activity across available local profiles.
- Local records, quota snapshots, trend history, and diagnostics are stored in `~/Library/Application Support/QuotaLens/quotalens.sqlite`.

### Menu Bar And Window Overlays

- The menu bar and floating overlays follow the foreground Codex, Claude, or Antigravity app and switch to the matching quota and activity view automatically.
- Each tool has an independently configurable, draggable window overlay. Claude is also detected while running in Terminal, iTerm, or VS Code; Codex precise snapping is an optional Accessibility-assisted mode.
- Choose used or available quota, adjust refresh intervals, launch at login, hide the Dock icon, and use light, dark, or system appearance.
- Built-in localization covers English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, German, French, Portuguese, and Brazilian Portuguese. In-app updates and localized release notes are included.

## Requirements

- macOS 14 or later.
- Building from source requires a Swift 6 toolchain or Xcode with Swift 6 support.
- Codex monitoring requires a working `codex` CLI and a signed-in local Codex/ChatGPT session, usually stored in `~/.codex/auth.json`.
- Claude monitoring requires a signed-in Claude Code installation.
- Antigravity monitoring requires a signed-in local Antigravity installation.

Codex, Claude, and Antigravity can be enabled or disabled independently.

Antigravity quota monitoring depends on its internal sign-in and quota interfaces, which may change without notice. If compatibility changes, QuotaLens keeps the last successful quota data and reports that an update is needed. If some local records cannot be read, their saved history is kept until a complete scan succeeds.

## Build And Run

Pull request and main-branch CI runs the test suite and builds an ad-hoc-signed Universal package, checking both architectures, Sparkle helper signatures, Downloader permissions, and the DMG. It does not publish a release or require notarization.

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
./scripts/build_and_package.sh
```

The packaging script detects whether the current Mac uses Apple Silicon or Intel, produces only the matching single-architecture package, and uses ad-hoc signing.
Local ad-hoc packaging reuses its architecture-specific Swift build cache and uses incremental optimized compilation. The first build can still take longer, while unchanged or small follow-up builds are much faster. Use `--clean` to discard the cache or `--full-optimization` to reproduce the whole-module release compilation used for formal releases.

Override the build architecture manually:

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

QuotaLens reads only the tools you enable. For Codex, it locates the CLI, starts `codex app-server --stdio`, and reads account, quota, activity, local session, and ChatGPT entitlement data. For Claude, it uses the existing Claude Code sign-in state and local project records. For Antigravity, it reads the available local sign-in profiles, model quota groups, and aggregate task activity.

Quota snapshots and their local history feed the unified pace, runout, reset, and recovery insights. Refreshed sign-in data stays in QuotaLens private storage and never modifies third-party sign-in files.

The app keeps its own local SQLite database for state, quota snapshots, local usage summaries, minimal usage event facts, pricing catalog metadata, and reconciliation metadata. Build outputs, packaged apps, temporary files, credentials, and local machine artifacts are intentionally excluded from the repository.

Each tool can be enabled or disabled independently in Settings. Codex and Claude local records can be rescanned, and Antigravity activity can be refreshed separately. Re-indexing Codex clears only its derived usage aggregates and rebuilds them from the current local rollout files; it does not delete account, subscription, or quota snapshots. A privacy-safe aggregate diagnostics JSON export is also available.

## Privacy Notes

QuotaLens is a local desktop utility. It reads configuration and local records only for enabled tools and stores derived app data locally in SQLite. Usage analytics keep token counts, model identifiers, timestamps, pricing status, source paths, byte offsets, and aggregate Antigravity task metadata rather than conversation bodies.

Codex conversation content is read directly from the original rollout file only when you open a conversation or run a full-text search; it is not copied into the QuotaLens analytics database. Claude and Antigravity views do not provide conversation playback. Exported diagnostics contain aggregate counters only and omit source paths. Window overlays use app and window geometry; optional Codex precise snapping uses only window and control metadata to locate the Help control, not conversation content. Quota and entitlement refreshes use the existing local sign-in state for each enabled tool.

API equivalent value is a diagnostic comparison against API list prices. It is not a subscription bill, invoice, or actual amount charged. Unknown models remain unpriced and are surfaced in diagnostics instead of being silently mapped to a default model.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE); third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
