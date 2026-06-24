#!/bin/bash
# 一键安装依赖。开好代理后运行一次即可：
#   PROXY=http://127.0.0.1:7890 bash setup/install_deps.sh
# 不传 PROXY 也能跑，只是下载可能很慢。
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
OLLAMA="/Applications/Ollama.app/Contents/Resources/ollama"
PIP_MIRROR="${PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"

if [ -n "$PROXY" ]; then
  export http_proxy="$PROXY" https_proxy="$PROXY" all_proxy="$PROXY"
  echo "✅ 走代理: $PROXY"
fi

echo "=== 1/3 安装 ffmpeg（录音用）==="
if [ -x "$PROJ/bin/ffmpeg" ]; then
  echo "  已存在，跳过"
else
  # arm64 原生 ffmpeg（Apple 芯片直接跑，无需 Rosetta）。evermeet.cx 那个是 x86_64，会要 Rosetta，已弃用。
  curl -L --progress-bar -o "$PROJ/bin/ffmpeg" "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0/ffmpeg-darwin-arm64"
  chmod +x "$PROJ/bin/ffmpeg"
  xattr -dr com.apple.quarantine "$PROJ/bin/ffmpeg" 2>/dev/null || true
  "$PROJ/bin/ffmpeg" -version | head -1 && echo "  ✅ ffmpeg 就绪(arm64)"
fi

echo "=== 2/3 安装语音转文字（SenseVoice + sherpa-onnx）==="
if [ ! -d "$PROJ/.venv" ]; then
  python3 -m venv "$PROJ/.venv"
fi
"$PROJ/.venv/bin/pip" install -q -U pip -i "$PIP_MIRROR"
"$PROJ/.venv/bin/pip" install -q -U sherpa-onnx numpy -i "$PIP_MIRROR"
MODEL_DIR="$PROJ/models/sensevoice"
if [ -f "$MODEL_DIR/model.int8.onnx" ]; then
  echo "  语音模型已存在，跳过"
else
  echo "  下载 SenseVoice 模型…"
  SV_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
  curl -L --progress-bar -o /tmp/sensevoice.tar.bz2 "$SV_URL"
  rm -rf /tmp/sv_extract && mkdir -p /tmp/sv_extract "$MODEL_DIR"
  tar xjf /tmp/sensevoice.tar.bz2 -C /tmp/sv_extract
  cp /tmp/sv_extract/sherpa-onnx-sense-voice-*/model.int8.onnx "$MODEL_DIR/"
  cp /tmp/sv_extract/sherpa-onnx-sense-voice-*/tokens.txt "$MODEL_DIR/"
fi
echo "  ✅ SenseVoice 就绪"

echo "=== 3/3 下载 Qwen3 模型（按内存自动选大小）==="
RAM=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
if   [ "$RAM" -lt 12 ]; then MODEL="qwen3:4b"
elif [ "$RAM" -lt 20 ]; then MODEL="qwen3:8b"
else MODEL="qwen3:14b"; fi
echo "  内存 ${RAM}GB → 选择 $MODEL"
"$OLLAMA" pull "$MODEL"
python3 - "$PROJ/config.json" "$MODEL" <<'PY'
import json, sys
p, m = sys.argv[1], sys.argv[2]
c = json.load(open(p, encoding="utf-8")); c["models"]["text"] = m
json.dump(c, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
echo "  ✅ 模型就绪：$MODEL"

echo
echo "全部依赖安装完成 🎉  接下来装 Hammerspoon 并授权即可。"
