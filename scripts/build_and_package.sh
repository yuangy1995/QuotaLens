#!/bin/bash
# ==============================================================================
# QuotaLens for macOS 自动化构建与打包发布脚本
# 支持 Release 编译、组装标准 macOS .app Bundle、代码签名、生成 DMG 与 ZIP 归档
# ==============================================================================

set -euo pipefail

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="QuotaLens"
BUNDLE_IDENTIFIER="com.quotalens.macos"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}-macOS.dmg"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-macOS.zip"

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}  QuotaLens macOS 自动化构建与打包流水线               ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "项目根目录: ${BLUE}${PROJECT_DIR}${NC}"
echo -e "输出目录  : ${BLUE}${DIST_DIR}${NC}"

# 1. 环境准备与清理
echo -e "\n${YELLOW}[1/6] 清理旧构建产物...${NC}"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# 2. Release 编译
echo -e "\n${YELLOW}[2/6] 编译 Release 可执行文件 (Swift 6)...${NC}"
cd "${PROJECT_DIR}"
swift build -c release

RELEASE_BIN="${BUILD_DIR}/release/${APP_NAME}"
if [ ! -f "${RELEASE_BIN}" ]; then
    echo -e "${RED}错误: 未找到编译生成的二进制文件: ${RELEASE_BIN}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Release 编译成功${NC}"

# 3. 组装标准 .app Bundle 目录结构
echo -e "\n${YELLOW}[3/6] 组装 macOS .app Bundle 结构...${NC}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# 复制二进制
cp "${RELEASE_BIN}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# 写入 PkgInfo
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# 复制 Info.plist
if [ -f "${PROJECT_DIR}/Resources/Info.plist" ]; then
    cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
    plutil -lint "${APP_BUNDLE}/Contents/Info.plist" >/dev/null
else
    echo -e "${YELLOW}未找到 Resources/Info.plist，自动生成默认 Info.plist${NC}"
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
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
fi

# 复制 AppIcon.icns
if [ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    echo -e "${GREEN}✓ 应用图标复制完成${NC}"
fi

# 复制资源包 (Resources Bundle)
RESOURCE_BUNDLE="${BUILD_DIR}/release/QuotaLens_QuotaLens.bundle"
SOURCE_RESOURCE_DIR="${PROJECT_DIR}/Sources/QuotaLens/Resources"
if [ -d "${SOURCE_RESOURCE_DIR}" ] && [ -n "$(find "${SOURCE_RESOURCE_DIR}" -type f -print -quit)" ]; then
    if [ ! -d "${RESOURCE_BUNDLE}" ]; then
        echo -e "${RED}错误: 未找到 SwiftPM 资源包: ${RESOURCE_BUNDLE}${NC}"
        exit 1
    fi
    cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/Resources/"
    echo -e "${GREEN}✓ 资源包复制完成${NC}"
else
    echo -e "${YELLOW}未生成 SwiftPM 资源包，跳过资源包复制${NC}"
fi

if grep -R "Bundle\\.module" "${PROJECT_DIR}/Sources/QuotaLens" >/dev/null; then
    echo -e "${RED}错误: 源码仍直接使用 Bundle.module，手工 .app 跨机器运行可能闪退${NC}"
    exit 1
fi

# 移除本机扩展属性和 AppleDouble 元数据，避免 ZIP/DMG 带入 ._* 垃圾文件。
find "${APP_BUNDLE}" \( -name ".DS_Store" -o -name "._*" \) -delete
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

# 4. 代码签名 (Code Signing)
echo -e "\n${YELLOW}[4/6] 执行代码签名...${NC}"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-"-"}"

if [ "${SIGN_IDENTITY}" == "-" ]; then
    echo -e "使用 ${CYAN}Ad-Hoc 本地签名${NC}"
    codesign --force --deep --sign - "${APP_BUNDLE}"
else
    echo -e "使用 Developer ID 签名: ${CYAN}${SIGN_IDENTITY}${NC}"
    codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
fi

# 验证签名
codesign -v --deep "${APP_BUNDLE}"
echo -e "${GREEN}✓ 代码签名验证通过${NC}"

# 5. 打包 ZIP 归档
echo -e "\n${YELLOW}[5/6] 生成 ZIP 压缩归档...${NC}"
cd "${DIST_DIR}"
ditto --norsrc --noextattr -c -k --keepParent "${APP_NAME}.app" "${ZIP_PATH}"
echo -e "${GREEN}✓ ZIP 归档生成完成: ${ZIP_PATH}${NC}"

# 6. 打包 DMG 安装镜像
echo -e "\n${YELLOW}[6/6] 生成 DMG 安装包...${NC}"
DMG_TMP_DIR="${DIST_DIR}/dmg_temp"
rm -rf "${DMG_TMP_DIR}"
mkdir -p "${DMG_TMP_DIR}"

ditto --norsrc --noextattr "${APP_BUNDLE}" "${DMG_TMP_DIR}/${APP_NAME}.app"
ln -s /Applications "${DMG_TMP_DIR}/Applications"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TMP_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}"

rm -rf "${DMG_TMP_DIR}"
echo -e "${GREEN}✓ DMG 安装包生成完成: ${DMG_PATH}${NC}"

# 输出构建清单
echo -e "\n${CYAN}======================================================${NC}"
echo -e "${GREEN}🎉 打包流水线执行完毕！${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "可执行应用包 : ${BLUE}${APP_BUNDLE}${NC}"
echo -e "DMG 安装镜像 : ${BLUE}${DMG_PATH}${NC} ($(du -sh "${DMG_PATH}" | awk '{print $1}'))"
echo -e "ZIP 归档文件 : ${BLUE}${ZIP_PATH}${NC} ($(du -sh "${ZIP_PATH}" | awk '{print $1}'))"
echo -e "SHA-256 (DMG): $(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
echo -e "SHA-256 (ZIP): $(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
echo -e "${CYAN}======================================================${NC}"
