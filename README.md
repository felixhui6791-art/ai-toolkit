# 本地 AI 工具集（ai-toolkit）

一套**全部跑在本机**的 Mac 快捷键小工具合集。按一个快捷键 → 抓取输入（说话 / 选中的文字 / 截图）→ 交给**本地模型**处理 → 结果直接出现在光标处。无需联网、免费、隐私不外泄。

> 运行平台：**macOS · Apple 芯片（M1/M2/M3/M4/M5）**

---

## 功能一览

| 工具 | 快捷键（默认） | 说明 |
|---|---|---|
| 🎙 **语音听写** | 按一下 `右⌘` 开始说，再按一下结束 | 本地语音转文字（SenseVoice），自动把字打到光标处 |
| 🌐 **划词翻译** | 选中文字按 `⌥T` | 中英互译，结果替换原文（本地大模型） |
| ✨ **划词润色** | 选中文字按 `⌥P` | 改得更通顺自然 |
| 📝 **划词总结** | 选中文字按 `⌥S` | 提炼要点 |
| 📸 **截图标注** | `⌥A` | 智能检测窗口/界面元素（鼠标移到哪高亮哪、单击截取，`空格`切窗口/元素），或拖拽框选 → 画框/箭头/笔/荧光/打码/文字 → 钉图 / 提字(OCR) / 翻译 / 保存 / 复制 |
| 📜 **长截图** | `⌥L` | 框选正文那栏 → 自动向下滚动连拍 → 拼成一张长图 → 标注 |
| 🎬 **录屏** | `⌥R` | 框选区域或整屏录成视频；再按一次 / 点菜单栏 🔴 / `Esc` 停止 |
| 📦 **截图·录屏 收集** | `⌥G` | 右侧抽屉，集中查看所有截图和录屏，可复制 / 播放 / 删除 |
| ⚙️ **控制面板** | 菜单栏 🤖 | 开关功能、改快捷键、选并下载大模型 |

> 所有快捷键都能在控制面板里改。

---

## 它怎么工作

```
按快捷键  →   抓输入            →   本地引擎/模型              →   结果直接给你
 (引擎)      麦克风/选中文字/截图      SenseVoice / Qwen3 / 截图程序     粘到光标 / 弹出标注
```

- **快捷键引擎**：[Hammerspoon](https://www.hammerspoon.org/)（免费）。负责监听快捷键、检测窗口/元素、把结果粘到光标。
- **截图/标注/长截图/录屏**：自带的原生程序（`screenshot/AIShot.app` + `screenshot/stitch`，Swift 编译）+ 系统 `screencapture`。
- **文本大脑**：本地 [Ollama](https://ollama.com) + Qwen3 系列模型（大小可在控制面板按内存自选下载）。
- **语音转文字**：SenseVoice Small（中文强、小而快）+ sherpa-onnx，全本地。
- 全部本地运行，除了**第一次下大模型**和**更新时拉一下新代码**外，不需要联网。

---

## 安装

### 给朋友 / 普通用户（一键安装包，推荐）

不用懂任何命令。让作者用 `setup/make_share_package.sh` 生成安装包（含 Hammerspoon、Ollama、截图程序、语音模型、ffmpeg 等），AirDrop 或压缩包发给你：

1. 双击「① 双击我安装.command」，按提示装好。
2. 系统设置 → 隐私与安全性，给 Hammerspoon 开 **辅助功能 / 麦克风 / 屏幕录制** 三项权限。
3. 点菜单栏 🤖 → 打开控制面板 → 在「文本大脑」选一个大模型点下载（只有翻译/润色/总结要用它；听写、截图、录屏不需要）。

详见安装包里的「使用说明.txt」。

### 开发 / 从源码安装

```bash
git clone https://github.com/felixhui6791-art/ai-toolkit.git ~/Hui/ai-toolkit
cd ~/Hui/ai-toolkit

# 1) 装本地依赖（ffmpeg / 语音引擎 / 语音模型；国内可带代理）
PROXY=http://127.0.0.1:7890 bash setup/install_deps.sh

# 2) 编译截图程序
bash screenshot/build.sh

# 3) 让 Hammerspoon 加载本工具集
echo 'dofile(os.getenv("HOME") .. "/Hui/ai-toolkit/hammerspoon/init.lua")' >> ~/.hammerspoon/init.lua
```

再手动装 [Hammerspoon](https://www.hammerspoon.org/) 和 [Ollama](https://ollama.com)，给 Hammerspoon 授权（辅助功能 / 麦克风 / 屏幕录制），在控制面板里下一个 Qwen3 模型即可。

---

## 自动更新

作者发布新版后，使用者菜单栏 🤖 会变成 **🤖🔴**，点开有「🆕 有新版本 → 点此更新」，一键更新到最新，**自己改的快捷键、选的模型、设置都保留不变**，本地的大模型 / 语音模型不受影响。也可随时点「检查更新」。

> 作者发布：双击 `setup/发布到GitHub.command`（编译截图程序 → 刷新版本号 → 提交 → 推送）。更新源在 `config.json` 的 `update_repo`。

---

## 目录结构

| 路径 | 作用 |
|---|---|
| `hammerspoon/init.lua` | 主入口：绑定所有快捷键、窗口/元素检测、自动更新检查 |
| `screenshot/` | 截图标注程序（`main.swift`→`AIShot.app`）、长截图拼接器（`stitch.swift`→`stitch`）、构建脚本 |
| `core/transcribe.py` | 语音转文字（SenseVoice / sherpa-onnx） |
| `core/llm.py` | 调本地大模型 Ollama（翻译/润色/总结） |
| `core/selfupdate.sh` · `merge_config.py` | 自动更新：拉取覆盖、合并配置（保留用户设置） |
| `ui/server.py` · `dashboard.html` · `tray.html` | 控制面板 + 截图收集架（本地网页，端口 7799） |
| `config.json` | 配置：模型、快捷键、文本预设、更新源 |
| `setup/` | 依赖安装、生成分享安装包、发布到 GitHub 等脚本 |
| `bin/` `models/` `.venv/` | ffmpeg / 语音模型 / Python 环境（体积大，不进 git，由安装脚本就地准备） |

---

## 许可证

[MIT](LICENSE)
