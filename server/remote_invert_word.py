#!/usr/bin/env python3
import sys
import os
import subprocess
import time

enToRu = {
    'q': 'й', 'w': 'ц', 'e': 'у', 'r': 'к', 't': 'е', 'y': 'н', 'u': 'г', 'i': 'ш', 'o': 'щ', 'p': 'з', '[': 'х', ']': 'ъ',
    'a': 'ф', 's': 'ы', 'd': 'в', 'f': 'а', 'g': 'п', 'h': 'р', 'j': 'о', 'k': 'л', 'l': 'д', ';': 'ж', "'": 'э',
    'z': 'я', 'x': 'ч', 'c': 'с', 'v': 'м', 'b': 'и', 'n': 'т', 'm': 'ь', ',': 'б', '.': 'ю',
    'Q': 'Й', 'W': 'Ц', 'E': 'У', 'R': 'К', 'T': 'Е', 'Y': 'Н', 'U': 'Г', 'I': 'Ш', 'O': 'Щ', 'P': 'З', '{': 'Х', '}': 'Ъ',
    'A': 'Ф', 'S': 'Ы', 'D': 'В', 'F': 'А', 'G': 'П', 'H': 'Р', 'J': 'О', 'K': 'Л', 'L': 'Д', ':': 'Ж', '"': 'Э',
    'Z': 'Я', 'X': 'Ч', 'C': 'С', 'V': 'М', 'B': 'И', 'N': 'Т', 'M': 'Ь', '<': 'Б', '>': 'Ю',
    '`': 'ё', '~': 'Ё', '@': '"', '#': '№', '$': ';', '^': ':', '&': '?'
}
ruToEn = {v: k for k, v in enToRu.items()}
LOCK_FILE = "/tmp/doubleshift_inverting.lock"

def get_active_layout(env):
    try:
        out = subprocess.check_output(['setxkbmap', '-query'], env=env).decode('utf-8').splitlines()
        for line in out:
            if 'layout:' in line:
                return line.split(':')[1].strip()
    except Exception:
        pass
    return "us"

def toggle_layout(env, orig_layout):
    new_layout = 'us,ru' if orig_layout.startswith('ru') else 'ru,us'
    subprocess.run(['setxkbmap', '-layout', new_layout], env=env)
    print(f"🌐 Server layout toggled to {new_layout}")

def set_layout(target, env):
    layout = 'ru,us' if target == 'ru' else 'us,ru'
    subprocess.run(['setxkbmap', '-layout', layout], env=env)
    print(f"🌐 Server layout set to {layout}")

def get_primary_text(env):
    try:
        p = subprocess.Popen(['xclip', '-selection', 'primary', '-o'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        out, _ = p.communicate()
        return out.decode('utf-8', errors='ignore').strip()
    except Exception:
        return ""

def get_clipboard_text(env):
    try:
        p = subprocess.Popen(['xclip', '-selection', 'clipboard', '-o'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        out, _ = p.communicate()
        return out.decode('utf-8', errors='ignore').strip()
    except Exception:
        return ""

def main():
    env = dict(os.environ, DISPLAY=':0')
    invert_last_word = '--last-word' in sys.argv
    orig_layout = get_active_layout(env)

    # 1. ОБЫЧНЫЙ ДВОЙНОЙ SHIFT (Без Cmd) ➔ ТОЛЬКО СМЕНА РАСКЛАДКИ!
    if not invert_last_word:
        toggle_layout(env, orig_layout)
        return

    # 2. CMD + ДВОЙНОЙ SHIFT: ИНВЕРСИЯ ТЕКСТА
    with open(LOCK_FILE, "w") as f:
        f.write("1")

    try:
        subprocess.run(['setxkbmap', '-layout', 'us'], env=env)
        time.sleep(0.02)

        text = get_primary_text(env)

        if not text:
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+shift+Left'], env=env)
            time.sleep(0.04)
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+c'], env=env)
            time.sleep(0.06)
            text = get_clipboard_text(env)

        if not text:
            toggle_layout(env, orig_layout)
            return

        inverted = []
        en_count = 0
        ru_count = 0
        for ch in text:
            if ch in enToRu:
                inverted.append(enToRu[ch])
                en_count += 1
            elif ch in ruToEn:
                inverted.append(ruToEn[ch])
                ru_count += 1
            else:
                inverted.append(ch)

        if en_count == 0 and ru_count == 0:
            toggle_layout(env, orig_layout)
            return

        inverted_str = "".join(inverted)
        print(f"🔄 Remote Inverting: '{text}' -> '{inverted_str}'")

        # Очищаем выделенный текст кнопкой BackSpace перед вставкой, чтобы исключить дублирование!
        subprocess.run(['xdotool', 'key', '--clearmodifiers', 'BackSpace'], env=env)
        time.sleep(0.03)

        for sel in ['clipboard', 'primary']:
            p = subprocess.Popen(['xclip', '-selection', sel, '-i'], stdin=subprocess.PIPE, env=env)
            p.communicate(inverted_str.encode('utf-8'))

        subprocess.run(['xdotool', 'key', '--clearmodifiers', 'Shift+Insert'], env=env)
        time.sleep(0.04)

        target_lang = 'ru' if en_count >= ru_count else 'en'
        set_layout(target_lang, env)
        subprocess.run(['xclip', '-selection', 'primary', '/dev/null'], stderr=subprocess.DEVNULL, env=env)
    finally:
        time.sleep(0.15)
        if os.path.exists(LOCK_FILE):
            try:
                os.remove(LOCK_FILE)
            except Exception:
                pass

if __name__ == '__main__':
    main()
