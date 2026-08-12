"""Состояние клавиатурной раскладки X11 через XKB напрямую (libX11 + ctypes).

Зачем не setxkbmap:
  * `setxkbmap -query` отдаёт СПИСОК раскладок ("us,ru"), а не активную. При
    включённом grp:caps_toggle пользователь переключает группу CapsLock'ом, и
    список при этом не меняется — прочитать по нему текущий язык невозможно.
  * `setxkbmap -layout ...` перекомпилирует всю клавиатурную карту (~50-200 мс)
    и рассылает MappingNotify всем клиентам X. Electron-приложения (Claude,
    VSCode, Chrome) на это реагируют с задержкой и теряют состояние модификаторов.

Здесь базовый список раскладок задаётся ОДИН раз (us,ru), а переключение языка —
это смена активной группы XKB через XkbLockGroup: мгновенно и без MappingNotify.
"""

import ctypes
import ctypes.util
import os
import subprocess

XkbUseCoreKbd = 0x0100

# Группа 0 — первая раскладка в списке, группа 1 — вторая.
BASE_LAYOUT = "us,ru"
# caps_toggle — переключение с клавиатуры самого сервера.
# alt_shift_toggle — переключение из RustDesk: CapsLock macOS обрабатывает на
# уровне прошивки и на удалённую сторону не отдаёт, а Alt+Shift доезжает как
# обычные модификаторы.
BASE_OPTIONS = "grp:caps_toggle,grp:alt_shift_toggle"
GROUP_BY_LANG = {"en": 0, "us": 0, "ru": 1}
LANG_BY_GROUP = {0: "en", 1: "ru"}


class XkbStateRec(ctypes.Structure):
    """Раскладка XkbStateRec из X11/XKBlib.h — порядок полей менять нельзя."""

    _fields_ = [
        ("group", ctypes.c_ubyte),
        ("locked_group", ctypes.c_ubyte),
        ("base_group", ctypes.c_ushort),
        ("latched_group", ctypes.c_ushort),
        ("mods", ctypes.c_ubyte),
        ("base_mods", ctypes.c_ubyte),
        ("latched_mods", ctypes.c_ubyte),
        ("locked_mods", ctypes.c_ubyte),
        ("compat_state", ctypes.c_ubyte),
        ("grab_mods", ctypes.c_ubyte),
        ("compat_grab_mods", ctypes.c_ubyte),
        ("lookup_mods", ctypes.c_ubyte),
        ("compat_lookup_mods", ctypes.c_ubyte),
        ("ptr_buttons", ctypes.c_ushort),
    ]


class Xkb:
    """Подключение к X-серверу для чтения и записи активной группы."""

    def __init__(self, display_name=None):
        name = display_name or os.environ.get("DISPLAY") or ":0"
        self._name = name.encode("utf-8")
        libname = ctypes.util.find_library("X11")
        if not libname:
            raise RuntimeError("libX11 не найдена — установи libx11-6")
        self._x = ctypes.CDLL(libname)
        self._x.XOpenDisplay.restype = ctypes.c_void_p
        self._d = None

    def __enter__(self):
        self._d = self._x.XOpenDisplay(self._name)
        if not self._d:
            raise RuntimeError(
                f"не открывается DISPLAY {self._name.decode()} "
                f"(XAUTHORITY={os.environ.get('XAUTHORITY', 'не задан')})"
            )
        return self

    def __exit__(self, *_exc):
        if self._d:
            self._x.XCloseDisplay(ctypes.c_void_p(self._d))
            self._d = None
        return False

    def group(self):
        """Активная группа XKB: 0 или 1."""
        state = XkbStateRec()
        rc = self._x.XkbGetState(
            ctypes.c_void_p(self._d), ctypes.c_uint(XkbUseCoreKbd), ctypes.byref(state)
        )
        if rc != 0:
            raise RuntimeError(f"XkbGetState вернул {rc}")
        return state.group

    def lock_group(self, group):
        """Зафиксировать группу. Мгновенно, без перекомпиляции карты."""
        self._x.XkbLockGroup(
            ctypes.c_void_p(self._d), ctypes.c_uint(XkbUseCoreKbd), ctypes.c_uint(group)
        )
        self._x.XFlush(ctypes.c_void_p(self._d))

    def lang(self):
        return LANG_BY_GROUP.get(self.group(), "en")


def x_env():
    """Окружение с DISPLAY/XAUTHORITY — скрипты дёргаются по SSH без сессии X."""
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")
    env.setdefault("XAUTHORITY", "/home/developer/.Xauthority")
    return env


def ensure_base_layout(env=None):
    """Привести список раскладок к us,ru, если он сбит. Идемпотентно.

    Вызывать дёшево: если список уже правильный, setxkbmap не запускается и
    группа не сбрасывается.
    """
    env = env or x_env()
    layout_ok = options_ok = False
    try:
        out = subprocess.check_output(["setxkbmap", "-query"], env=env, timeout=5)
        for line in out.decode("utf-8", "ignore").splitlines():
            if line.startswith("layout:"):
                layout_ok = line.split(":", 1)[1].strip() == BASE_LAYOUT
            elif line.startswith("options:"):
                have = set(line.split(":", 1)[1].strip().split(","))
                options_ok = set(BASE_OPTIONS.split(",")).issubset(have)
    except Exception:
        pass

    if layout_ok and options_ok:
        return False

    # Одной командой: при двух ключах -option подряд setxkbmap записывает
    # свойство корневого окна, но карту не перекомпилирует — `setxkbmap -query`
    # показывает нужные опции, а переключатели групп при этом не работают.
    subprocess.run(
        ["setxkbmap", "-layout", BASE_LAYOUT, "-option", BASE_OPTIONS],
        env=env,
        timeout=10,
    )
    return True


def toggle_lang(env=None):
    """Переключить язык на противоположный. Возвращает новый язык."""
    env = env or x_env()
    os.environ.setdefault("DISPLAY", env["DISPLAY"])
    os.environ.setdefault("XAUTHORITY", env["XAUTHORITY"])
    with Xkb(env["DISPLAY"]) as xkb:
        new_group = 1 - xkb.group()
        xkb.lock_group(new_group)
        return LANG_BY_GROUP.get(new_group, "?")


def set_lang(lang, env=None):
    """Установить язык абсолютно. Возвращает (изменилось, было, стало)."""
    lang = "ru" if str(lang).lower().startswith("ru") else "en"
    env = env or x_env()
    os.environ.setdefault("DISPLAY", env["DISPLAY"])
    os.environ.setdefault("XAUTHORITY", env["XAUTHORITY"])

    ensure_base_layout(env)
    with Xkb(env["DISPLAY"]) as xkb:
        before = xkb.group()
        want = GROUP_BY_LANG[lang]
        if before == want:
            return False, LANG_BY_GROUP.get(before, "?"), lang
        xkb.lock_group(want)
        return True, LANG_BY_GROUP.get(before, "?"), lang


def current_lang(env=None):
    env = env or x_env()
    os.environ.setdefault("DISPLAY", env["DISPLAY"])
    os.environ.setdefault("XAUTHORITY", env["XAUTHORITY"])
    with Xkb(env["DISPLAY"]) as xkb:
        return xkb.lang()
