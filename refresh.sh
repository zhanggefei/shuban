#!/bin/bash
# 一键刷新「书办」的数据快照（当前接的是企业微信日程 + 待办）
# 用法：./refresh.sh          拉取并更新 data/data.json
#       ./refresh.sh --open   拉取后顺便重启小组件让它立刻重载
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PY=/usr/bin/python3
[ -x "$PY" ] || PY=python3

# 从 Finder / Dock 启动小组件时，进程 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
# wecom-cli 和它依赖的 node 都不在里面 —— 界面点刷新就会「取数为空、数据被清空」。
# 这里显式把常见安装位置补进 PATH（fetch_data.py 里还有一道同样的兜底）。
for d in "$HOME/.workbuddy/binaries/node/cli-connector-packages/bin" \
         "$HOME/.octop/bin" "$HOME/bin" "$HOME/.local/bin" \
         /usr/local/bin /opt/homebrew/bin; do
  [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
for d in "$HOME/.workbuddy/binaries/node/versions/"*/bin; do
  [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

echo "== 刷新书办数据 =="

if [ "${1:-}" = "--open" ]; then
  "$PY" "$DIR/fetch_data.py"
  RC=$?
  pkill -f "ShuBan" 2>/dev/null
  sleep 0.4
  open "$DIR/build/书办.app"
  echo
  if [ $RC -eq 0 ]; then
    echo "✅ 刷新完成"
  else
    echo "⚠️ 刷新未完全成功（见上方提示）。已拉到的部分已更新，失败的模块保留上次数据。"
  fi
  exit $RC
fi

# 正常路径用 exec 把 bash 换成 python，少一层进程：小组件退出/重启时只能 terminate
# 到它的直接子进程（bash），python 会变成孤儿继续调 CLI，而输出管道已经断了 ——
# 实测表现为 wecom-cli 返回「成功但是空列表」，界面误报「部分模块沿用旧数据」。
exec "$PY" "$DIR/fetch_data.py"
