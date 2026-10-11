import AppKit
import ApplicationServices

/// Reads window state through the Accessibility API. All calls are synchronous IPC to other
/// apps, so each app element gets a short messaging timeout to keep a hung app from
/// stalling Docklane.
@MainActor
public enum AccessibilityInspector {
    private static let messagingTimeout: Float = 0.25

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Window number of an AX window element.
    public static func windowNumber(of element: AXUIElement) -> WindowNumber? {
        guard let getWindow = PrivateSymbols.axGetWindow else { return nil }
        var number: CGWindowID = 0
        guard getWindow(element, &number) == .success, number != 0 else { return nil }
        return number
    }

    /// The app's windows on the current Space plus its minimized windows.
    public static func windows(of pid: pid_t) -> [AXUIElement] {
        copyValue(application(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    public static func isMinimized(_ window: AXUIElement) -> Bool {
        copyValue(window, kAXMinimizedAttribute) as? Bool ?? false
    }

    /// Window numbers of minimized windows for the given apps.
    public static func minimizedWindowNumbers(of pids: Set<pid_t>) -> Set<WindowNumber> {
        var result: Set<WindowNumber> = []
        for pid in pids {
            for window in windows(of: pid) where isMinimized(window) {
                if let number = windowNumber(of: window) { result.insert(number) }
            }
        }
        return result
    }

    /// Focused window of the frontmost app.
    public static func focusedWindowNumber() -> WindowNumber? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let value = copyValue(application(app.processIdentifier), kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return windowNumber(of: value as! AXUIElement)
    }

    /// Elements found before, so the costly off-Space search runs once per window.
    private static var elementCache: [WindowNumber: (pid: pid_t, element: AXUIElement)] = [:]
    private static let elementCacheLimit = 400
    /// Total time the off-Space search may take on the main thread.
    private static let searchBudget: TimeInterval = 0.5

    /// AX element for a window. Falls back to probing the app's element ids for windows on
    /// another Space or in full screen, which `kAXWindows` leaves out. Returns nil quickly
    /// for an app that does not respond.
    public static func element(for number: WindowNumber, pid: pid_t) -> AXUIElement? {
        if let cached = elementCache[number], cached.pid == pid, windowNumber(of: cached.element) == number {
            return cached.element
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application(pid), kAXWindowsAttribute as CFString, &value)
        if result == .cannotComplete { return nil }  // hung: don't probe a thousand ids
        let listed = (value as? [AXUIElement])?.first { windowNumber(of: $0) == number }
        guard let element = listed ?? offSpaceElement(for: number, pid: pid) else { return nil }
        if elementCache.count >= elementCacheLimit { elementCache.removeAll() }
        elementCache[number] = (pid, element)
        return element
    }

    /// Builds candidate elements from remote tokens (pid, 0, "coco", element id) until one
    /// reports the wanted window number. Technique popularised by AltTab. Each candidate gets
    /// the short timeout and the whole search a time budget.
    private static func offSpaceElement(for number: WindowNumber, pid: pid_t) -> AXUIElement? {
        guard let create = PrivateSymbols.axCreateWithRemoteToken else { return nil }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636F_636F), toByteOffset: 8, as: Int32.self)
        }
        let deadline = Date().addingTimeInterval(searchBudget)
        let maximumElementID: UInt64 = 1000
        for elementID in 0..<maximumElementID {
            if elementID % 50 == 0 && Date() > deadline { return nil }
            token.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
            }
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            if windowNumber(of: element) == number { return element }
        }
        return nil
    }

    // MARK: - Small helpers

    public static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        copyValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
}
