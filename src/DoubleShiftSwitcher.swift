import AppKit
import ApplicationServices
import Carbon
import Darwin

// Double Shift Switcher v6.2.0 (Pure macOS Edition)
//
// Режимы работы:
// 1. Двойной Shift (без Cmd):
//    - Если текст ВЫДЕЛЕН (в любой программе) -> инвертирует выделенный фрагмент
//    - Если текст НЕ выделен -> переключает раскладку (Русский <-> Английский)
// 2. Cmd + Двойной Shift:
//    - Всегда инвертирует последнее набранное слово (независимо от того, был ли пробел)

let appVersion = "6.2.0"

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

func acquireSingleInstanceLock() {
    let path = "/tmp/double_shift_switcher.lock"
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    if fd < 0 { return }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        log("⛔️ уже запущен другой DoubleShift — выходим")
        exit(0)
    }
}

final class DoubleShiftSwitcher {
    private var lastShiftReleaseTime: TimeInterval = 0
    private var isShiftPressed = false
    private let doubleTapThreshold: TimeInterval = 0.38
    var tap: CFMachPort?

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

    private func isNumericPunctuation(_ chars: [Character], _ i: Int) -> Bool {
        guard chars[i] == "." || chars[i] == "," else { return false }
        let leftIsDigit = i > 0 && chars[i - 1].isNumber
        let rightIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
        return leftIsDigit || rightIsDigit
    }

    // MARK: - Запуск

    func start() {
        log("🚀 Double Shift Switcher v\(appVersion) starting...")

        let isTrusted = AXIsProcessTrusted()
        log("🔐 Accessibility Trusted Status: \(isTrusted)")

        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let switcher = Unmanaged<DoubleShiftSwitcher>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = switcher.tap {
                        CGEvent.tapEnable(tap: t, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                switcher.handleEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("❌ Ошибка создания EventTap.")
            return
        }

        self.tap = createdTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)

        log("✅ Double Shift Switcher v\(appVersion) готов к работе!")
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
        guard let match = selectableLayouts().first(where: { $0.lang == targetLanguage }) else { return }
        TISSelectInputSource(match.source)
        log("🌐 Раскладка -> \(targetLanguage)")
    }

    private func toggleMacLayout() {
        let layouts = selectableLayouts()
        guard layouts.count > 1 else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let currentIndex = layouts.firstIndex { $0.source == current } ?? -1
        let next = layouts[(currentIndex + 1) % layouts.count]
        TISSelectInputSource(next.source)
        log("🌐 Раскладка переключена -> \(next.lang)")
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

        let cmdPressed = flags.contains(.maskCommand)
        log("⚡️ Двойной Shift (Cmd: \(cmdPressed))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processAction(forceLastWord: cmdPressed)
        }
    }

    private func processAction(forceLastWord: Bool) {
        if forceLastWord {
            log("📝 Инверсия последнего слова (Cmd + Double Shift)")
            invertLastWord()
            return
        }

        // Проверяем, выделен ли текст в данный момент
        if let selected = getSelectedTextFast() {
            log("📝 Выделен текст '\(selected)' -> инвертирую")
            invertAndReplace(selected)
        } else {
            DispatchQueue.main.async { self.toggleMacLayout() }
        }
    }

    // MARK: - Чтение и замена текста

    private func getSelectedTextFast() -> String? {
        // 1. Accessibility API
        if let axText = selectedTextViaAccessibility(), !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return axText
        }

        // 2. Копирование через Cmd+C со сверкой changeCount
        let pb = NSPasteboard.general
        let countBefore = pb.changeCount

        postKey(virtualKey: 8, flags: [.maskCommand]) // Cmd+C
        for _ in 0..<8 {
            usleep(10_000)
            if pb.changeCount != countBefore {
                if let str = pb.string(forType: .string), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return str
                }
            }
        }
        return nil
    }

    private func selectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String, !text.isEmpty else { return nil }

        return text
    }

    private func invertLastWord() {
        // Выделяем предыдущее слово через Option + Shift + Left
        postKey(virtualKey: 123, flags: [.maskAlternate, .maskShift]) // Keycode 123 = Left Arrow
        usleep(40_000)

        // Копируем выделенное слово
        if let text = getSelectedTextFast() {
            invertAndReplace(text)
        } else {
            log("✖ Не удалось выделить слово для инверсии")
        }
    }

    private func invertAndReplace(_ text: String) {
        let sourceChars = Array(text)
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
            log("✖ В тексте '\(text)' нечего инвертировать")
            return
        }

        let inverted = String(invertedChars)
        log("🔄 Инверсия: '\(text)' -> '\(inverted)'")

        let pb = NSPasteboard.general
        // Сохраняем исходный буфер
        var savedItems: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData[type] = data
                }
            }
            if !itemData.isEmpty {
                savedItems.append(itemData)
            }
        }

        // Вставляем инвертированный текст
        pb.clearContents()
        pb.setString(inverted, forType: .string)

        postKey(virtualKey: 9, flags: [.maskCommand]) // Cmd+V
        usleep(70_000)

        // Восстанавливаем прежний буфер
        if !savedItems.isEmpty {
            pb.clearContents()
            for itemData in savedItems {
                let newItem = NSPasteboardItem()
                for (type, data) in itemData {
                    newItem.setData(data, forType: type)
                }
                pb.writeObjects([newItem])
            }
        }

        // Переключаем раскладку
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
        usleep(15_000)
    }
}

acquireSingleInstanceLock()
let switcher = DoubleShiftSwitcher()
switcher.start()
