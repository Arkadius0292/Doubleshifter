#!/usr/bin/env bash
set -e

echo "🚀 Installing Doubleshifter for macOS..."

APP_DIR="/Applications/DoubleShift.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Compile Swift code
swiftc src/DoubleShiftSwitcher.swift -o "$APP_DIR/Contents/MacOS/DoubleShift"
chmod +x "$APP_DIR/Contents/MacOS/DoubleShift"
codesign -f -s - "$APP_DIR/Contents/MacOS/DoubleShift"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DoubleShift</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.doubleshift</string>
    <key>CFBundleName</key>
    <string>DoubleShift</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Install LaunchAgent
PLIST_PATH="$HOME/Library/LaunchAgents/com.user.doubleshift.plist"
cp launchd/com.user.doubleshift.plist "$PLIST_PATH"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load -w "$PLIST_PATH"

echo "✅ Doubleshifter successfully installed and active!"
