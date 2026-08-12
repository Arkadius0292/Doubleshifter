#!/bin/bash
# Пересборка и перезапуск DoubleShift.
#
# Владелец процесса — launchd, и только он. Прежняя процедура делала
# `pkill -9` + `nohup ... &`: pkill убивал launchd-инстанс, KeepAlive тут же
# поднимал его заново, а nohup добавлял второй. Два процесса ловили один и тот
# же двойной Shift и переключали раскладку дважды, то есть визуально не
# переключали вовсе. Здесь сначала bootout, потом замена бинаря, потом
# bootstrap — ровно один живой процесс на всех этапах.

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
codesign --force --deep --sign - "$BUILD_DIR/DoubleShift"

echo "▶︎ остановка службы"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# Подчищаем инстансы, запущенные мимо launchd прошлыми версиями скрипта.
pkill -f "$BIN" 2>/dev/null || true
sleep 1

echo "▶︎ замена бинаря"
cp "$BUILD_DIR/DoubleShift" "$BIN"

echo "▶︎ запуск службы"
launchctl bootstrap "gui/$UID" "$PLIST"
sleep 2

COUNT=$(pgrep -f "$BIN" | wc -l | tr -d ' ')
echo "▶︎ живых процессов: $COUNT (ожидается 1)"
pgrep -lf "$BIN" || true

if [ "$COUNT" != "1" ]; then
    echo "⚠️ процессов не один — проверь launchctl list | grep $LABEL"
    exit 1
fi

echo "▶︎ лог: tail -f /tmp/double_shift_switcher.log"
