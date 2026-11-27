#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.iclip.clipboard"
TARGET_APP="/Applications/iClip.app"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESET_ALL=0

for arg in "$@"; do
  case "$arg" in
    --reset)
      RESET_ALL=1
      ;;
  esac
done

echo "=========================================="
echo "iClip 系统权限检查与同名旧版本冲突一键修复工具"
echo "=========================================="

# 1. 优雅退出运行中的 iClip，防止旧进程继续占用旧签名上下文
osascript -e 'tell application "iClip" to quit' 2>/dev/null || true
pkill -x iClip 2>/dev/null || true
pkill -x QingJian 2>/dev/null || true
sleep 0.6

# 2. 清理工作区 dist/iClip.app 等同名未安装副本（保留 .dmg/.zip），避免 macOS TCC / LaunchServices 串位
if [ -d "$PROJECT_DIR/dist/iClip.app" ]; then
  echo "清理构建目录中的同名副本：$PROJECT_DIR/dist/iClip.app"
  rm -rf "$PROJECT_DIR/dist/iClip.app"
fi

if [ ! -d "$TARGET_APP" ]; then
  echo "错误：未找到 ${TARGET_APP}，请先执行 ./build_app.sh --install 构建并安装。" >&2
  exit 1
fi

echo "当前安装签名信息："
codesign -dv "$TARGET_APP" 2>&1 | grep -E "Identifier=|Authority=|Signature=|TeamIdentifier=" || true

DUPLICATES="$(mdfind 'kMDItemFSName == "iClip.app"' 2>/dev/null | grep -v "^${TARGET_APP}$" || true)"
if [ -n "$DUPLICATES" ]; then
  echo "⚠️ 发现其他位置的同名 iClip.app（建议删除以免系统权限列表勾错）："
  echo "$DUPLICATES"
fi

# 3. 清理 TCC 旧残留（默认在 --reset 时清理全部；否则清理 Accessibility 与 ScreenCapture）
echo ""
echo "正在清理旧版签名/同名冲突导致的 TCC 授权残留 (${BUNDLE_ID})..."
tccutil reset Accessibility "$BUNDLE_ID" || true
tccutil reset ScreenCapture "$BUNDLE_ID" || true
tccutil reset Accessibility com.qingjian.clipboard 2>/dev/null || true
tccutil reset ScreenCapture com.qingjian.clipboard 2>/dev/null || true
if [ "$RESET_ALL" = "1" ]; then
  tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" || echo "提示：若完全磁盘访问重置失败，请在系统设置中点击 '-' 移除旧条目后重新拖入 ${TARGET_APP}。"
  tccutil reset SystemPolicyAllFiles com.qingjian.clipboard 2>/dev/null || true
else
  tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" 2>/dev/null || true
  tccutil reset SystemPolicyAllFiles com.qingjian.clipboard 2>/dev/null || true
fi

# 4. 强制刷新 LaunchServices，绑定到唯一的 /Applications/iClip.app
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
  "$LSREG" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi

echo ""
echo "说明：受 macOS SIP 安全机制限制，终端脚本无法跳过系统面板静默授权隐私开关。"
echo "接下来将为您打开 3 个权限面板并启动 ${TARGET_APP}："
echo "  1) 隐私与安全性 → 辅助功能：勾选或重新开启 iClip"
echo "  2) 隐私与安全性 → 完全磁盘访问权限：点击 '+' 或拖入 /Applications/iClip.app"
echo "  3) 隐私与安全性 → 屏幕录制与系统录音：勾选 iClip"
echo ""

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
sleep 0.3
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" || true
sleep 0.3
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true

open -n "$TARGET_APP"
echo "✓ 已完成清理、唯一路径注册与启动！"
