#!/bin/bash
# 编译截图工具到标准 .app 应用包
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/AIShot.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/aishot" "$HERE/main.swift" \
  -framework Cocoa -framework Vision
# 本地 ad-hoc 签名（避免权限/Gatekeeper 问题）
codesign --force --deep -s - "$APP" 2>/dev/null || true
echo "✅ 已构建: $APP"
