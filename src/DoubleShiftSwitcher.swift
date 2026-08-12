import AppKit
import Carbon

class DoubleShiftSwitcher {
    private var lastShiftReleaseTime: TimeInterval = 0
    private var isShiftPressed = false
    private let doubleTapThreshold: TimeInterval = 0.35 // 350ms window
    var tap: CFMachPort? = nil
    
    // EN -> RU mapping
    private let enToRu: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь", ",": "б", ".": "ю",
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н", "U": "Г", "I": "Ш", "O": "Щ", "P": "З", "{": "Х", "}": "Ъ",
        "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П", "H": "Р", "J": "О", "K": "Л", "L": "Д", ":": "Ж", "\"": "Э",
        "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И", "N": "Т", "M": "Ь", "<": "Б", ">": "Ю",
        "`": "ё", "~": "Ё", "@": "\"", "#": "№", "$": ";", "^": ":", "&": "?"
    ]
    
    private lazy var ruToEn: [Character: Character] = {
        var map = [Character: Character]()
        for (k, v) in enToRu {
            map[v] = k
        }
        return map
    }()
    
    func start() {
        print("🚀 Double Shift Switcher v4.1.0 (Multi-Client Master Engine) starting...")
        fflush(stdout)
        
        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(promptOptions)
        print("🔐 Accessibility Trusted Status:", trusted)
        fflush(stdout)
        
        while tap == nil {
            let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
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
                print("⚠️ Waiting for Accessibility Permission... Retrying in 2 seconds.")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 2.0)
            }
        }
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)
        
        print("✅ Double Shift Switcher v4.0.0 Active 24/7!")
        fflush(stdout)
        CFRunLoopRun()
    }
    
    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode != 56 && keyCode != 60 { // Left/Right Shift
                isShiftPressed = false
            }
            return
        }
        
        if type == .flagsChanged {
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            
            if keyCode == 56 || keyCode == 60 {
                let shiftIsDown = flags.contains(.maskShift)
                
                if shiftIsDown && !isShiftPressed {
                    isShiftPressed = true
                } else if !shiftIsDown && isShiftPressed {
                    isShiftPressed = false
                    let now = Date().timeIntervalSince1970
                    if (now - lastShiftReleaseTime) <= doubleTapThreshold {
                        let invertLastWord = flags.contains(.maskCommand)
                        print("⚡️ Double Shift Triggered! (InvertMode: \(invertLastWord))")
                        fflush(stdout)
                        
                        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                            self?.onDoubleShiftTriggered(invertLastWord: invertLastWord)
                        }
                        
                        lastShiftReleaseTime = 0
                    } else {
                        lastShiftReleaseTime = now
                    }
                }
            }
        }
    }
    
    private func isRustDeskActive() -> Bool {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontApp.bundleIdentifier {
            return bundleID.lowercased().contains("rustdesk")
        }
        return false
    }
    
    private func onDoubleShiftTriggered(invertLastWord: Bool) {
        if !invertLastWord {
            // 1. Обычный Double Shift (Смена языка): переключаем на Маке и синхронизируем сервер
            toggleMacLayout()
            if isRustDeskActive() {
                executeRemoteLayoutToggle()
            }
        } else {
            // 2. Cmd + Double Shift (Инверсия слова/текста): используем 100% нативный Mac CGEvent движок!
            executeNativeMacInverter(invertLastWord: true)
        }
    }
    
    private func executeRemoteLayoutToggle() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-i", "/Users/KuleshAV/.ssh/Contabo_main6",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=~/.ssh/sockets/%r@%h:%p",
            "-o", "ControlPersist=1h",
            "developer@169.58.127.161",
            "su - developer -c 'DISPLAY=:0 /usr/local/bin/remote_invert_word.py'"
        ]
        try? p.run()
    }
    
    private func executeRemoteInverter(invertLastWord: Bool) {
        let arg = invertLastWord ? "--last-word" : ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-i", "/Users/KuleshAV/.ssh/Contabo_main6",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=~/.ssh/sockets/%r@%h:%p",
            "-o", "ControlPersist=1h",
            "developer@169.58.127.161",
            "/usr/local/bin/remote_invert_word.py \(arg)"
        ]
        try? p.run()
    }
    
    private func executeNativeMacInverter(invertLastWord: Bool) {
        if !invertLastWord {
            toggleMacLayout()
            return
        }
        
        let pb = NSPasteboard.general
        let oldChangeCount = pb.changeCount
        
        // 1. Копируем выделенный мышкой текст через мгновенный CGEvent (Cmd+C)
        postNativeKeyCombination(virtualKey: 8, flags: [.maskCommand]) // Cmd+C
        usleep(40000)
        
        var textToInvert: String? = nil
        if pb.changeCount != oldChangeCount, let copied = pb.string(forType: .string), !copied.isEmpty {
            textToInvert = copied
        } else {
            // 2. Если текст не был выделен мышкой - выделяем последнее слово (Option+Shift+LeftArrow)
            postNativeKeyCombination(virtualKey: 123, flags: [.maskAlternate, .maskShift]) // Option+Shift+Left
            usleep(40000)
            postNativeKeyCombination(virtualKey: 8, flags: [.maskCommand]) // Cmd+C
            usleep(60000)
            textToInvert = pb.string(forType: .string)
        }
        
        if let text = textToInvert, !text.isEmpty {
            invertSelectedTextAndSetLayout(selectedText: text)
        } else {
            toggleMacLayout()
        }
    }
    
    private func invertSelectedTextAndSetLayout(selectedText: String) {
        var invertedChars = [Character]()
        var enCount = 0
        var ruCount = 0
        
        for char in selectedText {
            if char.isNumber {
                invertedChars.append(char)
                continue
            }
            if let ruChar = enToRu[char] {
                invertedChars.append(ruChar)
                enCount += 1
            } else if let enChar = ruToEn[char] {
                invertedChars.append(enChar)
                ruCount += 1
            } else {
                invertedChars.append(char)
            }
        }
        
        if enCount == 0 && ruCount == 0 {
            toggleMacLayout()
            if isRustDeskActive() {
                executeRemoteLayoutToggle()
            }
            return
        }
        
        let invertedText = String(invertedChars)
        print("🔄 Inverting Mac Native: '\(selectedText)' -> '\(invertedText)'")
        fflush(stdout)
        
        // Удаляем выделенный фрагмент текста кнопкой BackSpace перед вставкой!
        postNativeKeyCombination(virtualKey: 51, flags: []) // BackSpace
        usleep(20000)
        
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(invertedText, forType: .string)
        
        postNativeKeyCombination(virtualKey: 9, flags: [.maskCommand]) // Cmd+V
        
        let targetLang = enCount >= ruCount ? "ru" : "en"
        setMacLayoutTo(targetLanguage: targetLang)
        if isRustDeskActive() {
            executeRemoteLayoutToggle()
        }
    }
    
    private func postNativeKeyCombination(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cghidEventTap)
        }
        usleep(15000)
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cghidEventTap)
        }
    }
    
    private func setMacLayoutTo(targetLanguage: String) {
        guard let inputSourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        
        for source in inputSourceList {
            let category = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory)
            let isSelectable = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            let sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            
            if let cat = category, unsafeBitCast(cat, to: CFString.self) == kTISCategoryKeyboardInputSource,
               let sel = isSelectable, unsafeBitCast(sel, to: CFBoolean.self) == kCFBooleanTrue,
               let sID = sourceID {
                let idStr = unsafeBitCast(sID, to: NSString.self).lowercased
                if targetLanguage == "ru" && (idStr.contains("ru") || idStr.contains("russian")) {
                    TISSelectInputSource(source)
                    print("🌐 Set macOS layout to Russian")
                    fflush(stdout)
                    break
                } else if targetLanguage == "en" && (idStr.contains("abc") || idStr.contains("us") || idStr.contains("english")) {
                    TISSelectInputSource(source)
                    print("🌐 Set macOS layout to English")
                    fflush(stdout)
                    break
                }
            }
        }
    }
    
    private func toggleMacLayout() {
        guard let inputSourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        let currentSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        
        var selectableSources: [TISInputSource] = []
        for source in inputSourceList {
            let category = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory)
            let isSelectable = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            if let cat = category, unsafeBitCast(cat, to: CFString.self) == kTISCategoryKeyboardInputSource,
               let sel = isSelectable, unsafeBitCast(sel, to: CFBoolean.self) == kCFBooleanTrue {
                selectableSources.append(source)
            }
        }
        
        if selectableSources.count > 1 {
            if let currentIndex = selectableSources.firstIndex(where: { $0 == currentSource }) {
                let nextIndex = (currentIndex + 1) % selectableSources.count
                let nextSource = selectableSources[nextIndex]
                TISSelectInputSource(nextSource)
                
                let sourceID = TISGetInputSourceProperty(nextSource, kTISPropertyInputSourceID)
                let name = unsafeBitCast(sourceID, to: NSString.self)
                print("🌐 Toggled macOS layout to:", name)
                fflush(stdout)
            }
        }
    }
}

let switcher = DoubleShiftSwitcher()
switcher.start()
