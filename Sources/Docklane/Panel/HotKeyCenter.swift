import AppKit
import Carbon.HIToolbox

/// Global shortcuts (Carbon hot keys: no extra permission needed).
@MainActor
final class HotKeyCenter {
    enum Slot: UInt32 {
        /// Show / hide the panel (turns auto-hide on or off).
        case toggleHiding = 1
        /// Open the panel for keyboard navigation.
        case navigate = 2
    }

    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x444B_4C4E) // "DKLN"

    private init() {}

    func register(_ choice: HotKeyChoice, for slot: Slot, action: @escaping () -> Void) {
        unregister(slot)
        actions[slot.rawValue] = action
        guard let (keyCode, modifiers) = Self.keys(for: choice) else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        if RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            hotKeys[slot.rawValue] = ref
        }
    }

    private func unregister(_ slot: Slot) {
        unregister(id: slot.rawValue)
    }

    /// A fixed shortcut under a free `id` (100 and up; the slots above use small numbers).
    /// Returns false when macOS refused it (another app already has the combination).
    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        actions[id] = action
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }
        hotKeys[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        actions[id] = nil
        if let ref = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let center = Unmanaged<HotKeyCenter>.fromOpaque(refcon).takeUnretainedValue()
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { center.fire(id) }
            return noErr
        }, 1, &eventType, refcon, &handler)
    }

    private static func keys(for choice: HotKeyChoice) -> (UInt32, UInt32)? {
        switch choice {
        case .none: return nil
        case .controlOptionD: return (UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey))
        case .controlOptionK: return (UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey))
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionCommandP: return (UInt32(kVK_ANSI_P), UInt32(optionKey | cmdKey))
        }
    }
}
