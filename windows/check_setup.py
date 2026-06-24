# -*- coding: utf-8 -*-
"""Windows 环境检查：确认 Python + Ollama + 大模型 这条基础链路是否通。"""
import sys, platform, json, urllib.request

def http_get(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()

def http_post(url, obj, timeout=120):
    data = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

print("=" * 48)
print(" 本地 AI 工具集 · Windows 环境检查")
print("=" * 48)
print("Python :", sys.version.split()[0])
print("系统   :", platform.platform())

BASE = "http://localhost:11434"
try:
    tags = json.loads(http_get(BASE + "/api/tags"))
    models = [m["name"] for m in tags.get("models", [])]
    print("Ollama : 运行中 OK")
    print("已装模型:", ", ".join(models) if models else "(还没下模型)")
except Exception as e:
    print("Ollama : 连不上 X")
    print("  -> 请先安装 Ollama for Windows (ollama.com/download)，打开它，")
    print("     再在命令行运行:  ollama pull qwen3:8b")
    print("  错误:", e)
    input("\n按回车键关闭…")
    raise SystemExit

if models:
    m = models[0]
    print(f"\n正在用 {m} 测试翻译: 'Hello world, this is a local AI test.'")
    try:
        import re
        r = http_post(BASE + "/api/chat", {
            "model": m, "stream": False, "think": False,
            "options": {"temperature": 0.3},
            "messages": [
                {"role": "system", "content": "你是翻译引擎，只输出简体中文译文。"},
                {"role": "user", "content": "Hello world, this is a local AI test."}]})
        txt = re.sub(r"<think>.*?</think>", "", r["message"]["content"], flags=re.DOTALL).strip()
        print("翻译结果:", txt)
        print("\n[成功] 基础链路通了！Python + Ollama + 大模型 都正常。")
    except Exception as e:
        print("翻译测试失败:", e)
else:
    print("\n还没下模型。请运行:  ollama pull qwen3:8b   然后再跑一次本检查。")

input("\n按回车键关闭…")
