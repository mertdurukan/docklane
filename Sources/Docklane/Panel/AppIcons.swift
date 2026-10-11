import AppKit

/// App icons by process id. `NSRunningApplication(processIdentifier:)` and its `icon` are
/// LaunchServices round trips; views used to ask for them on every redraw.
@MainActor
enum AppIcons {
    private static var byPID: [pid_t: NSImage] = [:]
    private static var isObserving = false

    static func icon(for pid: pid_t) -> NSImage? {
        if let icon = byPID[pid] { return icon }
        observeTerminations()
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        byPID[pid] = icon
        return icon
    }

    /// Process ids are reused: drop an app's icon when it quits.
    private static func observeTerminations() {
        guard !isObserving else { return }
        isObserving = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { byPID[pid] = nil }
            }
        }
    }
}
