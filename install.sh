#!/bin/sh
# iClip for macOS — 免安全弹窗一键丝滑安装脚本（One iClip 唯一主线）
# 用法：curl -fsSL https://app.webfooo.com/iClip/install.sh | zsh

set -eu

if [ "$(uname -s)" != "Darwin" ]; then
  printf "\033[31m✖ 当前脚本仅适用于 macOS。Windows 用户请在 PowerShell 运行：\033[0m\n"
  printf "  irm https://app.webfooo.com/iClip/install.ps1 | iex\n"
  exit 1
fi

ZIP_NAME="iClip-macOS.zip"
PRIMARY_URL="https://app.webfooo.com/iClip/downloads/${ZIP_NAME}"
FALLBACK_URL="https://github.com/fanaruto/iClip/releases/latest/download/${ZIP_NAME}"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iclip-install.XXXXXX")"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT INT TERM

printf "\n\033[1;36m==> 正在安装 iClip for macOS\033[0m\n"
printf "    终端直连免除浏览器隔离标记，全程零安全拦截弹窗...\n"

ZIP_PATH="$STAGE_DIR/$ZIP_NAME"
if curl -fL --connect-timeout 8 --retry 2 --progress-bar "$PRIMARY_URL" -o "$ZIP_PATH" 2>/dev/null; then
  printf "  \033[32m✓\033[0m 已从国内高速源获取安装包\n"
else
  printf "  \033[33m!\033[0m 正在切换至备用源获取安装包...\n"
  curl -fL --connect-timeout 15 --retry 2 --progress-bar "$FALLBACK_URL" -o "$ZIP_PATH"
  printf "  \033[32m✓\033[0m 安装包下载完成\n"
fi

ZIP_SIZE="$(wc -c < "$ZIP_PATH" | tr -d '[:space:]')"
if [ "${ZIP_SIZE:-0}" -lt 65536 ]; then
  printf "\033[31m✖ 安装包下载不完整（%s 字节），请检查网络后重试\033[0m\n" "${ZIP_SIZE:-0}"
  exit 1
fi

ditto -x -k "$ZIP_PATH" "$STAGE_DIR/unpacked"
APP_SRC="$STAGE_DIR/unpacked/iClip.app"
if [ ! -x "$APP_SRC/Contents/MacOS/QingJian" ]; then
  printf "\033[31m✖ 安装包校验异常：未找到可执行文件 iClip.app\033[0m\n"
  exit 1
fi

xattr -cr "$APP_SRC" 2>/dev/null || true
codesign --force --deep --identifier com.qingjian.clipboard --sign - "$APP_SRC" >/dev/null 2>&1 || true

if [ -w "/Applications" ] && [ ! -L "/Applications" ]; then
  DEST_DIR="/Applications"
else
  DEST_DIR="$HOME/Applications"
  if [ -L "$DEST_DIR" ]; then
    printf "\033[31m✖ 拒绝安装：目标目录 %s 为异常符号链接\033[0m\n" "$DEST_DIR"
    exit 1
  fi
  mkdir -p "$DEST_DIR"
fi
TARGET_APP="$DEST_DIR/iClip.app"

if pgrep -x "QingJian" >/dev/null 2>&1; then
  printf "  \033[36m•\033[0m 正在平滑更新运行中的 iClip（历史记录完整保留）...\n"
  killall "QingJian" 2>/dev/null || true
  sleep 0.6
fi

rm -rf "$TARGET_APP"
ditto "$APP_SRC" "$TARGET_APP"
xattr -cr "$TARGET_APP" 2>/dev/null || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi
touch "$TARGET_APP" 2>/dev/null || true

APP_VER="$(defaults read "$TARGET_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "latest")"
open "$TARGET_APP"

printf "\n\033[1;32m✔ iClip v%s 安装完成并已启动！\033[0m\n" "$APP_VER"
printf "  • 安装位置：%s\n" "$TARGET_APP"
printf "  • 呼出面板：按下 \033[1m⌥ + V\033[0m（或点击顶部菜单栏 iClip 图标）\n"
printf "  • 极简模式：面板内按 \033[1m⌘ + E\033[0m 一键切换纯净模式\n\n"
