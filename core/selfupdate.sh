#!/bin/bash
# 自更新：从 GitHub 拉最新代码覆盖安装，保留用户配置/模型/语音引擎。
#   selfupdate.sh <user/repo>
# 只覆盖代码与编译好的截图程序；本地独有的大文件(ffmpeg/models/.venv/wheels 不在 zip 里) 不受影响。
set -e
REPO="$1"
PROJ="$HOME/Hui/ai-toolkit"
[ -z "$REPO" ] && { echo "用法: selfupdate.sh <user/repo>"; exit 2; }
[ -d "$PROJ" ] || { echo "找不到安装目录 $PROJ"; exit 3; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "下载最新版…"
# 优先 main 分支，失败再试 master
if ! curl -fL --connect-timeout 20 --max-time 300 -o "$TMP/src.zip" "https://github.com/$REPO/archive/refs/heads/main.zip"; then
  curl -fL --connect-timeout 20 --max-time 300 -o "$TMP/src.zip" "https://github.com/$REPO/archive/refs/heads/master.zip"
fi
# 用 ditto 解压：macOS 原生，能正确处理仓库里的中文文件名；
# 老的 unzip 遇到 GitHub 压缩包的 UTF-8 文件名会乱码+交互卡住，导致解压不全、更新失败。
ditto -x -k "$TMP/src.zip" "$TMP/x" 2>/dev/null
SRC="$(ls -d "$TMP"/x/*/ 2>/dev/null | head -1)"
[ -d "$SRC" ] || { echo "解压失败"; exit 4; }
[ -f "$SRC/hammerspoon/init.lua" ] || { echo "下载内容不像本工具集，已中止"; exit 5; }

echo "合并配置（保留你的快捷键/模型/设置）…"
if [ -f "$PROJ/config.json" ] && [ -f "$SRC/config.json" ]; then
  python3 "$SRC/core/merge_config.py" "$PROJ/config.json" "$SRC/config.json" 2>/dev/null || \
    cp "$PROJ/config.json" "$SRC/config.json"   # 万一合并脚本出错，至少别覆盖用户配置
fi

echo "覆盖更新…"
# -c 按内容比对(避免同长度文件如 VERSION 因时间戳被跳过)；不加 --delete：zip 里没有的本地文件(ffmpeg/models/.venv/wheels)原样保留
rsync -ac --exclude '.git' --exclude '.venv' --exclude 'wheels' --exclude 'models' \
  --exclude 'bin/ffmpeg' --exclude 'recordings' --exclude 'logs' "$SRC" "$PROJ/"

chmod +x "$PROJ/bin/ffmpeg" "$PROJ/screenshot/AIShot.app/Contents/MacOS/aishot" "$PROJ/screenshot/stitch" 2>/dev/null || true
xattr -dr com.apple.quarantine "$PROJ/screenshot/AIShot.app" "$PROJ/screenshot/stitch" 2>/dev/null || true
echo "OK"
