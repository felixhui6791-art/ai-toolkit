#!/bin/bash
# 在"我"的机器上运行，生成给朋友的一键安装包（含所有软件，唯独 Qwen3 大模型安装时再下）
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"        # 当前 ai-toolkit 项目
OUT="$HOME/Downloads/本地AI工具集-安装包"
APPS_HS="/Applications/Hammerspoon.app"
APPS_OL="/Applications/Ollama.app"

echo "=== 清理并新建打包目录 ==="
rm -rf "$OUT"; mkdir -p "$OUT/apps"

echo "=== 1) 拷贝需要安装的 App（Hammerspoon + Ollama）==="
ditto "$APPS_HS" "$OUT/apps/Hammerspoon.app"
ditto "$APPS_OL" "$OUT/apps/Ollama.app"

echo "=== 2) 拷贝项目本体（含 ffmpeg / 截图程序 / SenseVoice 语音模型）==="
rsync -a \
  --exclude '.venv' --exclude '.git' --exclude 'recordings/*' --exclude 'logs/*' \
  --exclude '*.wav' --exclude '__pycache__' --exclude '*.mov' \
  "$SRC/" "$OUT/ai-toolkit/"

echo "=== 3) 预下载 Python 依赖 wheel（让朋友离线安装）==="
mkdir -p "$OUT/ai-toolkit/wheels"
"$SRC/.venv/bin/pip" download -q sherpa-onnx numpy -d "$OUT/ai-toolkit/wheels" || \
  echo "  (wheel 预下载失败，朋友安装时会联网装，不影响)"

echo "=== 4) 生成朋友用的安装器 install.command ==="
cat > "$OUT/① 双击我安装.command" <<'INSTALL'
#!/bin/bash
cd "$(dirname "$0")"
echo "==============================================="
echo "   本地 AI 工具集 · 安装中（请勿关闭此窗口）"
echo "==============================================="

# 检查 python3
if ! command -v python3 >/dev/null 2>&1; then
  echo "需要先安装命令行工具，系统会弹窗，请点【安装】，装完后再次双击本文件。"
  xcode-select --install
  exit 0
fi

echo "[1/5] 安装 Hammerspoon 和 Ollama 到 应用程序…"
osascript -e 'quit app "Hammerspoon"' 2>/dev/null; killall Ollama 2>/dev/null; sleep 1   # 重跑安装时先退旧的，免"资源占用"
for app in apps/*.app; do
  name="$(basename "$app")"
  xattr -dr com.apple.quarantine "$app" 2>/dev/null
  rm -rf "/Applications/$name"
  ditto "$app" "/Applications/$name"
done

echo "[2/5] 安装工具到 个人目录/Hui/ai-toolkit …"
mkdir -p "$HOME/Hui"
rm -rf "$HOME/Hui/ai-toolkit"
ditto ai-toolkit "$HOME/Hui/ai-toolkit"
PROJ="$HOME/Hui/ai-toolkit"
xattr -dr com.apple.quarantine "$PROJ" 2>/dev/null
chmod +x "$PROJ/bin/ffmpeg" "$PROJ/screenshot/AIShot.app/Contents/MacOS/aishot" "$PROJ/screenshot/stitch" 2>/dev/null

echo "[3/5] 配置语音引擎（Python）…"
python3 -m venv "$PROJ/.venv"
"$PROJ/.venv/bin/pip" install -q -U pip 2>/dev/null
if ! "$PROJ/.venv/bin/pip" install -q --no-index --find-links "$PROJ/wheels" sherpa-onnx numpy 2>/dev/null; then
  echo "    离线包不匹配，改为联网安装…"
  "$PROJ/.venv/bin/pip" install -q sherpa-onnx numpy -i https://pypi.tuna.tsinghua.edu.cn/simple
fi

echo "[4/5] 让 Hammerspoon 加载工具集 + 设为开机启动…"
mkdir -p "$HOME/.hammerspoon"
LINE='dofile(os.getenv("HOME") .. "/Hui/ai-toolkit/hammerspoon/init.lua")'
grep -q ai-toolkit "$HOME/.hammerspoon/init.lua" 2>/dev/null || echo "$LINE" >> "$HOME/.hammerspoon/init.lua"

echo "[5/5] 启动 Ollama（大模型不打进安装包，装完到控制面板自己挑一个下载）…"
OLLAMA="/Applications/Ollama.app/Contents/Resources/ollama"
nohup "$OLLAMA" serve >/tmp/ollama.log 2>&1 &
# 按内存把"推荐型号"写进配置当默认选项（仅默认，不下载；到控制面板点"下载"才会下）
RAM=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
if   [ "$RAM" -lt 12 ]; then MODEL="qwen3:4b"
elif [ "$RAM" -lt 20 ]; then MODEL="qwen3:8b"
else MODEL="qwen3:14b"; fi
python3 - "$PROJ/config.json" "$MODEL" <<'PY'
import json, sys
p, m = sys.argv[1], sys.argv[2]
c = json.load(open(p, encoding="utf-8")); c["models"]["text"] = m
json.dump(c, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
echo "    已把推荐型号设为 $MODEL（按内存 ${RAM}GB）——还没下载，见下方说明。"

open -a Hammerspoon
echo
echo "==============================================="
echo "  安装完成！还差两步："
echo
echo "  ① 授予权限：系统设置 → 隐私与安全性，把 Hammerspoon 在这三项打开："
echo "       · 辅助功能   · 麦克风   · 屏幕录制与系统录音"
echo
echo "  ② 选并下载一个大模型（翻译/润色/总结要用；听写、截图、录屏不需要它）："
echo "       点屏幕右上角 🤖 → 打开控制面板 → 在『文本大脑』选一个型号 → 点【下载】"
echo "       内存小就选小的(4B/8B)，大就选大的(14B)；下完自动可用。"
echo
echo "  详见『使用说明.txt』。"
echo "==============================================="
INSTALL
chmod +x "$OUT/① 双击我安装.command"

echo "=== 5) 生成使用说明 ==="
cat > "$OUT/使用说明.txt" <<'GUIDE'
本地 AI 工具集 · 使用说明
========================================

【安装】（安装包里不含大模型，所以装得很快；模型你自己挑一个下）
1. 双击「① 双击我安装.command」。
   - 如果提示"无法打开/未受信任"，右键点它 →「打开」→ 再「打开」。
   - 装完窗口会提示"安装完成"。

2. 授予权限：系统设置 → 隐私与安全性，把 Hammerspoon 在这三项里打开：
   · 辅助功能      （监听快捷键、把字粘到光标、检测窗口/界面元素都靠它）
   · 麦克风        （语音听写用）
   · 屏幕录制与系统录音（截图 / 长截图 / 录屏用）
   开完最好重启一次 Hammerspoon（启动台里打开它）。

3. 选并下载一个「文本大脑」大模型（只有 翻译/润色/总结 要用它；
   语音听写、截图、长截图、录屏 都不需要它，可以先不下）：
   · 点屏幕右上角 🤖 →「打开控制面板」。
   · 在「文本大脑」那一行的下拉框里选一个型号 → 点【下载】，会在你电脑上下载：
       Qwen3 1.7B  ~1.4GB（8GB 内存可跑）
       Qwen3 4B    ~2.5GB（建议 8–16GB）
       Qwen3 8B    ~5GB  （建议 16GB）
       Qwen3 14B   ~9GB  （建议 24GB 以上）
       Qwen3 30B   ~18GB （建议 48GB 以上）
     内存小就选小的。下载要联网，较大的要几分钟到几十分钟，下完自动设为当前模型。

【怎么用】（屏幕右上角有 🤖 图标就代表在运行；点它能打开控制面板改快捷键/换模型）
  🎙 语音听写 ：按一下"右⌘"开始说话，再按一下"右⌘"结束，自动出字
  📸 截图标注 ：按 ⌥A，鼠标移到窗口/按钮上自动高亮(空格切窗口/元素)→单击截取
                 或拖拽框选 → 标注/钉图/提字(OCR)/翻译/保存/复制
  📜 长截图   ：按 ⌥L，框选正文那栏 → 自动向下滚动连拍拼成一张长图 → 标注
  🎬 录屏     ：按 ⌥R，框选区域或整屏录成视频；再按一次/点菜单栏🔴/Esc 停止
                 (纯画面无声音，存到「影片/录屏收集」)
  🌐 划词翻译 ：选中文字按 ⌥T
  ✨ 划词润色 ：选中文字按 ⌥P
  📝 划词总结 ：选中文字按 ⌥S
  📦 收集架   ：按 ⌥G，右侧抽屉看所有截图和录屏，可复制/播放/删除

【自动更新】（作者改进了功能后，你这边会收到提醒）
  · 作者发布新版后，你屏幕右上角 🤖 图标会变成 🤖🔴，
    点开菜单会有「🆕 有新版本 → 点此更新」，点一下就自动更新到最新，
    你自己改的快捷键、选的模型、设置都会保留不变。
  · 也可以随时点 🤖 →「检查更新」手动看有没有新版。

【要求】
  · 必须是 Apple 芯片的 Mac（M1/M2/M3/M4/M5）。
  · 全部本地运行，不联网（除了第一次下模型、和更新时拉一下新代码）。

【出问题】
  · 快捷键没反应 / 检测不灵 → 启动台里打开一次 Hammerspoon；
    或 系统设置→隐私与安全性→辅助功能，把 Hammerspoon 重新打勾。
  · 截图程序打不开 → 在"访达"里进入 个人目录/Hui/ai-toolkit/screenshot，
    右键 AIShot.app →「打开」一次。
GUIDE

echo
echo "=== 打包完成 ==="
echo "位置: $OUT"
du -sh "$OUT" 2>/dev/null
echo "把这个文件夹整体发给朋友（AirDrop 或压缩成 zip 传网盘）即可。"
