#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iClip"
VERSION="${1:-$(cat "$PROJECT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "2.5.0")}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST_DIR="$PROJECT_DIR/dist"
BRAND_DIR="$PROJECT_DIR/assets/brand"

# 免证书零报错分发策略：
# 仅在显式提供 CODESIGN_IDENTITY 或本机存在正式公证级「Developer ID Application」证书时使用证书签名；
# 绝不使用机器绑定的「Apple Development」调试证书签名对外发行包（否则其他 Mac 会因缺少设备描述文件触发 Gatekeeper「已损坏/无法验证」拦截）。
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

build_edition() {
  local edition_key="$1"       # dev | flow
  local edition_label="$2"     # Dev | Flow
  local swift_flag="$3"        # -DICLIP_EDITION_DEV | -DICLIP_EDITION_FLOW
  local scratch_dir="$PROJECT_DIR/.build-${edition_key}"
  local stage_dir="$DIST_DIR/.stage-${edition_key}"
  local staged_app="$stage_dir/${APP_NAME}.app"
  local named_app="$DIST_DIR/${APP_NAME}-${edition_label}.app"
  local zip_out="$DIST_DIR/${APP_NAME}-${edition_label}-macOS.zip"
  local dmg_stage="$DIST_DIR/.dmg-${edition_key}"
  local dmg_out="$DIST_DIR/${APP_NAME}-${edition_label}-macOS.dmg"

  echo "=========================================="
  echo "正在编译 [${edition_label}] 角色版本 (v${VERSION}, flag=${swift_flag})..."
  cd "$PROJECT_DIR"
  swift build -c release --scratch-path "$scratch_dir" -Xswiftc "$swift_flag" -Xswiftc -Osize -Xlinker -dead_strip

  local bin_path="$scratch_dir/release/QingJian"
  rm -rf "$stage_dir" "$named_app" "$zip_out" "$dmg_stage" "$dmg_out"
  mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
  cp "$bin_path" "$staged_app/Contents/MacOS/QingJian"
  chmod +x "$staged_app/Contents/MacOS/QingJian"
  strip -x "$staged_app/Contents/MacOS/QingJian" 2>/dev/null || true

  # 写入品牌液态玻璃图标与高清菜单栏模板图标
  cp "$BRAND_DIR/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
  cp "$BRAND_DIR/MenuBarIcon.png" "$staged_app/Contents/Resources/MenuBarIcon.png"
  cp "$BRAND_DIR/MenuBarIcon@2x.png" "$staged_app/Contents/Resources/MenuBarIcon@2x.png"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
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

  xattr -cr "$staged_app" 2>/dev/null || true
  if [ -n "$SIGN_IDENTITY" ]; then
    echo "使用分发证书签名 [${edition_label}]：$SIGN_IDENTITY"
    codesign --force --deep --options runtime --identifier com.qingjian.clipboard --sign "$SIGN_IDENTITY" "$staged_app"
  else
    echo "使用跨机通用免证书 Ad-hoc 签名 [${edition_label}]..."
    codesign --force --deep --identifier com.qingjian.clipboard --sign - "$staged_app"
  fi

  # 严格校验签名完整性
  codesign --verify --deep --strict "$staged_app"

  # 1. 打包 OTA 专属压缩包（压缩包内根应用固定为 iClip.app，确保原地热替换路径一致）
  ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$zip_out"
  ditto "$staged_app" "$named_app"

  # 2. 制作可视化拖拽安装镜像 (.dmg)
  mkdir -p "$dmg_stage/.background"
  ditto "$staged_app" "$dmg_stage/${APP_NAME}.app"
  ln -s /Applications "$dmg_stage/Applications"
  if [ -f "$BRAND_DIR/dmg-background.jpg" ]; then
    cp "$BRAND_DIR/dmg-background.jpg" "$dmg_stage/.background/background.jpg"
  fi
  cp "$BRAND_DIR/AppIcon.icns" "$dmg_stage/.VolumeIcon.icns"
  if [ -x /usr/bin/SetFile ]; then
    /usr/bin/SetFile -a C "$dmg_stage" 2>/dev/null || true
  fi
  hdiutil create -volname "${APP_NAME}" -srcfolder "$dmg_stage" -ov -format UDZO "$dmg_out" >/dev/null

  rm -rf "$stage_dir" "$dmg_stage"
}

build_edition "dev"  "Dev"  "-DICLIP_EDITION_DEV"
build_edition "flow" "Flow" "-DICLIP_EDITION_FLOW"

# 同步生成默认通用入口包
ditto "$DIST_DIR/iClip-Dev.app" "$DIST_DIR/iClip.app"
cp "$DIST_DIR/iClip-Dev-macOS.zip" "$DIST_DIR/iClip-macOS.zip"
cp "$DIST_DIR/iClip-Dev-macOS.dmg" "$DIST_DIR/iClip-macOS.dmg"

echo "=========================================="
echo "双角色专属构建、可视化 DMG 与签名自检完成 (v${VERSION})："
ls -lh "$DIST_DIR"/*.zip "$DIST_DIR"/*.dmg
shasum -a 256 "$DIST_DIR"/iClip-Dev-macOS.zip "$DIST_DIR"/iClip-Flow-macOS.zip "$DIST_DIR"/iClip-Dev-macOS.dmg "$DIST_DIR"/iClip-Flow-macOS.dmg
