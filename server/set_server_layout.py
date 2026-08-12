#!/usr/bin/env python3
"""Абсолютная установка языка серверной раскладки.

Единственная точка синхронизации раскладки Mac -> сервер. Идемпотентна: если
язык уже нужный, ничего не делает. Абсолютная установка (в отличие от toggle)
самовосстанавливается — потерянная или продублированная команда не уводит
сервер в противофазу с Маком.

  set_server_layout.py ru        установить русский
  set_server_layout.py en        установить английский
  set_server_layout.py --toggle  переключить на противоположный
  set_server_layout.py --get     вывести текущий язык
"""

import sys

sys.path.insert(0, "/usr/local/lib")

from doubleshift_xkb import current_lang, set_lang, toggle_lang, x_env  # noqa: E402


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "en"
    env = x_env()

    if arg in ("--get", "-g"):
        print(current_lang(env))
        return 0

    if arg in ("--toggle", "-t"):
        try:
            print(f"🌐 раскладка сервера → {toggle_lang(env)}")
            return 0
        except Exception as exc:
            print(f"✖ не удалось переключить раскладку: {exc}", file=sys.stderr)
            return 1

    try:
        changed, before, after = set_lang(arg, env)
    except Exception as exc:
        print(f"✖ не удалось сменить раскладку: {exc}", file=sys.stderr)
        return 1

    if changed:
        print(f"🌐 раскладка сервера {before} → {after}")
    else:
        print(f"🌐 раскладка сервера уже {after}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
