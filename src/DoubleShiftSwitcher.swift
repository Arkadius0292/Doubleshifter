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
    
    // RU -> EN mapping
    private lazy var ruToEn: [Character: Character] = {
        var map = [Character: Character]()
        for (k, v) in enToRu {
            map[v] = k
        }
        return map
    }()
    
    func start() {
        print("🚀 Double Shift Switcher v1.2.0 starting with Auto-Recovery...")
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
                    
                    // Auto-reenable if disabled by timeout
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
        
        print("✅ Double Shift Switcher Active 24/7!")
        fflush(stdout)
        CFRunLoopRun()
    }
    
    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode != 56 && keyCode != 60 { // 56: Left Shift, 60: Right Shift
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
                        print("⚡️ Double Shift Triggered!")
                        fflush(stdout)
                        
                        // Execute off-thread to prevent event tap timeout
                        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                            self?.onDoubleShiftTriggered()
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
    
    private func onDoubleShiftTriggered() {
        let isRustDesk = isRustDeskActive()
        let pb = NSPasteboard.general
        let oldChangeCount = pb.changeCount
        let oldContent = pb.string(forType: .string) ?? ""
        
        // 1. Send Copy shortcut
        postCopyShortcut(isRustDesk: isRustDesk)
        
        // Wait 90ms for application to process copy
        usleep(90000)
        
        let newChangeCount = pb.changeCount
        let newContent = pb.string(forType: .string) ?? ""
        
        if (newChangeCount != oldChangeCount || newContent != oldContent) && !newContent.isEmpty {
            invertSelectedTextAndSetLayout(selectedText: newContent, isRustDesk: isRustDesk)
        } else {
            toggleLayout(isRustDesk: isRustDesk)
        }
    }
    
    private func invertSelectedTextAndSetLayout(selectedText: String, isRustDesk: Bool) {
        var invertedChars = [Character]()
        var enCount = 0
        var ruCount = 0
        
        for char in selectedText {
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
            toggleLayout(isRustDesk: isRustDesk)
            return
        }
        
        let invertedText = String(invertedChars)
        print("🔄 Inverting: '\(selectedText)' -> '\(invertedText)' (RustDesk: \(isRustDesk))")
        fflush(stdout)
        
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(invertedText, forType: .string)
        
        postPasteShortcut(isRustDesk: isRustDesk)
        
        if enCount >= ruCount {
            setLayoutTo(targetLanguage: "ru", isRustDesk: isRustDesk)
        } else {
            setLayoutTo(targetLanguage: "en", isRustDesk: isRustDesk)
        }
    }
    
    private func setLayoutTo(targetLanguage: String, isRustDesk: Bool) {
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
        
        if isRustDesk {
            syncLinuxServerLayout(targetLanguage: targetLanguage)
        }
    }
    
    private func toggleLayout(isRustDesk: Bool) {
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
                let targetLang = name.lowercased.contains("ru") || name.lowercased.contains("russian") ? "ru" : "en"
                print("🌐 Toggled macOS layout to:", name)
                fflush(stdout)
                
                if isRustDesk {
                    syncLinuxServerLayout(targetLanguage: targetLang)
                }
            }
        }
    }
    
    private func syncLinuxServerLayout(targetLanguage: String) {
        DispatchQueue.global(qos: .utility).async {
            let layoutOrder = targetLanguage == "ru" ? "ru,us" : "us,ru"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-i", "/Users/KuleshAV/.ssh/Contabo_main6", "-o", "ConnectTimeout=2", "root@169.58.127.161", "sudo -u developer DISPLAY=:0 setxkbmap -layout '\(layoutOrder)'"]
            try? p.run()
        }
    }
    
    private func postCopyShortcut(isRustDesk: Bool) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyChar: CGKeyCode = 8 // 'C'
        
        if isRustDesk {
            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyChar, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyChar, keyDown: false) {
                keyDown.flags = .maskControl
                keyUp.flags = .maskControl
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        } else {
            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyChar, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyChar, keyDown: false) {
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
    
    private func postPasteShortcut(isRustDesk: Bool) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyChar: CGKeyCode = 9 // 'V'
        
        if isRustDesk {
            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyChar, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyChar, keyDown: false) {
                keyDown.flags = .maskControl
                keyUp.flags = .maskControl
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        } else {
            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyChar, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyChar, keyDown: false) {
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
}

let switcher = DoubleShiftSwitcher()
switcher.start()
