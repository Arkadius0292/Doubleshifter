import AppKit
import ApplicationServices
import Carbon
import Darwin

// Double Shift Switcher v6.0.0 (Pure macOS Edition)
//
// 100% локальная утилита для macOS без удалённых серверов и сетевых зависимостей:
//  - Двойной тап по клавише Shift -> мгновенное переключение раскладки (Русский <-> Английский)
//  - Cmd + Двойной Shift -> инверсия регистра и раскладки последнего слова / выделения
//  - Защита IP-адресов и чисел от мутации
//  - Автовосстановление EventTap при сбросе macOS
//  - Защита от дублирующих инстансов через flock

let appVersion = "6.0.0"

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

/// Не даём запуститься второму экземпляру
func acquireSingleInstanceLock() {
    let path = "/tmp/double_shift_switcher.lock"
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    if fd < 0 {
        log("⚠️ не открывается \(path) — защита от второго инстанса выключена")
        return
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        log("⛔️ уже запущен другой DoubleShift — выходим")
        exit(0)
    }
}

final class DoubleShiftSwitcher {
    private var lastShiftReleaseTime: TimeInterval = 0
    private var isShiftPressed = false
    private let doubleTapThreshold: TimeInterval = 0.35
    var tap: CFMachPort?
    private var watchdogTimer: Timer?

    private let enToRu: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь", ",": "б", ".": "ю",
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н", "U": "Г", "I": "Ш", "O": "Щ", "P": "З", "{": "Х", "}": "Ъ",
        "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П", "H": "Р", "J": "О", "K": "Л", "L": "Д", ":": "Ж", "\"": "Э",
        "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И", "N": "Т", "M": "Ь", "<": "Б", ">": "Ю",
        "`": "ё", "~": "Ё", "@": "\"", "#": "№", "$": ";", "^": ":", "&": "?",
        "/": ".", "?": ","
    ]

    private lazy var ruToEn: [Character: Character] = {
        var map = [Character: Character]()
        for (k, v) in enToRu { map[v] = k }
        return map
    }()

    /// Точка и запятая внутри числа — разделители IP, версии или дроби, а не буквы
    private func isNumericPunctuation(_ chars: [Character], _ i: Int) -> Bool {
        guard chars[i] == "." || chars[i] == "," else { return false }
        let leftIsDigit = i > 0 && chars[i - 1].isNumber
        let rightIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
        return leftIsDigit || rightIsDigit
    }

    // MARK: - Запуск

    func start() {
        log("🚀 Double Shift Switcher v\(appVersion) (Pure macOS) starting...")

        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(promptOptions)
        log("🔐 Accessibility Trusted Status: \(isTrusted)")

        var waitLogged = false
        while tap == nil {
            let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(eventMask),
                callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                    let switcher = Unmanaged<DoubleShiftSwitcher>.fromOpaque(refcon).takeUnretainedValue()

                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        log("⚠️ Event tap отключен macOS (\(type.rawValue)), восстанавливаю...")
                        if let t = switcher.tap {
                            CGEvent.tapEnable(tap: t, enable: true)
                        }
                        return Unmanaged.passUnretained(event)
                    }

                    switcher.handleEvent(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )

            if tap == nil {
                if !waitLogged {
                    log("⚠️ Нет доступа к Accessibility. Ожидаю выдачи прав...")
                    waitLogged = true
                }
                Thread.sleep(forTimeInterval: 2.0)
            }
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)

        // Сторожевой таймер: каждые 5 секунд проверяем, активен ли event tap
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, let t = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: t) {
                log("⚡️ Watchdog: Event tap был выключен, включаю обратно")
                CGEvent.tapEnable(tap: t, enable: true)
            }
        }

        log("✅ Double Shift Switcher v\(appVersion) активен")
        CFRunLoopRun()
    }

    // MARK: - Раскладка macOS

    private func primaryLanguage(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        guard let languages = unsafeBitCast(raw, to: NSArray.self) as? [String] else { return nil }
        guard let first = languages.first?.lowercased() else { return nil }
        if first.hasPrefix("ru") { return "ru" }
        if first.hasPrefix("en") { return "en" }
        return first
    }

    private func sourceID(of source: TISInputSource) -> String {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "?" }
        return unsafeBitCast(raw, to: NSString.self) as String
    }

    private func selectableLayouts() -> [(source: TISInputSource, lang: String)] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }

        var result: [(TISInputSource, String)] = []
        for source in list {
            guard let categoryRaw = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory),
                  unsafeBitCast(categoryRaw, to: CFString.self) == kTISCategoryKeyboardInputSource,
                  let selectableRaw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable),
                  unsafeBitCast(selectableRaw, to: CFBoolean.self) == kCFBooleanTrue,
                  let lang = primaryLanguage(of: source),
                  lang == "ru" || lang == "en"
            else { continue }
            result.append((source, lang))
        }
        return result
    }

    private func currentMacLanguage() -> String? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return primaryLanguage(of: current)
    }

    private func setMacLayout(to targetLanguage: String) {
        guard currentMacLanguage() != targetLanguage else { return }
        guard let match = selectableLayouts().first(where: { $0.lang == targetLanguage }) else {
            log("⚠️ На Маке нет раскладки для языка '\(targetLanguage)'")
            return
        }
        TISSelectInputSource(match.source)
        log("🌐 Раскладка Мака -> \(targetLanguage) (\(sourceID(of: match.source)))")
    }

    private func toggleMacLayout() {
        let layouts = selectableLayouts()
        guard layouts.count > 1 else {
            log("⚠️ Переключать нечего: активна только одна раскладка")
            return
        }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let currentIndex = layouts.firstIndex { $0.source == current } ?? -1
        let next = layouts[(currentIndex + 1) % layouts.count]
        TISSelectInputSource(next.source)
        log("🌐 Раскладка переключена -> \(next.lang) (\(sourceID(of: next.source)))")
    }

    // MARK: - Перехват двойного Shift

    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode != 56 && keyCode != 60 {
                isShiftPressed = false
                lastShiftReleaseTime = 0
            }
            return
        }

        guard type == .flagsChanged else { return }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 56 || keyCode == 60 else { return }

        let shiftIsDown = flags.contains(.maskShift)
        if shiftIsDown && !isShiftPressed {
            isShiftPressed = true
            return
        }
        guard !shiftIsDown && isShiftPressed else { return }

        isShiftPressed = false
        let now = Date().timeIntervalSince1970
        guard (now - lastShiftReleaseTime) <= doubleTapThreshold else {
            lastShiftReleaseTime = now
            return
        }
        lastShiftReleaseTime = 0

        let invertLastWord = flags.contains(.maskCommand)
        log("⚡️ Двойной Shift (инверсия: \(invertLastWord))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.onDoubleShiftTriggered(invertLastWord: invertLastWord)
        }
    }

    private func onDoubleShiftTriggered(invertLastWord: Bool) {
        if invertLastWord {
            invertLastWordLocally()
        } else {
            DispatchQueue.main.async { self.toggleMacLayout() }
        }
    }

    // MARK: - Инверсия последнего слова на Mac

    private func selectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef else { return nil }

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedRef
        ) == .success, let text = selectedRef as? String, !text.isEmpty else { return nil }

        return text
    }

    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        let chunkSize = 16

        for start in stride(from: 0, to: units.count, by: chunkSize) {
            let chunk = Array(units[start..<min(start + chunkSize, units.count)])
            for isDown in [true, false] {
                guard let event = CGEvent(
                    keyboardEventSource: source, virtualKey: 0, keyDown: isDown
                ) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            usleep(6_000)
        }
    }

    private func invertLastWordLocally() {
        // 1. Пробуем взять выделенный текст
        var text = selectedTextViaAccessibility()

        // 2. Если ничего не выделено — выделяем последнее слово через Option+Shift+Left
        if text == nil {
            postKey(virtualKey: 123, flags: [.maskAlternate, .maskShift])
            usleep(80_000)
            text = selectedTextViaAccessibility()
        }

        guard let selected = text, !selected.isEmpty else {
            log("✖ Выделение недоступно через Accessibility")
            return
        }

        let sourceChars = Array(selected)
        var invertedChars = [Character]()
        var enCount = 0
        var ruCount = 0
        for (index, char) in sourceChars.enumerated() {
            if char.isNumber || isNumericPunctuation(sourceChars, index) {
                invertedChars.append(char)
            } else if let ru = enToRu[char] {
                invertedChars.append(ru)
                enCount += 1
            } else if let en = ruToEn[char] {
                invertedChars.append(en)
                ruCount += 1
            } else {
                invertedChars.append(char)
            }
        }

        guard enCount > 0 || ruCount > 0 else {
            log("✖ В '\(selected)' нечего инвертировать")
            return
        }

        let inverted = String(invertedChars)
        log("🔄 Инверсия: '\(selected)' -> '\(inverted)'")

        typeText(inverted)
        usleep(60_000)

        let targetLanguage = enCount >= ruCount ? "ru" : "en"
        DispatchQueue.main.async { self.setMacLayout(to: targetLanguage) }
    }

    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cghidEventTap)
        }
        usleep(15_000)
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cghidEventTap)
        }
    }
}

acquireSingleInstanceLock()
let switcher = DoubleShiftSwitcher()
switcher.start()
