import AppKit
import ApplicationServices
import Carbon
import Darwin

// Double Shift Switcher v7.1.1 (Pure macOS All-in-One Double Shift)
//
// СТРОГО ОДИН ДВОЙНОЙ ТАП ПО КЛАВИШЕ SHIFT (без дополнительных клавиш!):
//  1. Выделен текст (слово, строка, целый абзац) -> инвертирует выделенный текст и меняет раскладку
//  2. Курсор сразу позади слова (без пробела, например "ghbdtn|") -> инвертирует последнее слово и меняет раскладку
//  3. Позади курсора пробел или пусто -> просто переключает раскладку (RU <-> EN)
//  4. Буфер обмена (картинки, файлы) полностью сохраняется

let appVersion = "7.1.1"

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
    private let doubleTapThreshold: TimeInterval = 0.45
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

        var waitLogged = false
        while tap == nil {
            let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
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
            )

            if tap == nil {
                if !waitLogged {
                    log("⚠️ Ожидаю включения тумблера DoubleShift в 'Системные настройки -> Универсальный доступ'...")
                    waitLogged = true
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap!, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)

        log("✅ Double Shift Switcher v\(appVersion) активен и готов к работе!")
        CFRunLoopRun()
    }

    // MARK: - Раскладка macOS

    private func selectableLayouts() -> [(source: TISInputSource, lang: String)] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }

        var result: [(TISInputSource, String)] = []
        for source in list {
            guard let categoryRaw = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory),
                  unsafeBitCast(categoryRaw, to: CFString.self) == kTISCategoryKeyboardInputSource,
                  let selectableRaw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable),
                  unsafeBitCast(selectableRaw, to: CFBoolean.self) == kCFBooleanTrue,
                  let idRaw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            else { continue }
            let id = unsafeBitCast(idRaw, to: NSString.self) as String
            if id == "com.apple.keylayout.ABC" {
                result.append((source, "en"))
            } else if id.contains("Russian") {
                result.append((source, "ru"))
            }
        }
        return result
    }

    private func currentMacLanguage() -> String? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let idRaw = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return nil }
        let id = unsafeBitCast(idRaw, to: NSString.self) as String
        if id == "com.apple.keylayout.ABC" { return "en" }
        if id.contains("Russian") { return "ru" }
        return nil
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
        let currentIdRaw = TISGetInputSourceProperty(current, kTISPropertyInputSourceID)
        let currentId = currentIdRaw != nil ? (unsafeBitCast(currentIdRaw, to: NSString.self) as String) : ""

        if let other = layouts.first(where: {
            let otherIdRaw = TISGetInputSourceProperty($0.source, kTISPropertyInputSourceID)
            let otherId = otherIdRaw != nil ? (unsafeBitCast(otherIdRaw, to: NSString.self) as String) : ""
            return otherId != currentId
        }) {
            TISSelectInputSource(other.source)
            log("🌐 Раскладка переключена -> \(other.lang)")
        }
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
        let elapsed = now - lastShiftReleaseTime

        if elapsed <= doubleTapThreshold {
            lastShiftReleaseTime = 0
            log("⚡️ Двойной Shift пойман (интервал: \(String(format: "%.2f", elapsed)) с)")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.executeAllInOneDoubleShift()
            }
        } else {
            lastShiftReleaseTime = now
        }
    }

    // MARK: - Главная логика All-In-One

    private func executeAllInOneDoubleShift() {
        // 1. Проверяем, есть ли УЖЕ выделенный текст (слово, фраза или целый абзац)
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
            postKey(virtualKey: 124, flags: [])
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            postKey(virtualKey: 124, flags: [])
            return nil
        }

        var hasInvertible = false
        for ch in trimmed {
            if enToRu[ch] != nil || ruToEn[ch] != nil {
                hasInvertible = true
                break
            }
        }

        if !hasInvertible {
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

        pb.clearContents()
        pb.setString(inverted, forType: .string)

        postKey(virtualKey: 9, flags: [.maskCommand]) // Cmd+V
        usleep(70_000)

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
