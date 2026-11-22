#!/bin/bash
# 编译并打包「书办」桌面办公助手
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/书办.app"
BIN="ShuBan"
SRC_DIR="$DIR/src"

echo "== 编译 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -o "$APP/Contents/MacOS/$BIN" \
  "$SRC_DIR"/*.swift \
  -framework SwiftUI -framework AppKit

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>书办</string>
  <key>CFBundleDisplayName</key><string>书办</string>
  <key>CFBundleExecutable</key><string>${BIN}</string>
  <key>CFBundleIdentifier</key><string>com.zhanggefei.shuban</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 zhanggefei &lt;zhanggefei@126.com&gt; · MIT License</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>WECALProjectDir</key><string>${DIR}</string>
</dict>
</plist>
PLIST

cp "$DIR/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 数据快照兜底（app 被移动后仍能显示内容）
if [ -f "$DIR/data/data.json" ]; then
  cp "$DIR/data/data.json" "$APP/Contents/Resources/data.json"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "== 完成 =="
echo "$APP"
