import AppKit
import DocklaneCore

/// Goes to a desktop or full-screen space: focuses the window last used there (macOS
/// switches space on the way), or, for an empty desktop, presses the user's own Mission
/// Control shortcut (⌃1…, or ⌃←/⌃→ as many times as needed).
@MainActor
enum SpaceSwitcher {
    /// Returns false when there was no way to get there.
    static func go(to target: SpaceInfo) -> Bool {
        let engine = WindowEngine.shared
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        switch SpaceNavigation.move(to: target, spaces: engine.spaces, windows: engine.windowsByRecency(),
                                    shortcuts: SpaceShortcuts.parse(hotKeys)) {
        case .focus(let id):
            guard let window = engine.windows.first(where: { $0.id == id }) else { return false }
            return WindowFocuser.focus(window)
        case .press(let shortcut, let times):
            for step in 0..<times {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(step)) { press(shortcut) }
            }
            return true
        case .none:
            return target.isShown
        }
    }

    private static func press(_ shortcut: SystemShortcut) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: shortcut.modifiers)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Name for a space in the switcher's desktop strip: "Desktop 2", or the app in full screen.
    static func title(for space: SpaceInfo, windows: [DockWindow]) -> (text: String, pid: pid_t?) {
        if let number = space.desktopNumber { return (String(localized: "Desktop \(number)"), nil) }
        if let window = windows.first(where: { $0.spaceIDs.contains(space.id) }) {
            return (window.appName, window.pid)
        }
        return (String(localized: "Full Screen"), nil)
    }
}
