import Foundation

/// What a key press means to the window switcher.
public enum SwitcherCommand: Equatable, Sendable {
    case next, previous, left, right, up, down
    case confirm, cancel
    case quitApp, hideApp, closeWindow, minimizeWindow
    case beginSearch
    case character(String)
    case backspace
    /// The modifier (⌘ or ⌥) was released.
    case modifierReleased
}

/// One key press, reduced to what the switcher needs. Characters come from the keyboard
/// layout (not the key's position), so shortcuts work on Turkish, AZERTY, Dvorak, ….
public struct SwitcherKeyPress: Equatable, Sendable {
    public enum Special: Equatable, Sendable {
        case tab, left, right, up, down, returnKey, escape, delete, space
    }

    public var special: Special?
    /// Character the key gives on the current Latin layout with the Shift state held.
    public var character: String?
    /// The same key without Shift, for letter shortcuts.
    public var baseCharacter: String?
    /// Text typed in the current layout (any script), for search.
    public var text: String?
    /// The switcher's modifier (⌘ or ⌥) is held.
    public var triggerHeld: Bool
    public var shift: Bool
    /// A modifier other than the trigger and Shift (⌃, or ⌥/⌘ when not the trigger) is held.
    public var otherModifier: Bool

    public init(special: Special? = nil, character: String? = nil, baseCharacter: String? = nil,
                text: String? = nil, triggerHeld: Bool, shift: Bool = false, otherModifier: Bool = false) {
        self.special = special
        self.character = character
        self.baseCharacter = baseCharacter
        self.text = text
        self.triggerHeld = triggerHeld
        self.shift = shift
        self.otherModifier = otherModifier
    }
}

/// Decides, synchronously inside the event tap, whether a key is swallowed and what it does.
/// Pure, unit tested.
public enum SwitcherKeys {
    public enum Decision: Equatable, Sendable {
        /// Let the key through to the frontmost app.
        case pass
        /// Swallow it and do nothing.
        case swallow
        /// Swallow it and run the command.
        case handle(SwitcherCommand)
        /// The modifier was released without us seeing it: switch, and let the key through.
        case releaseAndPass
    }

    public static func decide(_ key: SwitcherKeyPress, isOpen: Bool, isSearching: Bool) -> Decision {
        if key.special == .tab && key.triggerHeld && !key.otherModifier {
            return .handle(key.shift ? .previous : .next)
        }
        guard isOpen else { return .pass }

        switch key.special {
        case .tab: return .handle(key.shift ? .previous : .next)
        case .left: return .handle(.left)
        case .right: return .handle(.right)
        case .up: return .handle(.up)
        case .down: return .handle(.down)
        case .returnKey: return .handle(.confirm)
        case .escape: return .handle(.cancel)
        default: break
        }

        if isSearching {
            if key.special == .delete { return .handle(.backspace) }
            if let text = key.text, !text.isEmpty { return .handle(.character(text)) }
            return .swallow
        }

        // The modifier is no longer down: the release event was missed (tap timeout).
        guard key.triggerHeld else { return .releaseAndPass }
        guard !key.otherModifier else { return .swallow }

        if key.special == .space { return .handle(.confirm) }
        if key.character == "/" { return .handle(.beginSearch) }
        switch key.baseCharacter?.lowercased() {
        case "q": return .handle(.quitApp)
        case "h": return .handle(.hideApp)
        case "w": return .handle(.closeWindow)
        case "m": return .handle(.minimizeWindow)
        default: return .swallow // stray keys while the switcher is open
        }
    }

    /// A modifier change (or a tap that was re-enabled after a timeout) with the trigger up
    /// ends switching, unless the user is typing a search.
    public static func modifierReleased(triggerHeld: Bool, isOpen: Bool, isSearching: Bool) -> Bool {
        isOpen && !isSearching && !triggerHeld
    }
}
