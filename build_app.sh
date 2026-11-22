#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iClip"
VERSION="${1:-$(cat "$PROJECT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "1.8.0")}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST_DIR="$PROJECT_DIR/dist"

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}' || true)"
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

build_edition() {
  local edition_key="$1"       # dev | flow
  local edition_label="$2"     # Dev | Flow
  local swift_flag="$3"        # -DICLIP_EDITION_DEV | -DICLIP_EDITION_FLOW
  local scratch_dir="$PROJECT_DIR/.build-${edition_key}"
  local stage_dir="$DIST_DIR/.stage-${edition_key}"
  local staged_app="$stage_dir/${APP_NAME}.app"
  local named_app="$DIST_DIR/${APP_NAME}-${edition_label}.app"
  local zip_out="$DIST_DIR/${APP_NAME}-${edition_label}-macOS.zip"

  echo "=========================================="
  echo "正在编译 [${edition_label}] 角色版本 (v${VERSION}, flag=${swift_flag})..."
  cd "$PROJECT_DIR"
  swift build -c release --scratch-path "$scratch_dir" -Xswiftc "$swift_flag" -Xswiftc -O -Xlinker -dead_strip

  local bin_path="$scratch_dir/release/QingJian"
  rm -rf "$stage_dir" "$named_app" "$zip_out"
  mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
  cp "$bin_path" "$staged_app/Contents/MacOS/QingJian"
  chmod +x "$staged_app/Contents/MacOS/QingJian"

  cat > "$staged_app/Contents/Info.plist" << EOF
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
    <key>IClipEdition</key>
    <string>${edition_key}</string>
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
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.qingjian.iclip.archive</string>
            <key>UTTypeDescription</key>
            <string>iClip 收藏资产归档包</string>
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

  if [ -n "$SIGN_IDENTITY" ]; then
    echo "签名 [${edition_label}]：$SIGN_IDENTITY"
    codesign --force --deep --options runtime --identifier com.qingjian.clipboard --sign "$SIGN_IDENTITY" "$staged_app" 2>/dev/null \
      || codesign --force --deep --identifier com.qingjian.clipboard --sign "$SIGN_IDENTITY" "$staged_app"
  else
    echo "使用本地临时签名 [${edition_label}]..."
    codesign --force --deep --identifier com.qingjian.clipboard --sign - "$staged_app" 2>/dev/null || true
  fi

  # 严格校验签名完整性
  codesign --verify --deep --strict "$staged_app"

  # 打包 OTA 专属压缩包（压缩包内根应用固定为 iClip.app，确保原地热替换路径一致）
  ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$zip_out"
  ditto "$staged_app" "$named_app"
  rm -rf "$stage_dir"
}

build_edition "dev"  "Dev"  "-DICLIP_EDITION_DEV"
build_edition "flow" "Flow" "-DICLIP_EDITION_FLOW"

# 同步生成兼容 v1.7.x 存量客户端平滑升级的默认入口包（启动后可一键选择并 OTA 切换角色）
ditto "$DIST_DIR/iClip-Dev.app" "$DIST_DIR/iClip.app"
cp "$DIST_DIR/iClip-Dev-macOS.zip" "$DIST_DIR/iClip-macOS.zip"

echo "=========================================="
echo "双角色专属 OTA 构建与自检完成 (v${VERSION})："
ls -lh "$DIST_DIR"/*.zip
shasum -a 256 "$DIST_DIR"/iClip-Dev-macOS.zip "$DIST_DIR"/iClip-Flow-macOS.zip
