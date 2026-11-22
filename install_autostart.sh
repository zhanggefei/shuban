#!/bin/bash
# 可选：安装/卸载「登录自动启动书办」+「每 30 分钟后台自动刷新」
# 注：小组件本体已内置 10 分钟自动同步，这个定时刷新只在「希望退出后也保持数据新鲜」时才需要。
# 用法：./install_autostart.sh          安装
#       ./install_autostart.sh uninstall 卸载
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/书办.app"
AGENT_DIR="$HOME/Library/LaunchAgents"
W_PLIST="$AGENT_DIR/com.zhanggefei.shuban.plist"
R_PLIST="$AGENT_DIR/com.zhanggefei.shuban.refresh.plist"

if [ "${1:-}" = "uninstall" ]; then
  launchctl unload "$W_PLIST" 2>/dev/null || true
  launchctl unload "$R_PLIST" 2>/dev/null || true
  rm -f "$W_PLIST" "$R_PLIST"
  echo "已卸载开机自启与定时刷新。"
  exit 0
fi

[ -d "$APP" ] || { echo "未找到 $APP，请先执行 ./build.sh"; exit 1; }
mkdir -p "$AGENT_DIR" "$DIR/logs"

cat > "$W_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.zhanggefei.shuban</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST

cat > "$R_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.zhanggefei.shuban.refresh</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>$DIR/fetch_data.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>1800</integer>
  <key>StandardOutPath</key><string>$DIR/logs/refresh.log</string>
  <key>StandardErrorPath</key><string>$DIR/logs/refresh.err</string>
</dict>
</plist>
PLIST

launchctl unload "$W_PLIST" 2>/dev/null || true
launchctl unload "$R_PLIST" 2>/dev/null || true
launchctl load "$W_PLIST"
launchctl load "$R_PLIST"

echo "✅ 已安装："
echo "   · 登录自动启动小组件"
echo "   · 每 30 分钟后台自动拉取企微日程/待办（日志 $DIR/logs/refresh.log）"
echo "   卸载：./install_autostart.sh uninstall"
