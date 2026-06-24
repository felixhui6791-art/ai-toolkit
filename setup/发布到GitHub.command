#!/bin/bash
# 给“作者(你)”用的一键发布：编译截图程序 → 刷新版本号 → 提交 → 推送到 GitHub。
# 朋友那边 6 小时内会自动提示“有新版本”，点一下就更新到你刚发布的版本。
cd "$(dirname "$0")/.." || exit 1
PROJ="$(pwd)"
echo "============================================"
echo "   发布「本地 AI 工具集」到 GitHub"
echo "============================================"

command -v git >/dev/null 2>&1 || { echo "需要先装命令行工具（会弹窗，点安装后重跑本文件）"; xcode-select --install; exit 1; }

# 1) 取仓库地址（第一次会问你，并记到 config.json）
REPO="$(python3 -c "import json;print(json.load(open('config.json',encoding='utf-8')).get('update_repo',''))" 2>/dev/null)"
if [ -z "$REPO" ]; then
  echo
  echo "第一次发布：请先去 github.com 建一个【空】仓库（名字随意，比如 ai-toolkit，public）。"
  read -r -p "把它写成 用户名/仓库名 粘到这里（例：zhangsan/ai-toolkit）然后回车： " REPO
  [ -z "$REPO" ] && { echo "没填，退出。"; exit 1; }
  python3 - "$PROJ/config.json" "$REPO" <<'PY'
import json,sys
p,r=sys.argv[1],sys.argv[2]
c=json.load(open(p,encoding="utf-8")); c["update_repo"]=r
json.dump(c,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY
  echo "已记下仓库：$REPO（以后发布不再问）"
fi
echo "仓库：$REPO"

# 2) 重新编译截图程序，把最新的带进仓库（朋友更新时直接拿到，不用装 Xcode）
echo "编译截图程序…"; bash screenshot/build.sh >/dev/null 2>&1 && echo "  ✅ 已编译" || echo "  （编译跳过/失败，继续）"

# 3) 刷新版本号（用当前时间；朋友据此判断有没有新版）
date '+%Y-%m-%d %H:%M' > VERSION
echo "新版本号：$(cat VERSION)"

# 4) 提交并推送
[ -d .git ] || git init -q
git add -A
git -c user.email=local@ai-toolkit -c user.name="ai-toolkit" commit -q -m "发布 $(cat VERSION)" 2>/dev/null || echo "  （这次没有改动）"
git branch -M main 2>/dev/null
git remote remove origin 2>/dev/null
git remote add origin "https://github.com/$REPO.git"
echo
echo "推送到 GitHub …（第一次会让你登录/授权 GitHub）"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 || gh auth login
  git push -u origin main
else
  git push -u origin main
fi

CODE=$?
echo
if [ $CODE -eq 0 ]; then
  echo "✅ 发布完成！朋友那边 6 小时内会自动提示更新；他也可在菜单栏 🤖 → 检查更新 立刻拉到。"
else
  echo "⚠️ 推送没成功（多半是没登录 GitHub）。最省事的两种登录方式："
  echo "   · 装 GitHub 官方命令行：brew install gh，然后 gh auth login（浏览器点一下就好），再重跑本文件。"
  echo "   · 或用 GitHub Desktop（图形界面 App），把本文件夹拖进去，点 Commit + Push。"
fi
