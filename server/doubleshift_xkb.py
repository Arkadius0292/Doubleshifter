"""Состояние клавиатурной раскладки X11 через XKB напрямую (libX11 + ctypes).
Поддерживает работу на ВСЕХ активных X11 дисплеях (:0 для RustDesk/киоска, :10/:11 для RDP).
"""

import ctypes
import ctypes.util
import os
import subprocess
import glob

XkbUseCoreKbd = 0x0100

BASE_LAYOUT = "us,ru"
BASE_OPTIONS = "grp:caps_toggle,grp:alt_shift_toggle"
GROUP_BY_LANG = {"en": 0, "us": 0, "ru": 1}
LANG_BY_GROUP = {0: "en", 1: "ru"}


class XkbStateRec(ctypes.Structure):
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
    def __init__(self, display_name=None):
        name = display_name or os.environ.get("DISPLAY") or ":0"
        self._name = name.encode("utf-8")
        libname = ctypes.util.find_library("X11")
        if not libname:
            raise RuntimeError("libX11 not found")
        self._x = ctypes.CDLL(libname)
        self._x.XOpenDisplay.restype = ctypes.c_void_p
        self._d = None

    def __enter__(self):
        self._d = self._x.XOpenDisplay(self._name)
        if not self._d:
            raise RuntimeError(
                f"Failed to open DISPLAY {self._name.decode()}"
            )
        return self

    def __exit__(self, *_exc):
        if self._d:
            self._x.XCloseDisplay(ctypes.c_void_p(self._d))
            self._d = None
        return False

    def group(self):
        state = XkbStateRec()
        rc = self._x.XkbGetState(
            ctypes.c_void_p(self._d), ctypes.c_uint(XkbUseCoreKbd), ctypes.byref(state)
        )
        if rc != 0:
            raise RuntimeError(f"XkbGetState returned {rc}")
        return state.group

    def lock_group(self, group):
        self._x.XkbLockGroup(
            ctypes.c_void_p(self._d), ctypes.c_uint(XkbUseCoreKbd), ctypes.c_uint(group)
        )
        self._x.XFlush(ctypes.c_void_p(self._d))

    def lang(self):
        return LANG_BY_GROUP.get(self.group(), "en")


def get_all_active_displays():
    """Найти все активные X11 дисплеи (:0, :10, :11 и т.д.)"""
    displays = []
    for s in glob.glob("/tmp/.X11-unix/X*"):
        num = s.split("/X")[-1]
        displays.append(f":{num}")
    if not displays:
        displays = [":0", ":10"]
    return sorted(list(set(displays)))


def x_env(display=None):
    env = dict(os.environ)
    env["DISPLAY"] = display or env.get("DISPLAY", ":0")
    env["XAUTHORITY"] = "/home/developer/.Xauthority"
    return env


def _layout_and_options(denv):
    """Реальные layout/options из setxkbmap -query, а не догадки по подстроке."""
    out = subprocess.check_output(
        ["setxkbmap", "-query"], env=denv, stderr=subprocess.DEVNULL, timeout=3
    ).decode("utf-8", "ignore")
    layout = options = ""
    for line in out.splitlines():
        if line.startswith("layout:"):
            layout = line.split(":", 1)[1].strip()
        elif line.startswith("options:"):
            options = line.split(":", 1)[1].strip()
    return layout, options


_REQUIRED_OPTIONS = set(BASE_OPTIONS.split(","))


def ensure_base_layout(env=None):
    """Привести список раскладок и переключатели групп к BASE_LAYOUT/BASE_OPTIONS.

    Раньше проверка была `("us,ru" in out_str)`, а BASE_LAYOUT сам равен "us,ru" —
    условие было истинно всегда, как только список раскладок назывался правильно,
    независимо от того, скомпилированы ли в карту сами переключатели групп
    (grp:caps_toggle, grp:alt_shift_toggle). Из-за этого пропажа переключателей
    после рестарта X-сервера никогда не обнаруживалась и не чинилась сама.
    Плюс код нигде не проверял код возврата setxkbmap — неудачное применение
    выглядело как успешное.
    """
    displays = [env["DISPLAY"]] if env and "DISPLAY" in env else get_all_active_displays()
    changed_any = False
    for disp in displays:
        denv = x_env(disp)
        try:
            layout, options = _layout_and_options(denv)
            have_options = set(options.split(",")) if options else set()
            ok = (layout == BASE_LAYOUT) and _REQUIRED_OPTIONS.issubset(have_options)
        except Exception:
            ok = False

        if not ok:
            result = subprocess.run(
                ["setxkbmap", "-layout", BASE_LAYOUT, "-option", BASE_OPTIONS],
                env=denv, stderr=subprocess.PIPE, timeout=5,
            )
            if result.returncode == 0:
                changed_any = True
            # При неудаче ok останется False на следующей проверке — теперь мы
            # реально сверяем результат, а не верим самому факту вызова.
    return changed_any


def set_lang(lang, env=None):
    lang = "ru" if str(lang).lower().startswith("ru") else "en"
    want = GROUP_BY_LANG[lang]
    displays = [env["DISPLAY"]] if env and "DISPLAY" in env else get_all_active_displays()
    
    changed_any = False
    last_before = 0
    
    for disp in displays:
        denv = x_env(disp)
        try:
            ensure_base_layout(denv)
            with Xkb(disp) as xkb:
                before = xkb.group()
                last_before = before
                if before != want:
                    xkb.lock_group(want)
                    changed_any = True
        except Exception:
            pass
            
    return changed_any, LANG_BY_GROUP.get(last_before, "?"), lang


def toggle_lang(env=None):
    displays = [env["DISPLAY"]] if env and "DISPLAY" in env else get_all_active_displays()
    new_lang = "ru"
    for disp in displays:
        try:
            denv = x_env(disp)
            ensure_base_layout(denv)
            with Xkb(disp) as xkb:
                new_group = 1 - xkb.group()
                xkb.lock_group(new_group)
                new_lang = LANG_BY_GROUP.get(new_group, "?")
        except Exception:
            pass
    return new_lang


def current_lang(env=None):
    # :0 — основной интерфейс (RustDesk), приоритет над RDP-дисплеями.
    disp = (env and env.get("DISPLAY")) or ":0"
    try:
        with Xkb(disp) as xkb:
            return xkb.lang()
    except Exception:
        try:
            with Xkb(":0") as xkb:
                return xkb.lang()
        except Exception:
            return "en"
