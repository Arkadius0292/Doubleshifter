#!/usr/bin/env bash
# Установка Doubleshifter на macOS.
#
# Владелец процесса — launchd, и только он: два одновременно живущих экземпляра
# ловят один и тот же двойной Shift и переключают раскладку дважды, то есть
# визуально не переключают вовсе. Для пересборки уже установленной копии
# используйте ../rebuild.sh.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="/Applications/DoubleShift.app"
BIN="$APP_DIR/Contents/MacOS/DoubleShift"
LABEL="com.user.double_shift_switcher"
PLIST_SRC="$REPO_DIR/launchd/$LABEL.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "🚀 Установка Doubleshifter для macOS..."

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "▶︎ сборка"
swiftc -O -g "$REPO_DIR/src/DoubleShiftSwitcher.swift" -o "$BIN" \
    -framework AppKit -framework Carbon
chmod +x "$BIN"
codesign -f -s - "$BIN"

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
    <string>5.0.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "▶︎ установка LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_PATH"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID" "$PLIST_PATH"
sleep 2

COUNT=$(pgrep -f "$BIN" | wc -l | tr -d ' ')
if [ "$COUNT" != "1" ]; then
    echo "⚠️ живых процессов: $COUNT, ожидается 1 — проверьте launchctl list | grep $LABEL"
    exit 1
fi

echo "✅ Doubleshifter установлен и запущен."
echo
echo "Осталось выдать права: System Settings → Privacy & Security → Accessibility → DoubleShift."
echo "Без них перехват клавиш не работает, а инверсия не может прочитать выделенный текст."
echo "Процесс подхватит права сам, перезапускать не нужно:"
echo "    tail -f /tmp/double_shift_switcher.log"
