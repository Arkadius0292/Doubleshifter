#!/usr/bin/env python3
import os
import sys
import threading
import time
import subprocess

# Вывод уходит в journal, а не в терминал, поэтому по умолчанию буферизуется
# блоками — сообщения демона доходили до журнала с большой задержкой или
# терялись при падении. Переключаем на построчный.
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)


def wait_for_x(timeout=60):
    """Дождаться готовности X-сервера.

    Служба стартует по After=graphical.target, но это не гарантирует, что X уже
    принимает подключения. Импорт pynput в этот момент падает с DisplayNameError,
    и после boot демон оставался без потока горячих клавиш.
    """
    display = os.environ.setdefault("DISPLAY", ":0")
    os.environ.setdefault("XAUTHORITY", "/home/developer/.Xauthority")

    deadline = time.time() + timeout
    while time.time() < deadline:
        probe = subprocess.run(
            ["xdpyinfo", "-display", display],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if probe.returncode == 0:
            return True
        print(f"⏳ Жду X на {display}...")
        time.sleep(2)

    print(f"✖ X на {display} не поднялся за {timeout} с — выходим, systemd перезапустит")
    return False


if not wait_for_x():
    sys.exit(1)

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib
from pynput import keyboard

# ----------------------------------------------------
# 1. Графический HUD Выбора Сессий (GTK 3 Window)
# ----------------------------------------------------
class HUDWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="Смена рабочей среды")
        self.set_border_width(18)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_keep_above(True)
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)

        css = b"""
        window {
            background-color: #0F172A;
            border: 2px solid #334155;
            border-radius: 18px;
        }
        .title {
            color: #FFFFFF;
            font-size: 18px;
            font-weight: bold;
        }
        .subtitle {
            color: #94A3B8;
            font-size: 12px;
            margin-bottom: 12px;
        }
        button.close-btn {
            background-image: none;
            background-color: #EF4444;
            color: #FFFFFF;
            font-weight: bold;
            font-size: 14px;
            border-radius: 20px;
            border: none;
            padding: 3px 10px;
        }
        button.close-btn:hover {
            background-image: none;
            background-color: #DC2626;
        }
        button.card {
            background-image: none;
            background-color: #1E293B;
            border: 1px solid #334155;
            border-radius: 12px;
            padding: 10px 14px;
            margin-bottom: 8px;
            box-shadow: none;
        }
        button.card:hover {
            background-image: none;
            background-color: #334155;
            border-color: #38BDF8;
        }
        .card-title {
            color: #FFFFFF;
            font-size: 15px;
            font-weight: bold;
        }
        .card-desc {
            color: #94A3B8;
            font-size: 11px;
        }
        .key-badge {
            background-color: #0F172A;
            color: #38BDF8;
            font-weight: bold;
            border-radius: 6px;
            padding: 4px 8px;
            font-size: 12px;
            border: 1px solid #38BDF8;
        }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(vbox)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        lbl_title = Gtk.Label(label="🔄 Переключение рабочей среды", xalign=0)
        lbl_title.get_style_context().add_class("title")

        btn_close = Gtk.Button(label=" ✖ ")
        btn_close.get_style_context().add_class("close-btn")
        btn_close.connect("clicked", lambda w: self.destroy())

        header.pack_start(lbl_title, True, True, 0)
        header.pack_start(btn_close, False, False, 0)
        vbox.pack_start(header, False, False, 0)

        lbl_sub = Gtk.Label(label="Нажмите [1-4] на клавиатуре или кликните по выбору:", xalign=0)
        lbl_sub.get_style_context().add_class("subtitle")
        vbox.pack_start(lbl_sub, False, False, 0)

        icon_dir = "/home/developer/.local/share/kiosk-launcher/icons"
        modes = [
            ("1", "claude", "Claude AI Desktop", "Нативное приложение Claude AI с поддержкой скриншотов", f"{icon_dir}/claude.png"),
            ("2", "vscode", "Antigravity 2.0 IDE", "Оригинальная IDE Antigravity с мультиагентным чатом", f"{icon_dir}/vscode.png"),
            ("3", "xfce", "Быстрый Рабочий Стол", "Легковесный XFCE для управления и консоли", f"{icon_dir}/xfce.png"),
            ("4", "gnome", "Полная Ubuntu GNOME", "Полноценный десктоп Ubuntu со всеми окнами", f"{icon_dir}/gnome.png"),
        ]

        for key, mode, title, desc, icon_path in modes:
            btn = Gtk.Button()
            btn.get_style_context().add_class("card")
            btn.connect("clicked", self.on_mode_selected, mode)

            hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

            badge = Gtk.Label(label=f"[{key}]")
            badge.get_style_context().add_class("key-badge")
            hbox.pack_start(badge, False, False, 0)

            if os.path.exists(icon_path):
                try:
                    pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(icon_path, 32, 32, True)
                    img = Gtk.Image.new_from_pixbuf(pb)
                    hbox.pack_start(img, False, False, 0)
                except Exception:
                    pass

            tbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            t_lbl = Gtk.Label(label=title, xalign=0)
            t_lbl.get_style_context().add_class("card-title")
            d_lbl = Gtk.Label(label=desc, xalign=0)
            d_lbl.get_style_context().add_class("card-desc")

            tbox.pack_start(t_lbl, False, False, 0)
            tbox.pack_start(d_lbl, False, False, 0)
            hbox.pack_start(tbox, True, True, 0)

            btn.add(hbox)
            vbox.pack_start(btn, False, False, 0)

        self.connect("key-press-event", self.on_key_press)

    def on_key_press(self, widget, event):
        key_name = Gdk.keyval_name(event.keyval)
        if key_name == "Escape":
            self.destroy()
        elif key_name in ["1", "KP_1"]:
            self.on_mode_selected(None, "claude")
        elif key_name in ["2", "KP_2"]:
            self.on_mode_selected(None, "vscode")
        elif key_name in ["3", "KP_3"]:
            self.on_mode_selected(None, "xfce")
        elif key_name in ["4", "KP_4"]:
            self.on_mode_selected(None, "gnome")

    def on_mode_selected(self, widget, mode):
        self.destroy()
        switch_mode_action(mode)

# Одно окно HUD за раз: повторное нажатие хоткея при открытом окне не должно
# плодить копии.
_hud_window = None


def show_hud_window(trigger="?"):
    def run_gtk():
        global _hud_window
        print(f"⌨️  HUD вызван ({trigger})")
        if _hud_window is not None:
            _hud_window.present()
            return False

        def forget(_widget):
            global _hud_window
            _hud_window = None

        # Раньше здесь запускался вложенный Gtk.main(), а на destroy висел
        # Gtk.main_quit — закрытие окна выбрасывало демон из ГЛАВНОГО цикла,
        # он завершался и поднимался заново по Restart=always. Главный цикл уже
        # крутится в main(), отдельный тут не нужен.
        _hud_window = HUDWindow()
        _hud_window.connect("destroy", forget)
        _hud_window.show_all()
        return False

    GLib.idle_add(run_gtk)

def switch_mode_action(mode):
    print(f"🚀 Switching to session mode: {mode}")
    subprocess.run(["/usr/local/bin/direct_switch.py", mode])


def toggle_layout_action():
    try:
        sys.path.insert(0, "/usr/local/lib")
        from doubleshift_xkb import toggle_lang, x_env

        # Демон слушает хоткеи только на :0 (DISPLAY задан в systemd-юните),
        # поэтому это нажатие могло прийти только из RustDesk. toggle_lang()
        # без явного env перебирает ВСЕ активные дисплеи и переключал заодно
        # независимую RDP-сессию на :10, где никто ничего не нажимал.
        print(f"🌐 раскладка сервера → {toggle_lang(x_env(':0'))}")
    except Exception as e:
        print("Layout toggle error:", e)

def main():
    print("🚀 Master System Keyboard & HUD Daemon (v2.0 Multi-Client Native) Started 24/7.")

    # Фиксируем базовый список раскладок us,ru — но только если он сбит.
    # Раньше setxkbmap вызывался безусловно, а у службы стоит Restart=always:
    # каждое падение демона сбрасывало активную группу на us независимо от того,
    # какой язык стоял на Маке, и ломало синхронизацию раскладок.
    try:
        sys.path.insert(0, "/usr/local/lib")
        from doubleshift_xkb import ensure_base_layout, current_lang

        if ensure_base_layout():
            print("🌐 X11 layout list restored to us,ru.")
        else:
            print(f"🌐 X11 layout list already us,ru (active: {current_lang()}), not touching.")
    except Exception as e:
        print("Layout init error:", e)

    bindings = {}
    for combo in ('<alt>+<space>', '<cmd>+<space>', '<f12>', '<ctrl>+<alt>+k'):
        bindings[combo] = (lambda c=combo: show_hud_window(c))

    # Переключение раскладки через демон.
    # Штатные переключатели XKB (grp:caps_toggle, grp:alt_shift_toggle) из
    # RustDesk ненадёжны: CapsLock macOS обрабатывает на уровне прошивки и на
    # удалённую сторону не отдаёт вовсе. Здесь язык меняется программно через
    # XkbLockGroup — тот же путь, которым пользуется синхронизация с Мака.
    for combo in ('<ctrl>+<alt>+<space>', '<alt>+g', '<ctrl>+<alt>+g'):
        bindings[combo] = (lambda c=combo: (print(f"⌨️  {c}"), toggle_layout_action()))
    for digit, mode in ((1, "claude"), (2, "vscode"), (3, "xfce"), (4, "gnome")):
        for modifier in ('<alt>', '<cmd>'):
            combo = f'{modifier}+{digit}'
            bindings[combo] = (lambda m=mode, c=combo: (print(f"⌨️  {c}"), switch_mode_action(m)))

    # Невалидное сочетание роняет ВЕСЬ набор хоткеев разом, поэтому проверяем
    # каждое по отдельности и выкидываем только сломанное.
    valid = {}
    for combo, action in bindings.items():
        try:
            keyboard.HotKey.parse(combo)
            valid[combo] = action
        except Exception as e:
            print(f"⚠️  хоткей {combo} отброшен: {type(e).__name__}: {e}")
    print(f"⌨️  активных хоткеев: {len(valid)} из {len(bindings)}")

    hotkeys = keyboard.GlobalHotKeys(valid)
    hotkeys.start()

    # Поток слушателя может умереть сам по себе (например, обрыв соединения с X),
    # и тогда служба остаётся в состоянии active, но все горячие клавиши мертвы —
    # Restart=always в этом случае не срабатывает, потому что процесс жив.
    # Сторож замечает это и завершает процесс, чтобы systemd поднял службу.
    def watch_hotkeys():
        while True:
            time.sleep(5)
            if not hotkeys.is_alive():
                print("✖ поток горячих клавиш умер — выходим, systemd перезапустит")
                os._exit(1)
        return None

    threading.Thread(target=watch_hotkeys, daemon=True).start()

    Gtk.main()

if __name__ == "__main__":
    main()
