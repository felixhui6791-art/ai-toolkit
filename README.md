# 本地 AI 工具集（ai-toolkit）

一套**全部跑在本机**的快捷键小工具合集。按一个快捷键 → 抓取输入（说话 / 选中的文字 / 截图）→ 交给本地模型处理 → 结果直接出现在光标处。无需联网、免费、隐私不外泄。

> 运行平台：macOS（Apple Silicon，本机为 M5 Pro / 48GB）

---

## 它怎么工作（说人话）

```
按快捷键  →   抓输入        →   本地模型          →   结果吐到光标处
 (引擎)      麦克风/选中文字/截图   Whisper / Qwen3        自动粘贴
```

- **快捷键引擎**：用 [Hammerspoon](https://www.hammerspoon.org/)（免费）。它只负责"监听快捷键 + 把结果粘到光标"。
- **所有工具逻辑**：就在本项目文件夹里。加新工具 = 在这里加文件 / 改 `init.lua`，**不用重装、不用反复授权**。

## 目录结构

| 路径 | 作用 |
|---|---|
| `hammerspoon/init.lua` | 主入口：绑定所有快捷键（Hammerspoon 会加载它）|
| `core/transcribe.py` | 语音转文字（调本地 Whisper）|
| `core/llm.py` | 调本地大模型 Ollama（翻译/润色/总结等文本工具用）|
| `tools/` | 各个小工具的脚本 |
| `bin/` | 存放 ffmpeg 等小工具二进制 |
| `recordings/` | 临时录音（自动清理，不进 git）|
| `setup/install_deps.sh` | 一键安装依赖（开代理后运行一次）|
| `config.json` | 配置：模型、语言、快捷键、文本预设 |

## 用到的本地组件

| 组件 | 用途 | 安装方式 |
|---|---|---|
| Ollama + Qwen3 | 文本大脑 | 已装 Ollama；模型待下载 |
| SenseVoice Small + sherpa-onnx | 语音转文字（中文强·小而快）| `setup/install_deps.sh` |
| ffmpeg | 录音 | `setup/install_deps.sh` |
| Hammerspoon | 快捷键引擎 | 手动装一次 + 授权 |

## 安装进度

- [x] 创建项目骨架
- [x] 安装 Ollama（服务运行在 `localhost:11434`）
- [ ] 下载 Qwen3 模型（需代理）
- [ ] 安装 ffmpeg + sherpa-onnx + SenseVoice 模型（需代理，运行 `setup/install_deps.sh`）
- [ ] 安装 Hammerspoon 并授权（麦克风 + 辅助功能）
- [ ] 第一个工具：语音听写 ✅ 跑通

## 工具清单

| 工具 | 快捷键（默认） | 状态 |
|---|---|---|
| 🎙 语音听写 | 按住 `F5` 说话，松开出字 | 开发中 |
| 🌐 划词翻译 | 选中文字按 `⌥T` | 计划中 |
| ✨ 划词润色 | 选中文字按 `⌥P` | 计划中 |
| 📝 划词总结 | 选中文字按 `⌥S` | 计划中 |

> 快捷键都可在 `config.json` / `init.lua` 里改。
