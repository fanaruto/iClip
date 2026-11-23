#!/bin/zsh
# 一键切换 iClip 预设品牌图标方案（a | b | c | d）并同步生成双端图标资产
# 用法：./scripts/use_logo.sh b
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHOICE="${1:-a}"
swift "$PROJECT_DIR/scripts/render_brand_suite.swift" --active "$CHOICE"
echo "✔ 已切换激活方案 [${CHOICE}]，运行 ./build_app.sh 即可重新打包生效。"
