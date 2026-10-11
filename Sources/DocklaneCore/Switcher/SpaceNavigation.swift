import Foundation

/// A keyboard shortcut from the system's Keyboard Shortcuts settings.
public struct SystemShortcut: Equatable, Sendable {
    public let keyCode: UInt16
    /// Modifier bits as stored by macOS (the same bits as `CGEventFlags`).
    public let modifiers: UInt64

    public init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// The Mission Control shortcuts that move between spaces, read from
/// `com.apple.symbolichotkeys` (respecting the user's own key choices and switches).
public struct SpaceShortcuts: Equatable, Sendable {
    /// "Move left a space" / "Move right a space" (⌃← / ⌃→ unless changed).
    public var left: SystemShortcut?
    public var right: SystemShortcut?
    /// "Switch to Desktop N" (⌃1 …), only those that are switched on.
    public var desktops: [Int: SystemShortcut]

    public init(left: SystemShortcut?, right: SystemShortcut?, desktops: [Int: SystemShortcut]) {
        self.left = left
        self.right = right
        self.desktops = desktops
    }

    static let leftID = 79, rightID = 81, firstDesktopID = 118
    private static let controlAndFunction: UInt64 = 0x840000

    /// Parses the `AppleSymbolicHotKeys` dictionary. Missing entries take macOS's defaults:
    /// ⌃←/⌃→ on, "Switch to Desktop N" off.
    public static func parse(_ hotKeys: [String: Any]?) -> SpaceShortcuts {
        func entry(_ id: Int, default fallback: SystemShortcut?) -> SystemShortcut? {
            guard let item = hotKeys?[String(id)] as? [String: Any] else { return fallback }
            guard (item["enabled"] as? NSNumber)?.boolValue == true else { return nil }
            guard let parameters = (item["value"] as? [String: Any])?["parameters"] as? [NSNumber],
                  parameters.count >= 3 else { return fallback }
            return SystemShortcut(keyCode: parameters[1].uint16Value, modifiers: parameters[2].uint64Value)
        }
        var desktops: [Int: SystemShortcut] = [:]
        for number in 1...16 {
            if let shortcut = entry(firstDesktopID + number - 1, default: nil) { desktops[number] = shortcut }
        }
        return SpaceShortcuts(
            left: entry(leftID, default: SystemShortcut(keyCode: 123, modifiers: controlAndFunction)),
            right: entry(rightID, default: SystemShortcut(keyCode: 124, modifiers: controlAndFunction)),
            desktops: desktops)
    }
}

/// How to get to a space. Pure, unit tested.
public enum SpaceNavigation {
    public enum Move: Equatable, Sendable {
        /// Focus this window; macOS switches to its space on the way.
        case focus(WindowNumber)
        /// Press a system shortcut this many times.
        case press(SystemShortcut, times: Int)
        /// Already there, or no way to get there.
        case none
    }

    /// - Parameter windows: windows, most recently used first.
    public static func move(to target: SpaceInfo, spaces: [SpaceInfo], windows: [DockWindow],
                            shortcuts: SpaceShortcuts) -> Move {
        // Landing on the window last used there is what clicking the space in Mission
        // Control does, and it works for full-screen spaces and other displays alike.
        if let window = windows.first(where: { $0.spaceIDs.contains(target.id) && !$0.isMinimized }) {
            return .focus(window.id)
        }
        if target.isShown { return .none }
        if let number = target.desktopNumber, let shortcut = shortcuts.desktops[number] {
            return .press(shortcut, times: 1)
        }
        let onDisplay = spaces.filter { $0.display == target.display }
        guard let from = onDisplay.firstIndex(where: \.isShown),
              let to = onDisplay.firstIndex(where: { $0.id == target.id }) else { return .none }
        let shortcut = to > from ? shortcuts.right : shortcuts.left
        guard let shortcut else { return .none }
        return .press(shortcut, times: abs(to - from))
    }
}
