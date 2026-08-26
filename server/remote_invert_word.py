#!/usr/bin/env python3
"""Инверсия регистра и раскладки последнего слова / выделения.
Поддерживает ВСЕ активные X11 дисплеи (:0 для RustDesk, :10/:11 для RDP).
"""

import os
import subprocess
import sys
import time
import glob

sys.path.insert(0, "/usr/local/lib")
from doubleshift_xkb import Xkb, GROUP_BY_LANG, ensure_base_layout, x_env, get_all_active_displays

EN_TO_RU = {
    "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш",
    "o": "щ", "p": "з", "[": "х", "]": "ъ",
    "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л",
    "l": "д", ";": "ж", "\x27": "э",
    "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь", ",": "б",
    ".": "ю",
    "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н", "U": "Г", "I": "Ш",
    "O": "Щ", "P": "З", "{": "Х", "}": "Ъ",
    "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П", "H": "Р", "J": "О", "K": "Л",
    "L": "Д", ":": "Ж", "\"": "Э",
    "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И", "N": "Т", "M": "Ь", "<": "Б",
    ">": "Ю",
    "`": "ё", "~": "Ё", "@": "\"", "#": "№", "$": ";", "^": ":", "&": "?",
    "/": ".", "?": ",",
}
RU_TO_EN = {v: k for k, v in EN_TO_RU.items()}
NUMERIC_PUNCT = {".", ","}


def _is_numeric_context(text, i):
    left = text[i - 1] if i > 0 else ""
    right = text[i + 1] if i + 1 < len(text) else ""
    return left.isdigit() or right.isdigit()


LOCK_FILE = "/tmp/doubleshift_inverting.lock"
SELECT_TIMEOUT = 0.6


def read_selection(env, selection="primary"):
    try:
        out = subprocess.check_output(
            ["xclip", "-selection", selection, "-o"],
            env=env,
            stderr=subprocess.DEVNULL,
            timeout=3,
        )
        return out.decode("utf-8", "ignore")
    except Exception:
        return ""


def type_text(text, env):
    subprocess.run(
        ["xdotool", "type", "--clearmodifiers", "--delay", "12", "--", text],
        env=env,
        stderr=subprocess.DEVNULL,
        timeout=15,
    )


def xdo(env, *keys):
    subprocess.run(
        ["xdotool", "key", "--clearmodifiers", *keys],
        env=env,
        stderr=subprocess.DEVNULL,
        timeout=5,
    )


def get_selection(env):
    return read_selection(env)


def grab_last_word(env):
    before = get_selection(env)
    xdo(env, "ctrl+shift+Left")

    deadline = time.time() + SELECT_TIMEOUT
    while time.time() < deadline:
        current = get_selection(env)
        if current and current != before:
            return current
        time.sleep(0.03)

    return None


def invert(text):
    out = []
    en = ru = 0
    for i, ch in enumerate(text):
        if ch.isdigit():
            out.append(ch)
        elif ch in NUMERIC_PUNCT and _is_numeric_context(text, i):
            out.append(ch)
        elif ch in EN_TO_RU:
            out.append(EN_TO_RU[ch])
            en += 1
        elif ch in RU_TO_EN:
            out.append(RU_TO_EN[ch])
            ru += 1
        else:
            out.append(ch)
    return "".join(out), en, ru


def find_active_display():
    """Найти дисплей, на котором сейчас активно окно пользователя.

    Резервный путь — все реальные вызовы (openbox, xbindkeys, демон) передают
    DISPLAY явно в окружении процесса. Срабатывает, только если DISPLAY не
    задан вовсе. :0 (RustDesk) проверяется первым как основной интерфейс.
    """
    displays = get_all_active_displays()
    ordered = sorted(displays, key=lambda d: 0 if d == ":0" else 1)
    for disp in ordered:
        env = x_env(disp)
        try:
            out = subprocess.check_output(["xdotool", "getactivewindow"], env=env, stderr=subprocess.DEVNULL, timeout=2)
            if out.strip():
                return disp
        except Exception:
            pass
    return ":0"


def main():
    use_selection = "--selection" in sys.argv
    if "--last-word" not in sys.argv and not use_selection:
        print("укажи --last-word или --selection")
        return 2

    target_disp = os.environ.get("DISPLAY") or find_active_display()
    env = x_env(target_disp)
    ensure_base_layout(env)

    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))

    try:
        if use_selection:
            text = get_selection(env)
            source = "выделение"
        else:
            text = grab_last_word(env)
            source = "последнее слово"

        if not text or not text.strip():
            print(f"✖ не удалось получить {source} на {target_disp} — раскладку не трогаю")
            return 1

        inverted, en_count, ru_count = invert(text)
        if en_count == 0 and ru_count == 0:
            print(f"✖ в {text} нечего инвертировать")
            return 1

        print(f"🔄 инверсия на {target_disp}: {text} → {inverted}")
        type_text(inverted, env)

        # Только тот дисплей, где реально произошла инверсия. Раньше цикл шёл
        # по get_all_active_displays() и после инверсии в RustDesk (:0) заодно
        # переключал язык в независимой RDP-сессии (:10), где ничего не менялось.
        #
        # Текст сообщения "раскладка сервера → ru/en" не менять: Mac-сторона
        # (DoubleShiftSwitcher.swift, invertLastWordOnServer) парсит его как
        # подстроку, чтобы понять, в какой язык встать самому после инверсии.
        target = "ru" if en_count >= ru_count else "en"
        with Xkb(target_disp) as xkb:
            xkb.lock_group(GROUP_BY_LANG[target])
        print(f"🌐 раскладка сервера → {target}")
        return 0
    finally:
        time.sleep(0.15)
        try:
            os.remove(LOCK_FILE)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
