#!/usr/bin/env python3
"""Инверсия последнего слова прямо на сервере (Cmd + двойной Shift в RustDesk).

Почему инверсия делается здесь, а не на Маке: маковский путь гонял выделенный
текст через буфер обмена RustDesk, а мост буфера между клиентом 1.4.x и
сервером 1.2.7 не работает. Здесь текст не покидает сервер.

  remote_invert_word.py --last-word   выделить последнее слово и инвертировать
  remote_invert_word.py               ничего не делает (переключение раскладки
                                      живёт в set_server_layout.py)
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, "/usr/local/lib")

from doubleshift_xkb import Xkb, GROUP_BY_LANG, ensure_base_layout, x_env  # noqa: E402

EN_TO_RU = {
    'q': 'й', 'w': 'ц', 'e': 'у', 'r': 'к', 't': 'е', 'y': 'н', 'u': 'г', 'i': 'ш',
    'o': 'щ', 'p': 'з', '[': 'х', ']': 'ъ',
    'a': 'ф', 's': 'ы', 'd': 'в', 'f': 'а', 'g': 'п', 'h': 'р', 'j': 'о', 'k': 'л',
    'l': 'д', ';': 'ж', "'": 'э',
    'z': 'я', 'x': 'ч', 'c': 'с', 'v': 'м', 'b': 'и', 'n': 'т', 'm': 'ь', ',': 'б',
    '.': 'ю',
    'Q': 'Й', 'W': 'Ц', 'E': 'У', 'R': 'К', 'T': 'Е', 'Y': 'Н', 'U': 'Г', 'I': 'Ш',
    'O': 'Щ', 'P': 'З', '{': 'Х', '}': 'Ъ',
    'A': 'Ф', 'S': 'Ы', 'D': 'В', 'F': 'А', 'G': 'П', 'H': 'Р', 'J': 'О', 'K': 'Л',
    'L': 'Д', ':': 'Ж', '"': 'Э',
    'Z': 'Я', 'X': 'Ч', 'C': 'С', 'V': 'М', 'B': 'И', 'N': 'Т', 'M': 'Ь', '<': 'Б',
    '>': 'Ю',
    '`': 'ё', '~': 'Ё', '@': '"', '#': '№', '$': ';', '^': ':', '&': '?',
    # Русские точка и запятая набираются на клавише US "/" — без этих двух пар
    # знаки препинания в инвертированном тексте оставались латинскими.
    '/': '.', '?': ',',
}
RU_TO_EN = {v: k for k, v in EN_TO_RU.items()}

# Точка и запятая внутри числа — это разделители IP, версии или дроби, а не
# буквы. Баг #3 в реестре считался закрытым проверкой на цифру, но защищены
# были только сами цифры: 10.10.10.1 превращался в 10ю10ю10ю1.
NUMERIC_PUNCT = {'.', ','}


def _is_numeric_context(text, i):
    left = text[i - 1] if i > 0 else ""
    right = text[i + 1] if i + 1 < len(text) else ""
    return left.isdigit() or right.isdigit()

LOCK_FILE = "/tmp/doubleshift_inverting.lock"
SELECT_TIMEOUT = 0.6

# CLIPBOARD здесь не используется намеренно. Он общий: его синхронизирует
# RustDesk в обе стороны и туда же пишет e2ee_clipboard_receiver.py, получая
# данные с Мака. Любая запись в CLIPBOARD ради инверсии уезжала бы на Мак и
# затирала там буфер — в том числе скопированную картинку.
# PRIMARY (выделение мышью) не синхронизирует никто, поэтому читаем из него,
# а результат набираем клавишами через xdotool type.


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
    """Набрать текст клавишами. Буфер обмена не участвует.

    xdotool сам подставит нужные keycode, а для символов, которых нет в
    текущей карте, временно займёт свободный — поэтому кириллица набирается
    независимо от активной группы.
    """
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
    """Текст, выделенный мышью (X11 PRIMARY)."""
    return read_selection(env)


def grab_last_word(env):
    """Выделить последнее слово и вернуть его текст, либо None.

    Свежесть определяется сравнением с тем, что лежало в PRIMARY до выделения:
    PRIMARY хранит последнее выделение часами, и без такой сверки
    инвертировался бы случайный старый текст.
    """
    before = get_selection(env)
    xdo(env, "ctrl+shift+Left")

    deadline = time.time() + SELECT_TIMEOUT
    while time.time() < deadline:
        current = get_selection(env)
        if current and current != before:
            return current
        time.sleep(0.03)

    print("✖ выделение не попало в PRIMARY — приложение его туда не отдаёт")
    return None


def invert(text):
    """Вернуть (инвертированный текст, сколько было латиницы, сколько кириллицы)."""
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


def main():
    use_selection = "--selection" in sys.argv
    if "--last-word" not in sys.argv and not use_selection:
        print("укажи --last-word или --selection")
        return 2

    env = x_env()
    os.environ.setdefault("DISPLAY", env["DISPLAY"])
    os.environ.setdefault("XAUTHORITY", env["XAUTHORITY"])
    ensure_base_layout(env)

    # Лок читает e2ee_clipboard_receiver.py и на это время пропускает синк.
    # Сам буфер мы больше не трогаем, но лок оставлен: приёмник может писать в
    # CLIPBOARD прямо во время набора, и лишнее событие тут ни к чему.
    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))

    try:
        if use_selection:
            # Выделенное мышью живёт в PRIMARY. Режим включается отдельной
            # клавишей, а не автоматически: PRIMARY хранит последнее выделение
            # часами, и «догадаться» о свежести из скрипта нельзя.
            text = get_selection(env)
            source = "выделение"
        else:
            text = grab_last_word(env)
            source = "последнее слово"

        if not text or not text.strip():
            print(f"✖ не удалось получить {source} — раскладку не трогаю")
            return 1

        inverted, en_count, ru_count = invert(text)
        if en_count == 0 and ru_count == 0:
            print(f"✖ в '{text}' нечего инвертировать")
            return 1

        print(f"🔄 инверсия на сервере: '{text}' → '{inverted}'")

        # Выделение ещё активно — первый же набранный символ его заменит.
        type_text(inverted, env)

        # Слово было набрано не в той раскладке — переключаем на ту, в которой
        # оно теперь читается.
        target = "ru" if en_count >= ru_count else "en"
        with Xkb(env["DISPLAY"]) as xkb:
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
