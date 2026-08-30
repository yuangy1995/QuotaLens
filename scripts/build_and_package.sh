#!/bin/bash
# ==============================================================================
# QuotaLens for macOS build and packaging script.
# Builds Apple Silicon, Intel, or Universal app bundles and produces ZIP/DMG
# release assets whose names include the project version.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QuotaLens"
BUNDLE_IDENTIFIER="com.quotalens.macos"
CONFIGURATION="release"
DIST_DIR="${PROJECT_DIR}/dist"
REQUESTED_ARCH="${ARCH:-auto}"
APP_VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-"-"}"
SIGNING_MODE="${QUOTALENS_SIGNING_MODE:-adhoc}"
NOTARIZE="${QUOTALENS_NOTARIZE:-0}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
CLEAN_BUILD="${QUOTALENS_CLEAN_BUILD:-0}"
FAST_LOCAL_BUILD="${QUOTALENS_FAST_LOCAL_BUILD:-auto}"
PIPELINE_START_SECONDS="${SECONDS}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --arch <auto|apple-silicon|arm64|intel|x86_64|universal>
      Build architecture. Defaults to the current Mac's native architecture.
  --version <semver>
      Marketing version. Defaults to VERSION file.
  --build-number <number>
      CFBundleVersion. Defaults to git commit count, or 1 outside git.
  --configuration <debug|release>
      Swift build configuration. Defaults to release.
  --clean
      Delete the architecture-specific Swift build cache before compiling.
  --fast-local
      Use incremental optimized compilation for local packaging.
  --full-optimization
      Use Swift release whole-module optimization. This is always used for
      Developer ID and CI builds unless --fast-local is passed explicitly.
  --dist-dir <path>
      Output directory. Defaults to ./dist.
  --signing-mode <adhoc|developer-id>
      Signing mode. Defaults to adhoc for local packaging.
  --notarize
      Submit the signed app and DMG to Apple notarization, staple tickets, and
      run Gatekeeper assessment. Requires Developer ID signing and Apple
      notary credentials.
  -h, --help
      Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            REQUESTED_ARCH="${2:-}"
            shift 2
            ;;
        --version)
            APP_VERSION="${2:-}"
            shift 2
            ;;
        --build-number)
            BUILD_NUMBER="${2:-}"
            shift 2
            ;;
        --configuration)
            CONFIGURATION="${2:-}"
            shift 2
            ;;
        --clean)
            CLEAN_BUILD="1"
            shift
            ;;
        --fast-local)
            FAST_LOCAL_BUILD="1"
            shift
            ;;
        --full-optimization)
            FAST_LOCAL_BUILD="0"
            shift
            ;;
        --dist-dir)
            DIST_DIR="${2:-}"
            shift 2
            ;;
        --signing-mode)
            SIGNING_MODE="${2:-}"
            shift 2
            ;;
        --notarize)
            NOTARIZE="1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            exit 2
            ;;
    esac
done

case "${SIGNING_MODE}" in
    adhoc|developer-id)
        ;;
    *)
        echo -e "${RED}Unsupported signing mode: ${SIGNING_MODE}${NC}"
        usage
        exit 2
        ;;
esac

if [[ "${SIGNING_MODE}" == "developer-id" && "${SIGN_IDENTITY}" == "-" ]]; then
    echo -e "${RED}Developer ID signing requested but DEVELOPER_ID_APPLICATION is missing.${NC}"
    exit 1
fi

if [[ "${NOTARIZE}" == "1" && "${SIGNING_MODE}" != "developer-id" ]]; then
    echo -e "${RED}Notarization requires --signing-mode developer-id.${NC}"
    exit 1
fi

case "${CLEAN_BUILD}" in
    0|1) ;;
    *)
        echo -e "${RED}QUOTALENS_CLEAN_BUILD must be 0 or 1.${NC}"
        exit 2
        ;;
esac

case "${FAST_LOCAL_BUILD}" in
    auto|0|1) ;;
    *)
        echo -e "${RED}QUOTALENS_FAST_LOCAL_BUILD must be auto, 0, or 1.${NC}"
        exit 2
        ;;
esac

if [[ "${FAST_LOCAL_BUILD}" == "auto" ]]; then
    if [[ "${CONFIGURATION}" == "release" && "${SIGNING_MODE}" == "adhoc" && -z "${CI:-}" ]]; then
        FAST_LOCAL_BUILD="1"
    else
        FAST_LOCAL_BUILD="0"
    fi
fi

if [[ "${CONFIGURATION}" != "release" ]]; then
    FAST_LOCAL_BUILD="0"
fi

notarytool_submit() {
    local artifact="$1"
    if [[ -n "${APPLE_KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "${artifact}" \
            --keychain-profile "${APPLE_KEYCHAIN_PROFILE}" \
            --wait
        return
    fi

    if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
        echo -e "${RED}Missing Apple notarization credentials. Set APPLE_KEYCHAIN_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD.${NC}"
        exit 1
    fi

    xcrun notarytool submit "${artifact}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
        --wait
}

if [[ -z "${APP_VERSION}" ]]; then
    if [[ -f "${PROJECT_DIR}/VERSION" ]]; then
        APP_VERSION="$(tr -d '[:space:]' < "${PROJECT_DIR}/VERSION")"
    else
        APP_VERSION="1.0.0"
    fi
fi

if [[ ! "${APP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo -e "${RED}Invalid version: ${APP_VERSION}${NC}"
    echo "Use semantic versions such as 1.0.0, 1.1.0, or 2.0.0-beta.1."
    exit 2
fi

if [[ -z "${BUILD_NUMBER}" ]]; then
    BUILD_NUMBER="$(git -C "${PROJECT_DIR}" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

if [[ ! "${BUILD_NUMBER}" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo -e "${RED}Invalid build number: ${BUILD_NUMBER}${NC}"
    echo "Use an integer or dot-separated integer string such as 42 or 42.1."
    exit 2
fi

if [[ "${REQUESTED_ARCH}" == "auto" ]]; then
    HOST_ARCH="$(uname -m)"
    IS_TRANSLATED="$(sysctl -in sysctl.proc_translated 2>/dev/null || true)"
    if [[ "${HOST_ARCH}" == "arm64" || "${IS_TRANSLATED}" == "1" ]]; then
        REQUESTED_ARCH="arm64"
    elif [[ "${HOST_ARCH}" == "x86_64" ]]; then
        REQUESTED_ARCH="x86_64"
    else
        echo -e "${RED}Unsupported host architecture: ${HOST_ARCH}${NC}"
        exit 2
    fi
fi

case "${REQUESTED_ARCH}" in
    apple-silicon|arm64)
        ARCH_KEY="apple-silicon"
        ARCH_LABEL="Apple Silicon"
        SWIFT_ARCHES=("arm64")
        ;;
    intel|x86_64)
        ARCH_KEY="intel"
        ARCH_LABEL="Intel"
        SWIFT_ARCHES=("x86_64")
        ;;
    universal|fat)
        ARCH_KEY="universal"
        ARCH_LABEL="Universal"
        SWIFT_ARCHES=("arm64" "x86_64")
        ;;
    *)
        echo -e "${RED}Unsupported architecture: ${REQUESTED_ARCH}${NC}"
        usage
        exit 2
        ;;
esac

BUILD_ROOT="${PROJECT_DIR}/.build/package-${ARCH_KEY}"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
ASSET_BASENAME="${APP_NAME}-v${APP_VERSION}-macOS-${ARCH_KEY}"
DMG_PATH="${DIST_DIR}/${ASSET_BASENAME}.dmg"
ZIP_PATH="${DIST_DIR}/${ASSET_BASENAME}.zip"
UNIVERSAL_BIN="${BUILD_ROOT}/${APP_NAME}-universal"
RELEASE_BIN=""
RESOURCE_BUNDLE=""
BUILT_BIN=""

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}  QuotaLens macOS build and packaging pipeline        ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "Project     : ${BLUE}${PROJECT_DIR}${NC}"
echo -e "Version     : ${BLUE}${APP_VERSION}${NC}"
echo -e "Build number: ${BLUE}${BUILD_NUMBER}${NC}"
echo -e "Architecture: ${BLUE}${ARCH_LABEL}${NC}"
echo -e "Signing     : ${BLUE}${SIGNING_MODE}${NC}"
echo -e "Notarize    : ${BLUE}${NOTARIZE}${NC}"
if [[ "${FAST_LOCAL_BUILD}" == "1" ]]; then
    echo -e "Compilation : ${BLUE}incremental optimized local build${NC}"
else
    echo -e "Compilation : ${BLUE}${CONFIGURATION} full optimization${NC}"
fi
echo -e "Clean build : ${BLUE}${CLEAN_BUILD}${NC}"
echo -e "Output      : ${BLUE}${DIST_DIR}${NC}"

echo -e "\n${YELLOW}[1/6] Preparing output directories...${NC}"
rm -rf "${DIST_DIR}"
if [[ "${CLEAN_BUILD}" == "1" ]]; then
    rm -rf "${BUILD_ROOT}"
fi
mkdir -p "${DIST_DIR}" "${BUILD_ROOT}"

build_for_arch() {
    local arch="$1"
    local scratch="${BUILD_ROOT}/${arch}"
    echo -e "${YELLOW}Building ${APP_NAME} for ${arch}...${NC}"
    local build_args=(
        -c "${CONFIGURATION}"
        --arch "${arch}"
        --scratch-path "${scratch}"
        --disable-index-store
    )
    if [[ "${FAST_LOCAL_BUILD}" == "1" ]]; then
        build_args+=(
            -Xswiftc -no-whole-module-optimization
            -Xswiftc -enable-batch-mode
            -Xswiftc -incremental
        )
    fi
    swift build "${build_args[@]}"

    local bin="${scratch}/${arch}-apple-macosx/${CONFIGURATION}/${APP_NAME}"
    if [[ ! -f "${bin}" ]]; then
        echo -e "${RED}Missing build output: ${bin}${NC}"
        exit 1
    fi

    if [[ -z "${RESOURCE_BUNDLE}" ]]; then
        local candidate="${scratch}/${arch}-apple-macosx/${CONFIGURATION}/QuotaLens_QuotaLens.bundle"
        if [[ -d "${candidate}" ]]; then
            RESOURCE_BUNDLE="${candidate}"
        fi
    fi

    BUILT_BIN="${bin}"
}

echo -e "\n${YELLOW}[2/6] Compiling Swift package...${NC}"
cd "${PROJECT_DIR}"
BUILD_START_SECONDS="${SECONDS}"

if [[ "${#SWIFT_ARCHES[@]}" -eq 1 ]]; then
    build_for_arch "${SWIFT_ARCHES[0]}"
    RELEASE_BIN="${BUILT_BIN}"
else
    build_for_arch arm64
    ARM_BIN="${BUILT_BIN}"
    build_for_arch x86_64
    X86_BIN="${BUILT_BIN}"
    lipo -create "${ARM_BIN}" "${X86_BIN}" -output "${UNIVERSAL_BIN}"
    RELEASE_BIN="${UNIVERSAL_BIN}"
fi

lipo -info "${RELEASE_BIN}"
echo -e "${GREEN}Release build succeeded in $((SECONDS - BUILD_START_SECONDS))s${NC}"

echo -e "\n${YELLOW}[3/6] Assembling .app bundle...${NC}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"

cp "${RELEASE_BIN}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

if [[ -f "${PROJECT_DIR}/THIRD_PARTY_NOTICES.md" ]]; then
    cp "${PROJECT_DIR}/THIRD_PARTY_NOTICES.md" "${APP_BUNDLE}/Contents/Resources/"
fi

if [[ -f "${PROJECT_DIR}/Resources/Info.plist" ]]; then
    cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
    plutil -lint "${APP_BUNDLE}/Contents/Info.plist" >/dev/null
else
    cat <<EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_IDENTIFIER}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
fi

plutil -replace CFBundleExecutable -string "${APP_NAME}" "${APP_BUNDLE}/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "${BUNDLE_IDENTIFIER}" "${APP_BUNDLE}/Contents/Info.plist"
plutil -replace CFBundleName -string "${APP_NAME}" "${APP_BUNDLE}/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "${APP_VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${APP_BUNDLE}/Contents/Info.plist"

if [[ -n "${SPARKLE_PUBLIC_ED_KEY}" ]]; then
    plutil -replace SUPublicEDKey -string "${SPARKLE_PUBLIC_ED_KEY}" "${APP_BUNDLE}/Contents/Info.plist"
fi

SPARKLE_SEARCH_ROOT="${BUILD_ROOT}/${SWIFT_ARCHES[0]}"
SPARKLE_FRAMEWORK="$(find "${SPARKLE_SEARCH_ROOT}" -path "*/Sparkle.framework" -type d -print -quit 2>/dev/null || true)"
if [[ -z "${SPARKLE_FRAMEWORK}" || ! -d "${SPARKLE_FRAMEWORK}" ]]; then
    echo -e "${RED}Sparkle.framework is missing from the selected build output.${NC}"
    exit 1
fi
ditto --norsrc --noextattr "${SPARKLE_FRAMEWORK}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
if ! otool -l "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
fi

if [[ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

SOURCE_RESOURCE_DIR="${PROJECT_DIR}/Sources/QuotaLens/Resources"
if [[ -d "${SOURCE_RESOURCE_DIR}" ]] && [[ -n "$(find "${SOURCE_RESOURCE_DIR}" -type f -print -quit)" ]]; then
    if [[ -z "${RESOURCE_BUNDLE}" ]] || [[ ! -d "${RESOURCE_BUNDLE}" ]]; then
        echo -e "${RED}Missing SwiftPM resource bundle for ${APP_NAME}${NC}"
        exit 1
    fi
    cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/Resources/"
fi

if grep -R "Bundle\\.module" "${PROJECT_DIR}/Sources/QuotaLens" >/dev/null; then
    echo -e "${RED}Source still uses Bundle.module directly; packaged app may fail on another machine.${NC}"
    exit 1
fi

find "${APP_BUNDLE}" \( -name ".DS_Store" -o -name "._*" \) -delete
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

SOURCE_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
cat > "${APP_BUNDLE}/Contents/Resources/RELEASE.txt" <<EOF
${APP_NAME} v${APP_VERSION}
Build: ${BUILD_NUMBER}
Architecture: ${ARCH_LABEL}
Signing: ${SIGNING_MODE}
Team ID: ${APPLE_TEAM_ID:-not-applicable}
Notarization requested: ${NOTARIZE}
Source commit: ${SOURCE_COMMIT}
EOF

echo -e "${GREEN}.app bundle assembled${NC}"

echo -e "\n${YELLOW}[3b/6] Verifying packaged Mach-O architectures...${NC}"
SPARKLE_BUNDLE="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
SPARKLE_REQUIRED_COMPONENTS=(
    "Versions/Current/Sparkle"
    "Versions/Current/Autoupdate"
    "Versions/Current/Updater.app/Contents/MacOS/Updater"
    "Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    "Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer"
)
for component in "${SPARKLE_REQUIRED_COMPONENTS[@]}"; do
    if [[ ! -f "${SPARKLE_BUNDLE}/${component}" ]]; then
        echo -e "${RED}Missing Sparkle component: ${component}${NC}"
        exit 1
    fi
done

MACHO_COUNT=0
while IFS= read -r -d '' macho_file; do
    if ! file -b "${macho_file}" | grep -q "Mach-O"; then
        continue
    fi
    MACHO_COUNT=$((MACHO_COUNT + 1))
    macho_arches="$(lipo -archs "${macho_file}")"
    echo "${macho_file#${APP_BUNDLE}/}: ${macho_arches}"
    for required_arch in "${SWIFT_ARCHES[@]}"; do
        if [[ " ${macho_arches} " != *" ${required_arch} "* ]]; then
            echo -e "${RED}${macho_file} is missing required architecture ${required_arch}.${NC}"
            exit 1
        fi
    done
done < <(find "${APP_BUNDLE}/Contents" -type f -print0)

if [[ "${MACHO_COUNT}" -eq 0 ]]; then
    echo -e "${RED}No Mach-O files were found in the app bundle.${NC}"
    exit 1
fi
echo -e "${GREEN}All ${MACHO_COUNT} packaged Mach-O files contain the required architectures${NC}"

echo -e "\n${YELLOW}[4/6] Signing app bundle...${NC}"
if [[ -d "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework" ]]; then
    if [[ "${SIGNING_MODE}" == "adhoc" ]]; then
        codesign --force --deep --sign - "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
    else
        codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
    fi
fi

if [[ "${SIGNING_MODE}" == "adhoc" ]]; then
    echo -e "Using ${CYAN}ad-hoc local signing${NC}"
    codesign --force --deep --sign - "${APP_BUNDLE}"
else
    echo -e "Using Developer ID signing identity: ${CYAN}${SIGN_IDENTITY}${NC}"
    codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
fi
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
echo -e "${GREEN}Code signature verified${NC}"

if [[ "${NOTARIZE}" == "1" ]]; then
    echo -e "\n${YELLOW}[4b/6] Notarizing and stapling app bundle...${NC}"
    APP_NOTARY_ZIP="${DIST_DIR}/${ASSET_BASENAME}-notary.zip"
    (
        cd "${DIST_DIR}"
        ditto --norsrc --noextattr -c -k --keepParent "${APP_NAME}.app" "${APP_NOTARY_ZIP}"
    )
    notarytool_submit "${APP_NOTARY_ZIP}"
    xcrun stapler staple "${APP_BUNDLE}"
    spctl --assess --type execute --verbose=2 "${APP_BUNDLE}"
    rm -f "${APP_NOTARY_ZIP}"
    echo -e "${GREEN}App notarization, stapling, and Gatekeeper assessment passed${NC}"
fi

echo -e "\n${YELLOW}[5/6] Creating ZIP archive...${NC}"
(
    cd "${DIST_DIR}"
    ditto --norsrc --noextattr -c -k --keepParent "${APP_NAME}.app" "${ZIP_PATH}"
)
echo -e "${GREEN}ZIP created: ${ZIP_PATH}${NC}"

echo -e "\n${YELLOW}[6/6] Creating DMG image...${NC}"
DMG_TMP_DIR="${DIST_DIR}/dmg_temp"
rm -rf "${DMG_TMP_DIR}"
mkdir -p "${DMG_TMP_DIR}"

ditto --norsrc --noextattr "${APP_BUNDLE}" "${DMG_TMP_DIR}/${APP_NAME}.app"
ln -s /Applications "${DMG_TMP_DIR}/Applications"

create_dmg_image() {
    local max_attempts=5
    local attempt=1
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if hdiutil create -volname "${APP_NAME} v${APP_VERSION}" \
            -srcfolder "${DMG_TMP_DIR}" \
            -ov -format UDZO \
            "${DMG_PATH}"; then
            return 0
        fi
        echo -e "${YELLOW}hdiutil create failed (attempt ${attempt}/${max_attempts}), retrying in 3s...${NC}"
        sleep 3
        ((attempt++))
    done
    return 1
}

create_dmg_image

rm -rf "${DMG_TMP_DIR}"
echo -e "${GREEN}DMG created: ${DMG_PATH}${NC}"

if [[ "${NOTARIZE}" == "1" ]]; then
    echo -e "\n${YELLOW}[6b/6] Notarizing and stapling DMG...${NC}"
    notarytool_submit "${DMG_PATH}"
    xcrun stapler staple "${DMG_PATH}"
    spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
    echo -e "${GREEN}DMG notarization, stapling, and Gatekeeper assessment passed${NC}"
fi

echo -e "\n${CYAN}======================================================${NC}"
echo -e "${GREEN}Packaging complete${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "App bundle : ${BLUE}${APP_BUNDLE}${NC}"
echo -e "DMG        : ${BLUE}${DMG_PATH}${NC} ($(du -sh "${DMG_PATH}" | awk '{print $1}'))"
echo -e "ZIP        : ${BLUE}${ZIP_PATH}${NC} ($(du -sh "${ZIP_PATH}" | awk '{print $1}'))"
echo -e "SHA-256 DMG: $(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
echo -e "SHA-256 ZIP: $(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
echo -e "Elapsed     : ${BLUE}$((SECONDS - PIPELINE_START_SECONDS))s${NC}"
echo -e "${CYAN}======================================================${NC}"
