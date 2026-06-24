#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地控制面板服务器。只用 Python 标准库。
启动后浏览器打开 http://127.0.0.1:7799 即可看到面板。
  python3 ui/server.py
"""
import http.server, socketserver, json, os, urllib.request, urllib.parse, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
CONFIG = os.path.join(PROJ, "config.json")
PORT = 7799
OLLAMA = "/Applications/Ollama.app/Contents/Resources/ollama"
LIB = os.path.expanduser("~/Pictures/截图收集")          # 截图收集库
REC_LIB = os.path.expanduser("~/Movies/录屏收集")        # 录屏收集库
os.makedirs(LIB, exist_ok=True)
os.makedirs(REC_LIB, exist_ok=True)
THUMB_DIR = "/tmp/aishot_thumbs"                          # 录屏封面缩略图缓存
AISHOT = os.path.join(PROJ, "screenshot", "AIShot.app", "Contents", "MacOS", "aishot")
IMG_EXT = (".png", ".jpg", ".jpeg", ".tiff")
VID_EXT = (".mov", ".mp4", ".m4v")
CTYPE = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".tiff": "image/tiff",
         ".mov": "video/quicktime", ".mp4": "video/mp4", ".m4v": "video/x-m4v"}

_dur_cache = {}


def resolve(name):
    """把文件名解析到截图库或录屏库的真实路径（防路径穿越）。"""
    name = os.path.basename(name or "")
    for d in (LIB, REC_LIB):
        p = os.path.join(d, name)
        if name and os.path.exists(p):
            return p
    return None


def video_dur(p):
    """读视频时长(秒)，按 (路径,修改时间) 缓存，避免每次轮询都起 mdls。"""
    key = (p, os.path.getmtime(p))
    if key in _dur_cache:
        return _dur_cache[key]
    sec = 0
    try:
        out = subprocess.run(["mdls", "-raw", "-name", "kMDItemDurationSeconds", p],
                             capture_output=True, text=True, timeout=4).stdout.strip()
        sec = int(float(out)) if out and out != "(null)" else 0
    except Exception:
        sec = 0
    if sec > 0:                  # 刚录好的文件 Spotlight 还没索引出时长会返回0，不缓存0以便稍后重试
        _dur_cache[key] = sec
    return sec


def thumb_path(name):
    """给录屏生成/取用 QuickLook 首帧封面(零依赖)；缓存到 THUMB_DIR。"""
    src = resolve(name)
    if not src:
        return None
    os.makedirs(THUMB_DIR, exist_ok=True)
    out = os.path.join(THUMB_DIR, os.path.basename(name) + ".png")
    if (not os.path.exists(out)) or os.path.getmtime(out) < os.path.getmtime(src):
        try:
            subprocess.run(["qlmanage", "-t", "-s", "600", "-o", THUMB_DIR, src],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        except Exception:
            pass
    return out if os.path.exists(out) else None


def list_shots():
    items = []
    for n in os.listdir(LIB):
        if n.lower().endswith(IMG_EXT):
            p = os.path.join(LIB, n)
            items.append({"name": n, "ts": os.path.getmtime(p), "kind": "image"})
    if os.path.isdir(REC_LIB):
        for n in os.listdir(REC_LIB):
            if n.lower().endswith(VID_EXT):
                p = os.path.join(REC_LIB, n)
                items.append({"name": n, "ts": os.path.getmtime(p), "kind": "video", "dur": video_dur(p)})
    items.sort(key=lambda x: x["ts"], reverse=True)   # 新的在前
    return items


def machine_info():
    try:
        ram = round(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / (1024 ** 3))
    except Exception:
        ram = 0
    if ram and ram < 12:
        rec = "qwen3:4b"
    elif ram and ram < 20:
        rec = "qwen3:8b"
    else:
        rec = "qwen3:14b"   # 24GB+ 默认；更大内存可在面板手动选更大
    return {"ram_gb": ram, "recommended": rec}


def ollama_models(base):
    try:
        with urllib.request.urlopen(base.rstrip("/") + "/api/tags", timeout=2) as r:
            d = json.loads(r.read())
            return True, [m["name"] for m in d.get("models", [])]
    except Exception:
        return False, []


def deps_status():
    return {
        "ollama_app": os.path.exists("/Applications/Ollama.app"),
        "ffmpeg": os.path.exists(os.path.join(PROJ, "bin", "ffmpeg")),
        "whisper": os.path.exists(os.path.join(PROJ, ".venv", "bin", "python")),
        "hammerspoon": os.path.exists("/Applications/Hammerspoon.app"),
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            with open(os.path.join(HERE, "dashboard.html"), "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/tray" or self.path.startswith("/tray"):
            with open(os.path.join(HERE, "tray.html"), "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/api/shots":
            self._send(200, json.dumps(list_shots(), ensure_ascii=False))
        elif self.path.startswith("/shot?"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            name = os.path.basename((q.get("name") or [""])[0])   # 防路径穿越
            p = resolve(name)                                     # 截图库 / 录屏库都找
            if p:
                with open(p, "rb") as f:
                    self._send(200, f.read(), CTYPE.get(os.path.splitext(name)[1].lower(), "application/octet-stream"))
            else:
                self._send(404, "not found", "text/plain")
        elif self.path.startswith("/thumb?"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            name = os.path.basename((q.get("name") or [""])[0])
            tp = thumb_path(name)                                 # 录屏首帧封面
            if tp:
                with open(tp, "rb") as f:
                    self._send(200, f.read(), "image/png")
            else:
                self._send(404, "not found", "text/plain")
        elif self.path == "/api/state":
            with open(CONFIG, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            base = cfg.get("models", {}).get("base_url", "http://localhost:11434")
            ok, models = ollama_models(base)
            self._send(200, json.dumps({
                "config": cfg,
                "ollama": {"running": ok, "models": models},
                "deps": deps_status(),
                "machine": machine_info(),
            }, ensure_ascii=False))
        else:
            self._send(404, '{"error":"not found"}')

    def do_POST(self):
        if self.path == "/api/config":
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
            with open(CONFIG, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            self._send(200, '{"ok":true}')
        elif self.path == "/api/pull":
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
            model = (data.get("model") or "").strip()
            if model:
                # 后台下载，不阻塞；面板轮询已安装列表判断是否完成
                subprocess.Popen([OLLAMA, "pull", model],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self._send(200, '{"ok":true}')
        elif self.path == "/api/shots/copy":
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
            p = resolve(data.get("name") or "")
            if p:
                subprocess.run(["osascript", "-e",
                                'set the clipboard to (read (POSIX file "%s") as «class PNGf»)' % p])
            self._send(200, '{"ok":true}')
        elif self.path == "/api/shots/open":          # 用默认程序打开(录屏→QuickTime 播放)
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
            p = resolve(data.get("name") or "")
            if p:
                subprocess.run(["open", p])
            self._send(200, '{"ok":true}')
        elif self.path == "/api/shots/reveal":        # 在访达里高亮这个文件
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
            p = resolve(data.get("name") or "")
            if p:
                subprocess.run(["open", "-R", p])
            self._send(200, '{"ok":true}')
        elif self.path == "/api/shots/delete":
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
            names = data.get("names") or []
            paths = [resolve(x) for x in names]
            paths = [p for p in paths if p]                # 截图库/录屏库都解析
            if paths:
                subprocess.run([AISHOT, "--trash"] + paths)   # 移到废纸篓(可还原)
            self._send(200, '{"ok":true}')
        else:
            self._send(404, '{"error":"not found"}')

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        print("控制面板已启动: http://127.0.0.1:%d" % PORT)
        httpd.serve_forever()
