#!/usr/bin/env bash
# Установка серверной части Doubleshifter на Linux-машину с X11.
#
# Запускать НА СЕРВЕРЕ, из каталога репозитория. Нужен sudo.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/usr/local/backup/doubleshift-$STAMP"

echo "🚀 Установка серверной части Doubleshifter..."

for tool in xdotool xclip xdpyinfo setxkbmap; do
    command -v "$tool" >/dev/null || { echo "✖ нет $tool — apt install xdotool xclip x11-utils x11-xkb-utils"; exit 1; }
done

echo "▶︎ бэкап прежних версий в $BACKUP"
sudo mkdir -p "$BACKUP"
for f in set_server_layout.py remote_invert_word.py kiosk_system_keyboard_daemon.py; do
    [ -f "/usr/local/bin/$f" ] && sudo cp -a "/usr/local/bin/$f" "$BACKUP/"
done
[ -f "$HOME/.xbindkeysrc" ] && sudo cp -a "$HOME/.xbindkeysrc" "$BACKUP/"

echo "▶︎ установка"
sudo install -m 0644 "$REPO_DIR/server/doubleshift_xkb.py" /usr/local/lib/doubleshift_xkb.py
sudo install -m 0755 "$REPO_DIR/server/set_server_layout.py" /usr/local/bin/set_server_layout.py
sudo install -m 0755 "$REPO_DIR/server/remote_invert_word.py" /usr/local/bin/remote_invert_word.py
sudo install -m 0755 "$REPO_DIR/server/kiosk_system_keyboard_daemon.py" /usr/local/bin/kiosk_system_keyboard_daemon.py

echo "▶︎ проверка"
export DISPLAY="${DISPLAY:-:0}"
/usr/local/bin/set_server_layout.py --get >/dev/null && echo "  чтение раскладки работает"

if systemctl list-unit-files 2>/dev/null | grep -q kiosk_system_keyboard_daemon; then
    sudo systemctl restart kiosk_system_keyboard_daemon.service
    sleep 4
    echo "  демон: $(systemctl is-active kiosk_system_keyboard_daemon.service)"
fi

echo "✅ Готово. Бэкап прежних версий: $BACKUP"
echo
echo "Важно: одно сочетание — один владелец. Проверьте, что горячие клавиши"
echo "демона не продублированы в ~/.xbindkeysrc и в openbox rc.xml, иначе"
echo "каждое нажатие сработает дважды или трижды. Образец: server/xbindkeysrc"
