#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iClip"
VERSION="${1:-$(cat "$PROJECT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "1.2.0")}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
BUNDLE_DIR="$PROJECT_DIR/dist/${APP_NAME}.app"
ZIP_PATH="$PROJECT_DIR/dist/iClip-macOS.zip"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "正在编译 Release 版本 (v${VERSION})..."
cd "$PROJECT_DIR"
swift build -c release

BIN_PATH="$PROJECT_DIR/.build/release/QingJian"

echo "正在打包 ${APP_NAME}.app ..."
rm -rf "$BUNDLE_DIR" "$ZIP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/QingJian"
chmod +x "$MACOS_DIR/QingJian"

cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>iClip</string>
    <key>CFBundleDisplayName</key>
    <string>iClip</string>
    <key>CFBundleIdentifier</key>
    <string>com.qingjian.clipboard</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>QingJian</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 优先使用本机固定开发者证书签名，避免 OTA/重编后 macOS 辅助功能权限漂移失效
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}' || true)"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "使用稳定代码签名证书：$SIGN_IDENTITY"
  codesign --force --deep --options runtime --identifier com.qingjian.clipboard --sign "$SIGN_IDENTITY" "$BUNDLE_DIR" 2>/dev/null \
    || codesign --force --deep --identifier com.qingjian.clipboard --sign "$SIGN_IDENTITY" "$BUNDLE_DIR"
else
  echo "未检测到开发者证书，使用本地临时签名..."
  codesign --force --deep --identifier com.qingjian.clipboard --sign - "$BUNDLE_DIR" 2>/dev/null || true
fi

# 打包为保留代码签名与资源叉的标准 OTA 压缩包
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_DIR" "$ZIP_PATH"

echo "打包完成："
echo "  应用：$BUNDLE_DIR"
echo "  OTA 包：$ZIP_PATH"
