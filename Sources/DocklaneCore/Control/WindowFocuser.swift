import AppKit
import ApplicationServices

/// Brings one exact window to the front, switching desktop or full-screen space if needed.
///
/// macOS 14+ silently ignores focus requests from apps that are not active (the window
/// server even reports success), so the sequence is:
/// 1. unhide the target app if it is hidden,
/// 2. activate Docklane itself — allowed because the user just clicked its panel,
/// 3. ask the window server to front the exact window and make it key (switches Space).
///    Always attempted: activation is asynchronous, so `NSApp.isActive` is often still
///    false here even though the request will be honoured,
/// 4. raise the window's Accessibility element (found even on other Spaces),
/// 5. fall back to plain app activation when the exact-window path is unavailable,
/// 6. check a moment later that the window really has focus and retry once,
/// 7. never leave Docklane holding focus.
@MainActor
public enum WindowFocuser {
    /// Returns false when the window's app is gone; the caller should then hand focus back
    /// to whichever app was in front before Docklane.
    @discardableResult
    public static func focus(_ window: DockWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
            return false
        }
        if app.isHidden { app.unhide() }

        NSApp.activate()
        if !frontWindow(window.id, pid: window.pid) {
            app.activate()
        }

        let element = AccessibilityInspector.element(for: window.id, pid: window.pid)
        if let element { raise(element) }

        // After a Space switch the window settles a moment later; confirm the exact window
        // has focus, otherwise try once more, and make sure focus moved on from Docklane.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !app.isTerminated else { return }
            if !hasFocus(window) {
                if app.isHidden { app.unhide() }
                if !frontWindow(window.id, pid: window.pid) { app.activate() }
                if let element { raise(element) }
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                app.activate()
            }
        }
        return true
    }

    private static func hasFocus(_ window: DockWindow) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
            && AccessibilityInspector.focusedWindowNumber() == window.id
    }

    /// `_SLPSSetFrontProcessWithOptions` + two synthetic event records that make the window
    /// key. Returns false if the private calls are unavailable or rejected.
    private static func frontWindow(_ number: WindowNumber, pid: pid_t) -> Bool {
        guard let setFront = PrivateSymbols.setFrontProcessWithOptions,
              let postEvent = PrivateSymbols.postEventRecordTo,
              let processForPID = PrivateSymbols.getProcessForPID else { return false }

        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFront(&psn, number, userGenerated) == .success else { return false }

        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x3A] = 0x10
        withUnsafeBytes(of: number) { bytes in
            for (offset, byte) in bytes.enumerated() { record[0x3C + offset] = byte }
        }
        for offset in 0x20..<0x30 { record[offset] = 0xFF }
        for phase: UInt8 in [0x01, 0x02] {
            record[0x08] = phase
            _ = record.withUnsafeMutableBufferPointer { postEvent(&psn, $0.baseAddress!) }
        }
        return true
    }

    private static func raise(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}
