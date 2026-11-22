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
  <!-- 录屏开麦克风时，系统拿这条文案问用户；缺了它子进程收声会被静默拒掉 -->
  <key>NSMicrophoneUsageDescription</key><string>书办录屏时要把你的解说和会议声音一起录进去。</string>
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

# 签名：优先用本机自签身份，退路才是 ad-hoc。
#
# ⚠️ 为什么不能每次都 ad-hoc：ad-hoc 的 designated requirement 就是「cdhash 相等」，
# 每改一行代码重新编译 cdhash 都变 → 系统认为换了个应用 → 屏幕录制 / 麦克风授权全部失效，
# 而系统设置里那条「书办」还勾着，于是出现「勾着、说没权限、重启也没用」的死结。
# 用自签证书签，DR 变成「identifier + 证书指纹」，重新编译不会动它，授权一次长期有效。
SIGN_ID="ShuBan Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "== 完成 =="
echo "$APP"
