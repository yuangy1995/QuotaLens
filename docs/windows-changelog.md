# Windows integration — Unreleased

This change introduces the native Windows client alongside macOS. It does not rewrite v1.1.1 or create a new stable release tag. See the package's BUILD-INFO.json and the corresponding Actions run for exact source and verification results.

## Native application

Implemented WinUI 3 overview and tool spaces, query account management, quota snapshots, local usage and sessions, Codex forecasts/subscription/reset-credit views, Antigravity activity, settings, tray quick view, non-activating overlays, notifications, explicit startup registration and recovery center. Themes follow system/light/dark; initial UI languages are Simplified Chinese and English.

## Data and safety

Preserved query/local/history identity separation, verified-before-save accounts, cancellation, bounded provider responses, isolated Codex RPC homes, encrypted local credentials with DPAPI-protected key, atomic settings, retained failed snapshots and recoverable source removal. Antigravity local discovery uses access-only authorization without decoding the tool's refresh token; multiple profiles are not guessed.

Incremental JSONL indexing rejects incomplete/corrupt replacements without erasing committed facts. Codex text is read on demand rather than stored in analytics. Reference prices are generated from the Swift catalogs and checked in CI; unknown models and unsupported token classes remain unpriced. Manual and automatic Antigravity activity refresh now share one transactional pipeline and profile identity.

## Validation and packaging

Fixed C# date parsing, asynchronous Span comparison and Windows SQLite sharing in tests. Preserved the main branch's shared Swift prediction fixtures, with C# consuming the same file. The early prototype test project is superseded by Core/Providers/Infrastructure regression suites. Native CI launches the final self-contained executable, exercises page/theme/tray/overlay paths, and records screenshots plus machine-readable results without provider network calls.

Packages include the original project artwork, guide, licenses, dependency metadata, checksum and source provenance. There is no claim of live-account verification, full macOS pricing/localization parity, signed installer or silent verified auto-update. The macOS application source and its local encrypted-file credential design are unchanged.
