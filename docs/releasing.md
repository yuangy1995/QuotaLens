# Release Process

QuotaLens uses `VERSION` as the marketing-version source and matching `vX.Y.Z` Git tags. The `Release macOS and Windows` workflow builds both platforms from the exact tagged commit. Ordinary pushes to main build/test only and do not publish a release. Existing tags must not be moved to add Windows.

## Version and build identity

Use patch versions for fixes, minor versions for compatible features and major versions for incompatible behavior. `CFBundleShortVersionString` and Windows assembly/package marketing versions come from `VERSION`. macOS `CFBundleVersion` uses the Actions run number (or local git commit count). Windows archives include `BUILD-INFO.json` with the exact source SHA; a development archive sharing a marketing version with an old tag is not a new stable release.

Before tagging, confirm both CI workflows for the intended commit, review [Windows acceptance](windows.md#manual-acceptance-still-required), and update the changelog. A native smoke test does not substitute for real account or hardware acceptance.

## Local macOS packaging

```bash
swift test
swift build -c release
swift test -c release --filter CodexCapacityForecastTests
./scripts/build_and_package.sh
./scripts/build_and_package.sh --arch apple-silicon --version 1.2.0 --build-number 42
```

The script detects the current Mac architecture unless `--arch apple-silicon`, `--arch intel` or `--arch universal` is supplied. Local packages use ad-hoc signing. Architecture-specific incremental optimized caches are retained; `--clean` discards them and `--full-optimization` matches whole-module release optimization.

A successful incremental local build does not establish whole-module Release compatibility. Keep compiler-compatibility changes covered by behavior tests rather than disabling optimization or ownership checks. Keep legacy localization initializers split per language and extended tables in bounded static groups; preserve sequential fallback lookups for older Swift type-checkers. The existing localization regression tests cover those boundaries.

## Local Windows packaging

On Windows, from the repository root:

```powershell
dotnet run --project windows/QuotaLens.Core.Tests -c Release
dotnet run --project windows/QuotaLens.Providers.Tests -c Release
dotnet run --project windows/QuotaLens.Infrastructure.Tests -c Release
./windows/scripts/build.ps1
```

The script generates Windows artwork from the original ICNS, publishes a self-contained native x64 directory, launches that published executable in isolated test mode and creates `windows/artifacts/QuotaLens-Windows-x64-vX.Y.Z.zip` plus a checksum. The ZIP includes guides, original project license, available package notices, dependency metadata and build provenance. Native screenshots/test results remain separate validation artifacts, not demo accounts in production.

Do not remove DLLs, XAML/PRI resources or bundled runtime files. `-SkipSmoke` is for local diagnostics only; release/CI does not use it. Windows packages currently remain unsigned directory archives, not signed installers or automatic verified upgrades. See [the Windows guide](windows.md#packaging-and-updates).

## Signing and publishing

macOS update-capable builds require repository secrets `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_PRIVATE_ED_KEY`. The public key is embedded in the Mac app; the private EdDSA key signs Mac update archives/appcasts only. No private key is committed to Git. Existing macOS release behavior remains ad-hoc code signing without Apple notarization; Sparkle signing does not mean Apple notarization.

To generate/reuse the Sparkle update key pair on the maintainer's Mac:

```bash
swift package resolve
SPARKLE_KEYS_TOOL="./.build/artifacts/sparkle/Sparkle/bin/generate_keys"
"${SPARKLE_KEYS_TOOL}" --account yuangy1995.QuotaLens
"${SPARKLE_KEYS_TOOL}" --account yuangy1995.QuotaLens -p
"${SPARKLE_KEYS_TOOL}" --account yuangy1995.QuotaLens -x sparkle_private_key
```

This Sparkle maintainer key management is separate from application account credentials. macOS application credentials remain in QuotaLens's local encrypted-file store, not Keychain.

Windows does not reuse Sparkle keys, embed an Authenticode certificate, create signing credentials in CI or claim SmartScreen reputation. Add a separate reviewed signing process before advertising signed Windows installation.

After choosing a **new** version and committing it, create the matching tag (the following version is only an example):

```bash
git tag -a v1.2.0 -m "QuotaLens v1.2.0"
git push origin main
git push origin v1.2.0
```

The release workflow validates tag syntax, `VERSION` and the exact checked-out commit on both platforms. It runs the macOS test/Release quality gate and catalog parity, builds Apple Silicon/Intel/Universal packages, and separately runs Windows Core/Providers/Infrastructure tests and the published native UI smoke check. GitHub publication requires both platform build jobs to succeed.

Assets include the three macOS `.dmg`/`.zip` variants, `QuotaLens-Windows-x64-vX.Y.Z.zip`, architecture-specific Mac appcasts, the legacy combined `appcast.xml`, and `SHA256SUMS.txt`. Only package artifacts are merged into the release; native validation evidence is not mistaken for a downloadable app. `gh release create` does not overwrite a pre-existing release automatically. A newly edited workflow is not evidence that a release was actually published.

## Updates

Mac uses separate `appcast-apple-silicon.xml` and `appcast-intel.xml` feeds; the combined `appcast.xml` remains available for legacy clients. The Universal Mac package is a direct-download option. The first v1.0.0 release did not contain Sparkle and needs a manual upgrade to an update-capable build.

Windows checks the official repository's latest release for a Windows archive before offering a browser link. It does not execute an unsigned updater. Quit before replacing the complete app directory; user data remains in a separate directory. Moving the executable may require re-registering its startup entry. Do not claim auto-update or signing acceptance from a successful compilation alone.
