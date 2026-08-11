# Doubleshifter 🚀 (v4.0.0)

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)](https://github.com/Arkadius0292/Doubleshifter)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20(RustDesk)-blue.svg)]()

**Doubleshifter** — ультрабыстрая утилита для macOS и удалённых Linux-сессий (RustDesk), автоматизирующая смену раскладки клавиатуры (RU ↔ EN) по двойному нажатию `Shift`, а также умную инверсию раскладки текста при зажатой клавише `Cmd`.

---

## 🔥 Возможности v4.0.0

- **⚡️ 100% Чистая смена языка**: Двойной клик `Shift` переключает системную раскладку за 0.01 мс без паразитной печати букв `c` и без вмешательства в буфер обмена.
- **🔄 Умная инверсия (`Cmd` + Двойной `Shift`)**:
  - **Если текст выделен мышкой**: Инвертирует именно выделенный фрагмент (`Ghbdtn` ➔ `Привет`).
  - **Если текст не выделен**: Автоматически выделяет последнее набранное слово перед курсором и инвертирует его.
- **🧹 Нулевое дублирование (Pre-clearing BackSpace)**: Перед вставкой инвертированного текста система выполняет мгновенное стирание выделенного фрагмента, гарантируя отсутствие дубликатов вставок.
- **🖥 Гибридный движок RustDesk (Linux X11)**: При работе внутри RustDesk утилита выполняет нативную обработку на сервере Linux через SSH с использованием `xclip` и `xdotool`.
- **⚡️ Native CGEvent Engine**: Все ключевые сочетания на macOS выполняются через микросекундные системные события ядра `CGEvent`.

---

## 🛠 Архитектура

```mermaid
sequenceDiagram
    autonumber
    actor User as Пользователь
    participant Mac as DoubleShift.app (macOS)
    participant Server as Linux Server (RustDesk X11)

    User->>Mac: Двойное нажатие Shift
    alt Активно окно RustDesk?
        Mac->>Server: SSH сигнал remote_invert_word.py
        Server->>Server: X11 setxkbmap / Shift+Insert (нативно)
    else Обычное приложение macOS
        Mac->>Mac: Carbon TISSelectInputSource / CGEvent HID
    end
```

---

## 📦 Установка на macOS

```bash
git clone https://github.com/Arkadius0292/Doubleshifter.git
cd Doubleshifter
chmod +x scripts/install.sh
./scripts/install.sh
```

---

## 📄 Лицензия

Распространяется под лицензией [MIT](LICENSE).
