import AppKit
import Carbon.HIToolbox

/// Intercepts the switcher shortcut (e.g. ⌘Tab) before macOS's app switcher sees it, and the
/// keys used while the switcher is open. Every other key passes through untouched. Typed
/// characters are only read while the switcher is in search mode, to filter its list; they
/// are never stored. Needs Accessibility permission.
@MainActor
final class SwitcherKeyTap {
    enum Key {
        case next, previous, left, right, up, down
        case confirm, cancel
        case quitApp, hideApp, closeWindow, minimizeWindow
        case beginSearch
        case character(String)
        case backspace
        /// The modifier (⌘ or ⌥) was released.
        case modifierReleased
    }

    /// Return true to swallow the key.
    var onKey: ((Key) -> Bool)?
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

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        port = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .flagsChanged:
            if isSwitching() && !event.flags.contains(trigger) {
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
        let backward = flags.contains(.maskShift)

        if code == kVK_Tab && flags.contains(trigger) && !hasOtherModifiers(flags) {
            return onKey?(backward ? .previous : .next) ?? false
        }
        guard isSwitching() else { return false }

        switch code {
        case kVK_Tab: return send(backward ? .previous : .next)
        case kVK_LeftArrow: return send(.left)
        case kVK_RightArrow: return send(.right)
        case kVK_UpArrow: return send(.up)
        case kVK_DownArrow: return send(.down)
        case kVK_Return, kVK_ANSI_KeypadEnter: return send(.confirm)
        case kVK_Escape: return send(.cancel)
        default: break
        }

        if isSearching() {
            if code == kVK_Delete { return send(.backspace) }
            if let text = Self.characters(of: event) { return send(.character(text)) }
            return true
        }

        switch code {
        case kVK_Space: return send(.confirm)
        case kVK_ANSI_Slash: return send(.beginSearch)
        case kVK_ANSI_Q: return send(.quitApp)
        case kVK_ANSI_H: return send(.hideApp)
        case kVK_ANSI_W: return send(.closeWindow)
        case kVK_ANSI_M: return send(.minimizeWindow)
        default: return true // swallow stray keys while the switcher is open
        }
    }

    private func send(_ key: Key) -> Bool {
        onKey?(key) ?? true
    }

    /// Printable characters of a key press (layout-aware), or nil.
    private static func characters(of event: CGEvent) -> String? {
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
