import AppKit
import ApplicationServices
import Carbon
import Darwin

// Double Shift Switcher v5.1.0
//
// Что изменилось в 5.1.0:
//  - Добавлена полная поддержка Microsoft Remote Desktop, Windows App и RDP
//  - Раскладка и инверсия синхронизируются на ВСЕ активные экраны сервера (:0 для RustDesk, :10/:11 для RDP)

let appVersion = "5.1.0"

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

/// Не даём запуститься второму экземпляру: два обработчика двойного Shift
/// переключают раскладку дважды, то есть визуально не переключают вовсе.
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
    // fd намеренно не закрываем: блокировка держится, пока жив процесс.
}

final class DoubleShiftSwitcher {
    private var lastShiftReleaseTime: TimeInterval = 0
    private var isShiftPressed = false
    private let doubleTapThreshold: TimeInterval = 0.35
    var tap: CFMachPort?

    private let sshHost = "developer@169.58.127.161"
    private let sshKey = "/Users/KuleshAV/.ssh/Contabo_main6"
    private let remoteEnv = "XAUTHORITY=/home/developer/.Xauthority"

    /// Все обращения к серверу — строго по очереди и с ожиданием завершения.
    /// Иначе две команды уходят параллельно и приходят в произвольном порядке.
    private let sshQueue = DispatchQueue(label: "pro.kulesh.doubleshift.ssh")

    private let enToRu: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь", ",": "б", ".": "ю",
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н", "U": "Г", "I": "Ш", "O": "Щ", "P": "З", "{": "Х", "}": "Ъ",
        "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П", "H": "Р", "J": "О", "K": "Л", "L": "Д", ":": "Ж", "\"": "Э",
        "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И", "N": "Т", "M": "Ь", "<": "Б", ">": "Ю",
        "`": "ё", "~": "Ё", "@": "\"", "#": "№", "$": ";", "^": ":", "&": "?",
        // Русские точка и запятая набираются на клавише US "/" — без этих двух
        // пар знаки препинания в инвертированном тексте оставались латинскими.
        "/": ".", "?": ","
    ]

    private lazy var ruToEn: [Character: Character] = {
        var map = [Character: Character]()
        for (k, v) in enToRu { map[v] = k }
        return map
    }()

    /// Точка и запятая внутри числа — разделители IP, версии или дроби, а не
    /// буквы. Проверка `isNumber` защищала только сами цифры, поэтому
    /// 10.10.10.1 превращался в 10ю10ю10ю1.
    private func isNumericPunctuation(_ chars: [Character], _ i: Int) -> Bool {
        guard chars[i] == "." || chars[i] == "," else { return false }
        let leftIsDigit = i > 0 && chars[i - 1].isNumber
        let rightIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
        return leftIsDigit || rightIsDigit
    }

    // MARK: - Запуск

    func start() {
        log("🚀 Double Shift Switcher v\(appVersion) starting...")

        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log("🔐 Accessibility Trusted Status: \(AXIsProcessTrustedWithOptions(promptOptions))")

        var waitLogged = false
        while tap == nil {
            let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                    let switcher = Unmanaged<DoubleShiftSwitcher>.fromOpaque(refcon!).takeUnretainedValue()

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
                // Раньше это писалось в лог каждые 2 секунды и за сутки давало
                // тысячу строк, забивая всё остальное.
                if !waitLogged {
                    log("⚠️ Нет доступа к Accessibility. Жду выдачи прав, повтор каждые 2 секунды.")
                    waitLogged = true
                }
                Thread.sleep(forTimeInterval: 2.0)
            }
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)

        // Ловим ЛЮБУЮ смену раскладки на Маке: двойной Shift, Cmd+Space, клик
        // мышью в меню. Это единственное место, откуда сервер узнаёт о языке.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let obs = observer else { return }
                Unmanaged<DoubleShiftSwitcher>.fromOpaque(obs).takeUnretainedValue().onSystemLayoutChanged()
            },
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately
        )

        // Смена языка вне Remote Desktop на сервер не отправляется — незачем. Но при
        // возвращении в RDP / RustDesk стороны обязаны совпасть, иначе первые же
        // символы уходят не в той раскладке.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard Self.isRemoteDesktopApp(app), let lang = self.currentMacLanguage() else { return }
            log("🔗 Remote Desktop (RDP / RustDesk) в фокусе — подтягиваю раскладку сервера (\(lang))")
            self.syncServerLayout(to: lang)
        }

        log("✅ Double Shift Switcher v\(appVersion) активен")
        CFRunLoopRun()
    }

    // MARK: - Раскладка macOS

    /// Язык источника ввода по официальному свойству, а не по подстроке в ID.
    /// `com.apple.keylayout.RussianWin` содержит подстроку "us" — на этом
    /// ломался выбор английской раскладки.
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

    /// Выбираемые клавиатурные раскладки, у которых язык — русский или английский.
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
            log("⚠️ на Маке нет раскладки для языка '\(targetLanguage)'")
            return
        }
        TISSelectInputSource(match.source)
        log("🌐 раскладка Мака → \(targetLanguage) (\(sourceID(of: match.source)))")
    }

    private func toggleMacLayout() {
        let layouts = selectableLayouts()
        guard layouts.count > 1 else {
            log("⚠️ переключать нечего: активна одна раскладка")
            return
        }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let currentIndex = layouts.firstIndex { $0.source == current } ?? -1
        let next = layouts[(currentIndex + 1) % layouts.count]
        TISSelectInputSource(next.source)
        log("🌐 раскладка Мака переключена → \(next.lang) (\(sourceID(of: next.source)))")
    }

    // MARK: - Синхронизация с сервером

    @objc private func onSystemLayoutChanged() {
        guard let lang = currentMacLanguage() else { return }
        log("🌐 смена раскладки на Маке: \(lang)")

        guard isRemoteDesktopFrontmost() else { return }
        syncServerLayout(to: lang)
    }

    /// Абсолютная установка языка на сервере. Единственная команда раскладки,
    /// которая туда уходит.
    private func syncServerLayout(to language: String) {
        runRemote("\(remoteEnv) /usr/local/bin/set_server_layout.py \(language)", label: "layout=\(language)")
    }

    @discardableResult
    private func runRemote(_ command: String, label: String, wait: Bool = false) -> String {
        var output = ""
        let work = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-i", self.sshKey,
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=~/.ssh/sockets/%r@%h:%p",
                "-o", "ControlPersist=1h",
                self.sshHost,
                command
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                log("✖ ssh не запустился (\(label)): \(error.localizedDescription)")
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                log("✖ ssh \(label) завершился с кодом \(process.terminationStatus): \(output)")
            } else if !output.isEmpty {
                log("→ сервер (\(label)): \(output)")
            }
        }

        if wait {
            sshQueue.sync(execute: work)
        } else {
            sshQueue.async(execute: work)
        }
        return output
    }

    // MARK: - Определение Remote Desktop & RustDesk

    private static func isRemoteDesktopApp(_ app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        let path = app.executableURL?.path.lowercased() ?? ""
        return bundleID.contains("rustdesk") ||
               bundleID.contains("microsoft") ||
               bundleID.contains("rdc") ||
               bundleID.contains("windows app") ||
               name.contains("rustdesk") ||
               name.contains("remote desktop") ||
               name.contains("windows app") ||
               path.contains("rustdesk") ||
               path.contains("remote desktop")
    }

    /// NSWorkspace — часть AppKit и не потокобезопасна.
    private func isRemoteDesktopFrontmost() -> Bool {
        if Thread.isMainThread {
            return Self.isRemoteDesktopApp(NSWorkspace.shared.frontmostApplication)
        }
        var result = false
        DispatchQueue.main.sync {
            result = Self.isRemoteDesktopApp(NSWorkspace.shared.frontmostApplication)
        }
        return result
    }

    // MARK: - Перехват двойного Shift

    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode != 56 && keyCode != 60 {
                isShiftPressed = false
                // Между двумя тапами не должно быть других клавиш, иначе Shift
                // для заглавной буквы засчитывается как первый тап.
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
        // Читаем frontmost здесь, на главном потоке, до ухода в фон.
        let inRemoteDesktop = isRemoteDesktopFrontmost()
        log("⚡️ двойной Shift (инверсия: \(invertLastWord), Remote Desktop: \(inRemoteDesktop))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.onDoubleShiftTriggered(invertLastWord: invertLastWord, inRemoteDesktop: inRemoteDesktop)
        }
    }

    private func onDoubleShiftTriggered(invertLastWord: Bool, inRemoteDesktop: Bool) {
        guard invertLastWord else {
            // Смена раскладки Мака сама поднимет наблюдателя, а тот отправит на
            // сервер абсолютный set. Никаких дополнительных SSH отсюда.
            DispatchQueue.main.async { self.toggleMacLayout() }
            return
        }

        if inRemoteDesktop {
            invertLastWordOnServer()
        } else {
            invertLastWordLocally()
        }
    }

    // MARK: - Инверсия последнего слова

    /// Внутри RustDesk текст не покидает сервер: мост буфера обмена между
    /// клиентом 1.4.x и сервером 1.2.7 не работает, а сетевой round-trip
    /// буфера всё равно не укладывался в отведённые таймауты.
    private func invertLastWordOnServer() {
        let output = runRemote(
            "\(remoteEnv) /usr/local/bin/remote_invert_word.py --last-word",
            label: "invert",
            wait: true
        )

        // Сервер сам решает, в какую раскладку встать после инверсии. Подтягиваем
        // за ним Мак, чтобы стороны не разъехались.
        let language: String? = {
            if output.contains("раскладка сервера → ru") { return "ru" }
            if output.contains("раскладка сервера → en") { return "en" }
            return nil
        }()

        if let language = language {
            DispatchQueue.main.async { self.setMacLayout(to: language) }
        }
    }

    /// Выделенный текст через Accessibility API — без участия буфера обмена.
    ///
    /// Буфер здесь общий: его синхронизирует RustDesk в обе стороны, опрашивает
    /// каждые 0.3 с sync_mac_clipboard.py и хранит Paste.app. Прошлый вариант
    /// клал туда инвертированное слово, и оно успевало уехать на сервер, а
    /// скопированная картинка — потеряться.
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

    /// Набрать текст напрямую событиями клавиатуры, минуя буфер обмена.
    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        // CGEvent надёжно несёт короткую строку за раз, поэтому режем на куски.
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
        // 1. Пробуем взять то, что уже выделено.
        var text = selectedTextViaAccessibility()

        // 2. Ничего не выделено — выделяем последнее слово сами.
        if text == nil {
            postKey(virtualKey: 123, flags: [.maskAlternate, .maskShift]) // Option+Shift+Left
            usleep(80_000)
            text = selectedTextViaAccessibility()
        }

        guard let selected = text, !selected.isEmpty else {
            log("✖ выделение недоступно через Accessibility — раскладку не трогаю")
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
            log("✖ в '\(selected)' нечего инвертировать")
            return
        }

        let inverted = String(invertedChars)
        log("🔄 инверсия: '\(selected)' → '\(inverted)'")

        // Выделение ещё активно — первый набранный символ его заменит.
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
