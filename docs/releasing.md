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

Build one downloadable package:

```bash
./scripts/build_and_package.sh --arch apple-silicon
./scripts/build_and_package.sh --arch intel
./scripts/build_and_package.sh --arch universal
```

The script reads `VERSION` automatically. You can override it:

```bash
./scripts/build_and_package.sh --arch universal --version 1.0.1 --build-number 42
```

## Publishing A GitHub Release

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
- `SHA256SUMS.txt`

The workflow validates that the pushed tag matches `VERSION`.
