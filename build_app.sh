#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iClip"
VERSION=""
INSTALL_AFTER_BUILD="0"
for arg in "$@"; do
  case "$arg" in
    --install)
      INSTALL_AFTER_BUILD="1"
      ;;
    --*)
      echo "未知参数: $arg" >&2
      exit 1
      ;;
    *)
      if [ -z "$VERSION" ]; then
        VERSION="$arg"
      fi
      ;;
  esac
done
if [ -z "$VERSION" ]; then
  VERSION="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "3.0.0")"
fi
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST_DIR="$PROJECT_DIR/dist"
BRAND_DIR="$PROJECT_DIR/assets/brand"

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
SIGN_USE_HARDENED_RUNTIME="0"
if [ -n "$SIGN_IDENTITY" ]; then
  if [[ "$SIGN_IDENTITY" == *"Developer ID Application"* ]]; then
    SIGN_USE_HARDENED_RUNTIME="1"
  fi
else
  DEV_ID_APP="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}' || true)"
  if [ -n "$DEV_ID_APP" ]; then
    SIGN_IDENTITY="$DEV_ID_APP"
    SIGN_USE_HARDENED_RUNTIME="1"
  else
    APPLE_DEV_CERT="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}' || true)"
    if [ -n "$APPLE_DEV_CERT" ]; then
      SIGN_IDENTITY="$APPLE_DEV_CERT"
      SIGN_USE_HARDENED_RUNTIME="0"
    fi
  fi
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

SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo "27.2")"
SDK_BUILD="$(xcrun --show-sdk-build-version 2>/dev/null || echo "27B52")"

BIN_PATH="$SCRATCH_DIR/release/iClip"
rm -rf "$STAGE_DIR" "$FINAL_APP" "$ZIP_OUT" "$DMG_STAGE" "$DMG_OUT"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_PATH" "$STAGED_APP/Contents/MacOS/iClip"
chmod +x "$STAGED_APP/Contents/MacOS/iClip"
strip -x "$STAGED_APP/Contents/MacOS/iClip" 2>/dev/null || true
if command -v vtool >/dev/null 2>&1; then
  # 保留 minos=14.0 向下兼容，同时将 Mach-O LC_BUILD_VERSION 的 sdk 升级为当前 macOS SDK（如 27.2），
  # 激活 macOS 26/27 原生 Liquid Glass 开关动效、液态滑块与浮动玻璃侧边栏
  vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$STAGED_APP/Contents/MacOS/iClip" "$STAGED_APP/Contents/MacOS/iClip"
fi

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
    <string>com.iclip.clipboard</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>iClip</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>DTSDKName</key>
    <string>macosx${SDK_VERSION}</string>
    <key>DTSDKBuild</key>
    <string>${SDK_BUILD}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppDataUsageDescription</key>
    <string>需要读取您从微信、飞书等应用复制或拖拽到 iClip 的高清图片，以便为您直接展示原图并存入剪贴板。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>长按悬浮精灵时录制您的语音，以便即时转写为 iClip 待办事项。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>用于将您长按悬浮精灵说出的语音实时转写为文字并加入待办清单。</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.iclip.archive</string>
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
  echo "使用证书签名：$SIGN_IDENTITY（Hardened Runtime=${SIGN_USE_HARDENED_RUNTIME}）"
  if [ "$SIGN_USE_HARDENED_RUNTIME" = "1" ]; then
    codesign --force --deep --options runtime --identifier com.iclip.clipboard --sign "$SIGN_IDENTITY" "$STAGED_APP"
  else
    codesign --force --deep --identifier com.iclip.clipboard --sign "$SIGN_IDENTITY" "$STAGED_APP"
  fi
else
  echo "未发现开发者签名证书，回退跨机通用 Ad-hoc 签名..."
  codesign --force --deep --identifier com.iclip.clipboard --sign - "$STAGED_APP"
fi

codesign --verify --deep --strict "$STAGED_APP"
codesign -dv --requirements - "$STAGED_APP" 2>&1 | grep -E "Authority=|Signature=|designated" || true

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

if [ "$INSTALL_AFTER_BUILD" = "1" ]; then
  TARGET_APP="/Applications/${APP_NAME}.app"
  NEW_SIG_DESC="$(codesign -dv "$FINAL_APP" 2>&1 | grep -E '^(Authority=|Signature=|TeamIdentifier=)' | sort | tr '\n' '|')"
  OLD_SIG_DESC=""
  if [ -d "$TARGET_APP" ]; then
    OLD_SIG_DESC="$(codesign -dv "$TARGET_APP" 2>&1 | grep -E '^(Authority=|Signature=|TeamIdentifier=)' | sort | tr '\n' '|')"
  fi

  echo "------------------------------------------"
  echo "正在安装更新至 ${TARGET_APP}..."
  osascript -e 'tell application "iClip" to quit' 2>/dev/null || true
  pkill -x iClip 2>/dev/null || true
  pkill -x QingJian 2>/dev/null || true
  sleep 1

  if [ -n "$OLD_SIG_DESC" ] && [ "$OLD_SIG_DESC" != "$NEW_SIG_DESC" ]; then
    echo "检测到应用签名变化，清理旧 TCC 同名授权残留避免假勾选..."
    tccutil reset Accessibility com.iclip.clipboard >/dev/null 2>&1 || true
    tccutil reset ScreenCapture com.iclip.clipboard >/dev/null 2>&1 || true
    tccutil reset SystemPolicyAllFiles com.iclip.clipboard >/dev/null 2>&1 || true
  fi

  rm -rf "$TARGET_APP"
  ditto "$FINAL_APP" "$TARGET_APP"
  # 清理构建目录中的解压 .app 副本（保留 .dmg/.zip），避免同名多副本导致 TCC/LaunchServices 串位
  rm -rf "$FINAL_APP"
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$LSREG" ]; then
    "$LSREG" -f "$TARGET_APP" >/dev/null 2>&1 || true
  fi
  open "$TARGET_APP"
  echo "✓ 已唯一安装并启动 ${TARGET_APP}"
fi
