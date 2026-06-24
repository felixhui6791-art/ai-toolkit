#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""更新时合并配置：以新版 config 为底（带上新增的工具/预设），但保留用户自己的设置。
用法： merge_config.py <用户当前config> <新版config(会被写成合并结果)>
合并后的结果写回第二个参数（新版config），随后由 selfupdate.sh 覆盖到安装目录。
"""
import json, sys

old = json.load(open(sys.argv[1], encoding="utf-8"))   # 用户当前的（含他改过的快捷键/选的模型）
new = json.load(open(sys.argv[2], encoding="utf-8"))   # 新版默认（含新功能）

# 1) 整体保留用户的这些选择（模型、语言、录音设备、更新源）
for k in ("update_repo", "models", "speech_language", "audio_device_index"):
    if k in old:
        new[k] = old[k]

# 2) 对“原本就有”的工具，保留用户改过的快捷键和启用开关；新工具用新版默认
old_tools = old.get("tools") or {}
for tid, t in (new.get("tools") or {}).items():
    if tid in old_tools and isinstance(t, dict):
        for f in ("hotkey", "enabled"):
            if f in old_tools[tid]:
                t[f] = old_tools[tid][f]

json.dump(new, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("配置已合并（保留了你的快捷键/模型/设置）")
