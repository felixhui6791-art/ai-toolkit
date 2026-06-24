#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
调用本地 Ollama 大模型。只依赖 Python 标准库（无需 pip 安装）。

用法：
  echo "要处理的文字" | python3 core/llm.py --preset translate
  echo "要处理的文字" | python3 core/llm.py --system "你是..."
读取 stdin 作为待处理文本，把模型结果打印到 stdout。
"""
import sys, os, json, argparse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "..", "config.json")


def load_config():
    with open(CONFIG, "r", encoding="utf-8") as f:
        return json.load(f)


def ask(prompt, model, system=None, base_url="http://localhost:11434"):
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    payload = json.dumps({
        "model": model,
        "messages": messages,
        "stream": False,
        # 关闭思考输出，工具场景只要最终结果
        "think": False,
        "options": {"temperature": 0.3},
    }).encode("utf-8")
    req = urllib.request.Request(
        base_url.rstrip("/") + "/api/chat",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    import re
    content = data.get("message", {}).get("content", "")
    # 万一思考标记漏到正文，清掉
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL)
    return content.strip()


def main():
    cfg = load_config()
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset", help="config.json 里 presets 的名字，如 translate")
    ap.add_argument("--system", help="自定义系统提示词（覆盖 preset）")
    ap.add_argument("--model", default=cfg["models"]["text"])
    ap.add_argument("--infile", help="从文件读取待处理文本（优先于 stdin）")
    args = ap.parse_args()

    system = args.system
    if not system and args.preset:
        system = cfg.get("presets", {}).get(args.preset)

    if args.infile:
        with open(args.infile, "r", encoding="utf-8") as f:
            text = f.read().strip()
    else:
        text = sys.stdin.read().strip()
    if not text:
        sys.exit(0)

    try:
        out = ask(text, args.model, system, cfg["models"]["base_url"])
        sys.stdout.write(out)
    except Exception as e:
        sys.stderr.write("LLM 调用失败: %s\n" % e)
        sys.exit(1)


if __name__ == "__main__":
    main()
