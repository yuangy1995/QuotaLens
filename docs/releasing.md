# Release Process

QuotaLens uses a single source of truth for versioning:

- `VERSION` stores the marketing version, such as `1.0.0`.
- Git tags use the same version with a leading `v`, such as `v1.0.0`.
- `CFBundleShortVersionString` is written from `VERSION` during packaging.
- `CFBundleVersion` is the build number. In GitHub Actions it uses `GITHUB_RUN_NUMBER`; locally it defaults to the git commit count.

## Version Rules

Use semantic versioning:

- Patch release: `1.0.1` for bug fixes.
- Minor release: `1.1.0` for compatible new features.
- Major release: `2.0.0` for breaking behavior or identity changes.
- Prerelease: `1.1.0-beta.1` for testing builds.

## Local Packaging

Build one locally signed downloadable package:

```bash
./scripts/build_and_package.sh --arch apple-silicon
./scripts/build_and_package.sh --arch intel
./scripts/build_and_package.sh --arch universal
```

The script reads `VERSION` automatically. You can override it:

```bash
./scripts/build_and_package.sh --arch universal --version 1.0.1 --build-number 42
```

Local packages use ad-hoc signing unless you explicitly request Developer ID signing:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build_and_package.sh --arch universal --signing-mode developer-id
```

Production releases also pass `--notarize`, which requires Apple notarization credentials and runs `codesign --verify --deep --strict`, `xcrun stapler`, and `spctl` checks. The script refuses to notarize ad-hoc builds.

## Product Boundary

QuotaLens' current overlay is an app-owned floating window. It is not a WidgetKit desktop widget and this release process does not build or ship a Widget Extension.

## Publishing A GitHub Release

Before publishing an update-capable production build, configure Sparkle signing, Developer ID signing, and Apple notarization secrets in the GitHub repository:

- `SPARKLE_PUBLIC_ED_KEY`: public EdDSA key embedded into the app bundle.
- `SPARKLE_PRIVATE_ED_KEY`: private EdDSA key used only by GitHub Actions to sign update archives and appcasts.
- `DEVELOPER_ID_APPLICATION`: Developer ID Application identity string, such as `Developer ID Application: Example, Inc. (TEAMID)`.
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`: base64-encoded `.p12` export for that Developer ID Application certificate.
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`: password for the `.p12` export.
- `APPLE_BUILD_KEYCHAIN_PASSWORD`: temporary CI keychain password.
- `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`: credentials used by `xcrun notarytool`.

Generate the key pair once with Sparkle's tools, then keep the private key out of git:

```bash
swift package resolve

# After SwiftPM has resolved Sparkle, the tool is usually under:
SPARKLE_KEYS_TOOL="./.build/artifacts/sparkle/Sparkle/bin/generate_keys"

# Generate or reuse the keychain-stored key pair for this app.
"${SPARKLE_KEYS_TOOL}" --account yuangy1995.QuotaLens

# Print the public key for SPARKLE_PUBLIC_ED_KEY.
"${SPARKLE_KEYS_TOOL}" --account yuangy1995.QuotaLens -p

# Export the private key for SPARKLE_PRIVATE_ED_KEY.
"${SPARKLE_KEYS_TOOL}" --account yuangy1995.QuotaLens -x sparkle_private_key
```

Put the printed public key into `SPARKLE_PUBLIC_ED_KEY`, and put the private key file contents into `SPARKLE_PRIVATE_ED_KEY`.

The workflow intentionally fails when any Developer ID or notarization secret is missing. Production release builds must not fall back to ad-hoc signing.

1. Update `VERSION`.
2. Commit the version change.
3. Create and push a matching tag:

```bash
git tag -a v1.0.0 -m "QuotaLens v1.0.0"
git push origin main
git push origin v1.0.0
```

The `Release macOS` workflow builds and uploads:

- Apple Silicon: `QuotaLens-vX.Y.Z-macOS-apple-silicon.dmg` and `.zip`
- Intel: `QuotaLens-vX.Y.Z-macOS-intel.dmg` and `.zip`
- Universal: `QuotaLens-vX.Y.Z-macOS-universal.dmg` and `.zip`
- In-app update feeds: `appcast-apple-silicon.xml` and `appcast-intel.xml`
- Legacy in-app update feed: `appcast.xml` with both architecture items for older clients
- `SHA256SUMS.txt`

The workflow validates that the pushed tag matches `VERSION`, runs the quality gate (`swift test`, focused migration/parser/pricing tests, `swift build -c release`, and `git diff --check`), signs with Developer ID, notarizes, staples, and Gatekeeper-assesses the resulting app and DMG before publishing.

## In-App Updates

QuotaLens uses Sparkle for macOS self-updates. The release workflow publishes separate appcast feeds for the app's internal update checks:

- `appcast-apple-silicon.xml`
- `appcast-intel.xml`
- `appcast.xml` remains published so older clients that still read the static `SUFeedURL` can update.

The Universal package remains available on the GitHub Release page for direct downloads.

The first public `v1.0.0` build did not include Sparkle. Users must manually install the first Sparkle-enabled version once; versions after that can update in-app.
