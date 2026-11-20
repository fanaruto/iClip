#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="轻剪"
BUNDLE_DIR="$PROJECT_DIR/dist/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "正在编译 Release 版本..."
cd "$PROJECT_DIR"
swift build -c release

BIN_PATH="$PROJECT_DIR/.build/release/QingJian"

echo "正在打包 ${APP_NAME}.app ..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/QingJian"
chmod +x "$MACOS_DIR/QingJian"

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>轻剪</string>
    <key>CFBundleDisplayName</key>
    <string>轻剪</string>
    <key>CFBundleIdentifier</key>
    <string>com.qingjian.clipboard</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
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

# 使用本地临时签名，确保系统辅助功能权限可正常识别应用
codesign --force --deep --sign - "$BUNDLE_DIR" 2>/dev/null || true

echo "打包完成：$BUNDLE_DIR"
