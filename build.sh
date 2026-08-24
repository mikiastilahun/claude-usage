#!/bin/bash
# Builds ClaudeUsage.app — a menu bar only (no Dock icon) macOS app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Usage"
BUNDLE="build/${APP_NAME}.app"
CONFIG="${1:-release}"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" --disable-sandbox

BIN="$(swift build -c "$CONFIG" --show-bin-path)/ClaudeUsage"

echo "==> Assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/ClaudeUsage"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Usage</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleExecutable</key>      <string>ClaudeUsage</string>
    <key>CFBundleIdentifier</key>      <string>com.mikiastilahun.claudeusage</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS treats it as a stable identity (needed for login items).
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || \
    echo "    (ad-hoc signing skipped)"

echo "==> Built $BUNDLE"
