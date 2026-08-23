#!/bin/bash
# Generates a Sparkle appcast for one architecture-specific release asset.

set -euo pipefail

ARCH_KEY=""
VERSION=""
BUILD_NUMBER=""
ARCHIVE_PATH=""
OUTPUT_PATH=""
REPOSITORY="${GITHUB_REPOSITORY:-yuangy1995/QuotaLens}"

usage() {
    cat <<EOF
Usage: $0 --arch <apple-silicon|intel> --version <semver> --build-number <number> --archive <zip> --output <appcast.xml>
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            ARCH_KEY="${2:-}"
            shift 2
            ;;
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --build-number)
            BUILD_NUMBER="${2:-}"
            shift 2
            ;;
        --archive)
            ARCHIVE_PATH="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

if [[ "${ARCH_KEY}" != "apple-silicon" && "${ARCH_KEY}" != "intel" ]]; then
    echo "Only apple-silicon and intel appcasts are used for in-app updates."
    exit 2
fi

if [[ -z "${VERSION}" || -z "${BUILD_NUMBER}" || -z "${ARCHIVE_PATH}" || -z "${OUTPUT_PATH}" ]]; then
    usage
    exit 2
fi

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
    echo "Archive not found: ${ARCHIVE_PATH}"
    exit 1
fi

if [[ -z "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
    echo "SPARKLE_PRIVATE_ED_KEY is not set; cannot generate signed Sparkle appcast."
    exit 1
fi

SIGN_UPDATE_PATH="${SIGN_UPDATE_PATH:-$(find .build -path "*/bin/sign_update" -type f -print -quit 2>/dev/null || true)}"
if [[ -z "${SIGN_UPDATE_PATH}" || ! -x "${SIGN_UPDATE_PATH}" ]]; then
    echo "Sparkle sign_update tool not found. Expected it under .build after SwiftPM resolves Sparkle."
    exit 1
fi

SIGNATURE_ATTRIBUTES="$(printf '%s' "${SPARKLE_PRIVATE_ED_KEY}" | "${SIGN_UPDATE_PATH}" "${ARCHIVE_PATH}" --ed-key-file - | tr '\n' ' ')"
if [[ -z "${SIGNATURE_ATTRIBUTES}" || "${SIGNATURE_ATTRIBUTES}" != *"sparkle:edSignature"* ]]; then
    echo "Sparkle signature generation did not return an EdDSA signature."
    exit 1
fi

ASSET_NAME="$(basename "${ARCHIVE_PATH}")"
DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/download/v${VERSION}/${ASSET_NAME}"
RELEASE_URL="https://github.com/${REPOSITORY}/releases/tag/v${VERSION}"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

case "${ARCH_KEY}" in
    apple-silicon)
        ARCH_TITLE="Apple Silicon"
        HARDWARE_REQUIREMENTS="arm64"
        ;;
    intel)
        ARCH_TITLE="Intel"
        HARDWARE_REQUIREMENTS="x86_64"
        ;;
esac

cat > "${OUTPUT_PATH}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>QuotaLens ${ARCH_TITLE} Updates</title>
    <link>https://github.com/${REPOSITORY}</link>
    <description>QuotaLens ${ARCH_TITLE} appcast</description>
    <language>en</language>
    <item>
      <title>QuotaLens v${VERSION}</title>
      <link>${RELEASE_URL}</link>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>${HARDWARE_REQUIREMENTS}</sparkle:hardwareRequirements>
      <description><![CDATA[
        <p>QuotaLens v${VERSION}</p>
        <p>This in-app update feed is architecture-specific and downloads the ${ARCH_TITLE} build automatically.</p>
      ]]></description>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure url="${DOWNLOAD_URL}"
                 ${SIGNATURE_ATTRIBUTES}
                 type="application/zip" />
    </item>
  </channel>
</rss>
EOF

echo "Generated ${OUTPUT_PATH}"
