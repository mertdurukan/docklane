import AppKit
import ApplicationServices
import DocklaneCore

/// Subscribes to Accessibility notifications of every regular app, so the engine learns about
/// new, closed, minimized, retitled, moved and focused windows as they happen instead of
/// polling for them.
@MainActor
final class AppEventWatcher {
    enum Event {
        /// Windows appeared, disappeared, were minimized/restored or retitled.
        case windowsChanged
        case focusChanged
        /// A window of `pid` was moved or resized.
        case geometryChanged(pid: pid_t)
    }

    private let onEvent: (Event) -> Void
    private var observers: [pid_t: AXObserver] = [:]

    private static let notifications: [String] = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    /// Watches every running regular app and drops apps that quit.
    func sync() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
        let running = Set(apps.map(\.processIdentifier))
        for pid in observers.keys where !running.contains(pid) {
            unwatch(pid)
        }
        for app in apps where observers[app.processIdentifier] == nil {
            watch(app.processIdentifier)
        }
    }

    func unwatchAll() {
        for pid in Array(observers.keys) { unwatch(pid) }
    }

    private func watch(_ pid: pid_t) {
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let observer = created else { return }
        // Short timeout: registering is IPC, and a hung app would otherwise block for seconds
        // per notification.
        let appElement = AccessibilityInspector.application(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.notifications {
            // Some apps don't support every notification; that's fine. A hung app is not
            // asked again for each one.
            if AXObserverAddNotification(observer, appElement, notification as CFString, refcon) == .cannotComplete {
                break
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func unwatch(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func handle(_ notification: String, pid: pid_t) {
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            onEvent(.focusChanged)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            onEvent(.geometryChanged(pid: pid))
        default:
            onEvent(.windowsChanged)
        }
    }

    /// C callback; observers are scheduled on the main run loop, so this runs on the main thread.
    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let name = notification as String
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let watcher = Unmanaged<AppEventWatcher>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated {
            watcher.handle(name, pid: pid)
        }
    }
}
