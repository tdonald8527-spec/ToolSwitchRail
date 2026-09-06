#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
SRC_DIR="$ROOT_DIR/ToolSwitchRail"
DIST_DIR="$ROOT_DIR/Dist"
APP_NAME="Tool Switch Rail"
BUNDLE_NAME="ToolSwitchRail"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/$BUNDLE_NAME"

cd "$ROOT_DIR"

echo "[1/5] 检查 Apple Command Line Tools / Swift..."
if ! command -v xcrun >/dev/null 2>&1; then
  echo "错误：未找到 xcrun。请先运行：xcode-select --install"
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "错误：未找到 swiftc。请先运行：xcode-select --install"
  exit 1
fi
xcrun swiftc --version | head -n 2

echo "[2/5] 创建 .app 目录..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ToolSwitchRail</string>
    <key>CFBundleIdentifier</key>
    <string>com.donald.toolswitchrail</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Tool Switch Rail</string>
    <key>CFBundleDisplayName</key>
    <string>Tool Switch Rail</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Tool Switch Rail</string>
</dict>
</plist>
PLIST

cp "$SRC_DIR/Resources/default-config.json" "$RESOURCES_DIR/default-config.json"
if [ -d "$SRC_DIR/Resources/icons" ]; then
  mkdir -p "$RESOURCES_DIR/icons"
  cp -R "$SRC_DIR/Resources/icons/"* "$RESOURCES_DIR/icons/"
fi

echo "[3/5] 编译 SwiftUI + AppKit..."
SWIFT_FILES=(
  "$SRC_DIR/ToolSwitchRailApp.swift"
  "$SRC_DIR/AppDelegate.swift"
  "$SRC_DIR/Models/ToolConfig.swift"
  "$SRC_DIR/Models/ToolStatus.swift"
  "$SRC_DIR/Services/AccessibilityPermission.swift"
  "$SRC_DIR/Services/ConfigStore.swift"
  "$SRC_DIR/Services/GlobalHotKeyManager.swift"
  "$SRC_DIR/Services/WindowTracker.swift"
  "$SRC_DIR/Services/WindowManager.swift"
  "$SRC_DIR/Services/ToolStatusMonitor.swift"
  "$SRC_DIR/UI/ToolIconView.swift"
  "$SRC_DIR/UI/NeedsYouPanel.swift"
  "$SRC_DIR/UI/RailView.swift"
  "$SRC_DIR/UI/RailWindowController.swift"
)

xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -lsqlite3 \
  "${SWIFT_FILES[@]}" \
  -o "$EXECUTABLE"

chmod +x "$EXECUTABLE"

echo "[4/5] 本地签名与代码需求绑定..."
/usr/bin/codesign --force --deep -s - -r="designated => identifier \"com.donald.toolswitchrail\"" "$APP_DIR" >/dev/null

echo "[5/5] 完成。"
echo ""
echo "生成位置："
echo "$APP_DIR"
echo ""
echo "首次运行后，请到："
echo "系统设置 → 隐私与安全性 → 辅助功能"
echo "允许 Tool Switch Rail。"
echo ""
open -R "$APP_DIR"
