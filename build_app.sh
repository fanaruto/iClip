#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iClip"
VERSION="${1:-$(cat "$PROJECT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "3.0.0")}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST_DIR="$PROJECT_DIR/dist"
BRAND_DIR="$PROJECT_DIR/assets/brand"

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}' || true)"
fi

if [ ! -f "$BRAND_DIR/AppIcon.icns" ]; then
  echo "正在生成品牌图标资产..."
  swift "$PROJECT_DIR/scripts/render_brand_suite.swift" --active a
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

SCRATCH_DIR="$PROJECT_DIR/.build-unified"
STAGE_DIR="$DIST_DIR/.stage-unified"
STAGED_APP="$STAGE_DIR/${APP_NAME}.app"
FINAL_APP="$DIST_DIR/${APP_NAME}.app"
ZIP_OUT="$DIST_DIR/${APP_NAME}-macOS.zip"
DMG_STAGE="$DIST_DIR/.dmg-unified"
DMG_OUT="$DIST_DIR/${APP_NAME}-macOS.dmg"

echo "=========================================="
echo "正在编译 iClip 统一主线版本 (v${VERSION})..."
cd "$PROJECT_DIR"
swift build -c release --scratch-path "$SCRATCH_DIR" -Xswiftc -Osize -Xlinker -dead_strip

BIN_PATH="$SCRATCH_DIR/release/QingJian"
rm -rf "$STAGE_DIR" "$FINAL_APP" "$ZIP_OUT" "$DMG_STAGE" "$DMG_OUT"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_PATH" "$STAGED_APP/Contents/MacOS/QingJian"
chmod +x "$STAGED_APP/Contents/MacOS/QingJian"
strip -x "$STAGED_APP/Contents/MacOS/QingJian" 2>/dev/null || true

cp "$BRAND_DIR/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$BRAND_DIR/MenuBarIcon.png" "$STAGED_APP/Contents/Resources/MenuBarIcon.png"
cp "$BRAND_DIR/MenuBarIcon@2x.png" "$STAGED_APP/Contents/Resources/MenuBarIcon@2x.png"

cat > "$STAGED_APP/Contents/Info.plist" << EOF
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
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
    <key>NSAppDataUsageDescription</key>
    <string>需要读取您从微信等应用拖拽到 iClip 的图片或文件，以便为您复制到剪贴板。</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.qingjian.iclip.archive</string>
            <key>UTTypeDescription</key>
            <string>iClip 收藏资产归档包</string>
            <key>UTTypeIconFile</key>
            <string>AppIcon</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>iclip</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

xattr -cr "$STAGED_APP" 2>/dev/null || true
if [ -n "$SIGN_IDENTITY" ]; then
  echo "使用分发证书签名：$SIGN_IDENTITY"
  codesign --force --deep --options runtime --identifier com.qingjian.clipboard --sign "$SIGN_IDENTITY" "$STAGED_APP"
else
  echo "使用跨机通用免证书 Ad-hoc 签名..."
  codesign --force --deep --identifier com.qingjian.clipboard --sign - "$STAGED_APP"
fi

codesign --verify --deep --strict "$STAGED_APP"

ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$ZIP_OUT"
ditto "$STAGED_APP" "$FINAL_APP"

mkdir -p "$DMG_STAGE/.background"
ditto "$STAGED_APP" "$DMG_STAGE/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGE/Applications"
if [ -f "$BRAND_DIR/dmg-background.jpg" ]; then
  cp "$BRAND_DIR/dmg-background.jpg" "$DMG_STAGE/.background/background.jpg"
fi
cp "$BRAND_DIR/AppIcon.icns" "$DMG_STAGE/.VolumeIcon.icns"
if [ -x /usr/bin/SetFile ]; then
  /usr/bin/SetFile -a C "$DMG_STAGE" 2>/dev/null || true
fi
hdiutil create -volname "${APP_NAME}" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_OUT" >/dev/null

rm -rf "$STAGE_DIR" "$DMG_STAGE"

echo "=========================================="
echo "iClip 统一主线构建、可视化 DMG 与签名自检完成 (v${VERSION})："
ls -lh "$ZIP_OUT" "$DMG_OUT"
shasum -a 256 "$ZIP_OUT" "$DMG_OUT"
