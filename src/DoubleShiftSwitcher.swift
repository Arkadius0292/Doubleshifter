import AppKit
import ApplicationServices
import Carbon
import Darwin

// Double Shift Switcher v7.0.0 (Pure macOS All-in-One Double Shift)
//
// ЕДИНСТВЕННЫЙ ЖЕСТ ДЛЯ ВСЕГО — ДВОЙНОЙ ТАП ПО SHIFT (без дополнительных клавиш!):
//  1. Выделен текст (слово, строка, целый абзац) -> инвертирует раскладку выделенного текста и меняет язык
//  2. Курсор сразу позади слова (без пробела, например "ghbdtn|") -> инвертирует последнее слово и меняет язык
//  3. Позади курсора пробел или пусто -> просто переключает раскладку (RU <-> EN)
//  4. Буфер обмена (картинки, файлы) полностью сохраняется

let appVersion = "7.0.0"

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
        log("🚀 Double Shift Switcher v\(appVersion) (All-in-One Double Shift) starting...")

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

        log("✅ Double Shift Switcher v\(appVersion) активен и готов к работе!")
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

        log("⚡️ Двойной Shift получен")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.executeAllInOneDoubleShift()
        }
    }

    // MARK: - Главная логика All-In-One

    private func executeAllInOneDoubleShift() {
        // 1. Проверяем, есть ли УЖЕ выделенный текст (слово, фраза или абзац)
        if let alreadySelected = getAlreadySelectedText() {
            log("📝 Обнаружен выделенный текст '\(alreadySelected)' -> инвертирую")
            invertAndReplace(alreadySelected)
            return
        }

        // 2. Проверяем, есть ли слово прямо перед курсором (без пробела)
        if let wordBehind = grabWordBehindCursor() {
            log("📝 Обнаружено слово позади курсора '\(wordBehind)' -> инвертирую")
            invertAndReplace(wordBehind)
            return
        }

        // 3. Позади курсора пусто или пробел -> просто меняем раскладку
        log("🌐 Позади курсора нет слова -> переключаю раскладку")
        DispatchQueue.main.async { self.toggleMacLayout() }
    }

    // MARK: - Чтение и захват текста

    private func getAlreadySelectedText() -> String? {
        // 1. Accessibility API
        if let axText = selectedTextViaAccessibility(), !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return axText
        }

        // 2. Проверяем буфер через быстрый Cmd+C
        let pb = NSPasteboard.general
        let countBefore = pb.changeCount

        postKey(virtualKey: 8, flags: [.maskCommand]) // Cmd+C
        for _ in 0..<5 {
            usleep(8_000)
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

    private func grabWordBehindCursor() -> String? {
        let pb = NSPasteboard.general
        let countBefore = pb.changeCount

        // Нажимаем Option + Shift + Left (выделить слово влево)
        postKey(virtualKey: 123, flags: [.maskAlternate, .maskShift])
        usleep(35_000)

        // Копируем выделение через Cmd+C
        postKey(virtualKey: 8, flags: [.maskCommand])
        
        var copiedStr: String?
        for _ in 0..<8 {
            usleep(10_000)
            if pb.changeCount != countBefore {
                if let str = pb.string(forType: .string) {
                    copiedStr = str
                    break
                }
            }
        }

        guard let text = copiedStr, !text.isEmpty else {
            // Ничего не скопировалось -> снимаем случайное выделение стрелкой вправо
            postKey(virtualKey: 124, flags: [])
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Были только пробелы -> возвращаем курсор вправо
            postKey(virtualKey: 124, flags: [])
            return nil
        }

        // Проверяем, есть ли буквы для инверсии
        var hasInvertible = false
        for ch in trimmed {
            if enToRu[ch] != nil || ruToEn[ch] != nil {
                hasInvertible = true
                break
            }
        }

        if !hasInvertible {
            // Только цифры или символы без букв -> снимаем выделение
            postKey(virtualKey: 124, flags: [])
            return nil
        }

        return text
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
