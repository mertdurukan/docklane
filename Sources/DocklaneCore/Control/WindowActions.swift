import AppKit
import ApplicationServices

/// Everything the window menu can do to a window or its app.
@MainActor
public enum WindowActions {
    /// macOS won't minimize a full-screen window (⌘M does nothing there), so such a window
    /// first leaves full screen, then goes to the Dock once that animation is over.
    public static func minimize(_ window: DockWindow) {
        guard let element = AccessibilityInspector.element(for: window.id, pid: window.pid) else { return }
        guard isFullScreen(element) else {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return
        }
        let screenSize = size(of: element)
        AXUIElementSetAttributeValue(element, fullScreenAttribute, kCFBooleanFalse)
        Task { @MainActor in
            // The attribute flips at once but the animation takes a moment, and a minimize
            // request during it is ignored: wait until the window has left the screen-sized
            // frame and stopped changing size (checked every 50 ms, up to 3 s).
            var last = screenSize
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(50))
                let current = size(of: element)
                if current != screenSize && current == last { break }
                last = current
            }
            for _ in 0..<3 where !AccessibilityInspector.isMinimized(element) {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        guard let value = AccessibilityInspector.copyValue(element, kAXSizeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    private static let fullScreenAttribute = "AXFullScreen" as CFString

    private static func isFullScreen(_ element: AXUIElement) -> Bool {
        (AccessibilityInspector.copyValue(element, "AXFullScreen") as? Bool) == true
    }

    /// Presses the window's close button, so the app can still ask to save.
    public static func close(_ window: DockWindow) {
        guard let element = AccessibilityInspector.element(for: window.id, pid: window.pid),
              let button = AccessibilityInspector.copyValue(element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    /// Moves and resizes the window to `frame` (Cocoa coordinates), optionally restoring it
    /// from the Dock first.
    public static func fill(_ window: DockWindow, frame: CGRect, restoreIfMinimized: Bool = false) {
        guard let element = AccessibilityInspector.element(for: window.id, pid: window.pid) else { return }
        if restoreIfMinimized && AccessibilityInspector.isMinimized(element) {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        // Accessibility positions are top-left based, measured from the main display's top.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin = CGPoint(x: frame.minX, y: mainHeight - frame.maxY)
        var size = frame.size
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    /// The window's frame in Cocoa coordinates (WindowServer bounds are top-left based).
    public static func cocoaFrame(of window: DockWindow) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: window.bounds.minX, y: mainHeight - window.bounds.maxY,
                      width: window.bounds.width, height: window.bounds.height)
    }

    public static func hideApp(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    public static func quitApp(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    /// The Dock's "New Window": bring the app forward, then send it ⌘N.
    public static func newWindow(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.activate()
        app.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            let keyN: CGKeyCode = 0x2D
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyN, keyDown: isDown) else { continue }
                event.flags = .maskCommand
                event.postToPid(pid)
            }
        }
    }

    /// Opens files with the app at `appURL`, like dropping them on its Dock icon.
    public static func open(_ files: [URL], withApplicationAt appURL: URL) {
        guard !files.isEmpty else { return }
        NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Launches (or activates) an app, e.g. a pinned app without windows.
    public static func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSApp.activate()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
