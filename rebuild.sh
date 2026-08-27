#!/bin/bash
# Пересборка и перезапуск DoubleShift с постоянной цифровой подписью идентификатора.

set -euo pipefail

SRC="/Users/KuleshAV/АРХИВ ПРИЛОЖЕНИЙ/Doubleshifter/src/DoubleShiftSwitcher.swift"
APP="/Applications/DoubleShift.app"
BIN="$APP/Contents/MacOS/DoubleShift"
PLIST="$HOME/Library/LaunchAgents/com.user.double_shift_switcher.plist"
LABEL="com.user.double_shift_switcher"
BUILD_DIR="/tmp/DoubleShiftBuild"

echo "▶︎ сборка"
mkdir -p "$BUILD_DIR"
swiftc -O -g "$SRC" -o "$BUILD_DIR/DoubleShift" -framework AppKit -framework Carbon

echo "▶︎ остановка службы"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -9 -f "$BIN" 2>/dev/null || true
rm -f /tmp/double_shift_switcher.lock
sleep 1

echo "▶︎ замена бинаря и постоянная подпись"
cp "$BUILD_DIR/DoubleShift" "$BIN"
codesign --force --deep -s - -r='designated => identifier "com.user.doubleshift"' "$APP"

echo "▶︎ запуск службы"
launchctl bootstrap "gui/$UID" "$PLIST"
sleep 1

COUNT=$(pgrep -f "$BIN" | wc -l | tr -d ' ')
echo "▶︎ живых процессов: $COUNT (ожидается 1)"
pgrep -lf "$BIN" || true

echo "▶︎ лог: tail -f /tmp/double_shift_switcher.log"
