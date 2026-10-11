import AppKit
import Carbon.HIToolbox
import DocklaneCore

/// Intercepts the switcher shortcut (e.g. ⌘Tab) before macOS's app switcher sees it, and the
/// keys used while the switcher is open. Every other key passes through untouched. Typed
/// characters are only read while the switcher is in search mode, to filter its list; they
/// are never stored. Needs Accessibility permission.
@MainActor
final class SwitcherKeyTap {
    /// Called inside the event tap: must stay quick. Return true to swallow the key;
    /// heavy work (focusing, quitting) is deferred by the receiver.
    var onKey: ((SwitcherCommand) -> Bool)?
    var isSwitching: () -> Bool = { false }
    var isSearching: () -> Bool = { false }

    private var trigger: CGEventFlags = .maskCommand
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    func start(_ shortcut: SwitcherShortcut) {
        stop()
        switch shortcut {
        case .off: return
        case .commandTab: trigger = .maskCommand
        case .optionTab: trigger = .maskAlternate
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<SwitcherKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                // The tap runs on the main run loop.
                let swallow = MainActor.assumeIsolated { tap.handle(type, event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
    }

    /// The trigger modifier is physically down right now (independent of delivered events).
    var isTriggerHeld: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(trigger)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        port = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            // A modifier release may have been missed while the tap was off.
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if SwitcherKeys.modifierReleased(triggerHeld: flags.contains(trigger),
                                             isOpen: isSwitching(), isSearching: isSearching()) {
                _ = onKey?(.modifierReleased)
            }
            return false
        case .flagsChanged:
            if SwitcherKeys.modifierReleased(triggerHeld: event.flags.contains(trigger),
                                             isOpen: isSwitching(), isSearching: isSearching()) {
                _ = onKey?(.modifierReleased)
            }
            return false
        case .keyDown:
            return keyDown(event)
        default:
            return false
        }
    }

    private func keyDown(_ event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isOpen = isSwitching()
        // Characters are only looked up while the switcher is open (never stored).
        let press = SwitcherKeyPress(
            special: Self.special(code),
            digit: Self.digit(code),
            character: isOpen ? KeyboardLayout.character(for: code, shift: flags.contains(.maskShift)) : nil,
            baseCharacter: isOpen ? KeyboardLayout.character(for: code, shift: false) : nil,
            text: isOpen && isSearching() ? Self.typedText(of: event) : nil,
            triggerHeld: flags.contains(trigger),
            shift: flags.contains(.maskShift),
            otherModifier: hasOtherModifiers(flags)
        )
        switch SwitcherKeys.decide(press, isOpen: isOpen, isSearching: isSearching()) {
        case .pass:
            return false
        case .swallow:
            return true
        case .handle(let command):
            // When the switcher can't open (nothing to switch to) the system shortcut works.
            return onKey?(command) ?? false
        case .releaseAndPass:
            _ = onKey?(.modifierReleased)
            return false
        }
    }

    private static func special(_ code: Int) -> SwitcherKeyPress.Special? {
        switch code {
        case kVK_Tab: .tab
        case kVK_LeftArrow: .left
        case kVK_RightArrow: .right
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        case kVK_Return, kVK_ANSI_KeypadEnter: .returnKey
        case kVK_Escape: .escape
        case kVK_Delete: .delete
        case kVK_Space: .space
        case kVK_ANSI_Grave, kVK_ISO_Section: .backquote
        default: nil
        }
    }

    private static func digit(_ code: Int) -> Int? {
        let row = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let pad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                   kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        if let index = row.firstIndex(of: code) ?? pad.firstIndex(of: code) { return index + 1 }
        return nil
    }

    /// Printable text of a key press in the current layout (any script), or nil.
    private static func typedText(of event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        let text = String(utf16CodeUnits: buffer, count: length)
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return text
    }

    /// ⌘Tab must not fire for ⌘⌥Tab etc.; Shift is allowed (it reverses direction).
    private func hasOtherModifiers(_ flags: CGEventFlags) -> Bool {
        let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        return !flags.intersection(others).subtracting(trigger).isEmpty
    }
}

/// Character a key gives on the current Latin keyboard layout (the ASCII-capable one, so
/// shortcuts still work while a Cyrillic or Arabic layout is selected).
enum KeyboardLayout {
    static func character(for keyCode: Int, shift: Bool) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifiers,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
