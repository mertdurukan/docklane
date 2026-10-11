import CoreGraphics

/// Running apps with no window, shown in the window switcher like the macOS app switcher does
/// (an app whose last window was closed, Xcode without a project, Keychain Access before its
/// window opens). Each is a stand-in `DockWindow` with an id no real window can have.
public extension DockWindow {
    /// Window numbers are small; the top bit marks a stand-in for an app without windows.
    private static let appMarker: WindowNumber = 0x8000_0000

    static func appWithoutWindows(pid: pid_t, bundleID: String, appName: String) -> DockWindow {
        DockWindow(id: appMarker | WindowNumber(truncatingIfNeeded: pid), pid: pid, bundleID: bundleID, appName: appName,
                   title: "", bounds: .zero, isOnScreen: false, isMinimized: false)
    }

    /// A stand-in for a running app that has no window (nothing to capture, close or minimize).
    var isAppWithoutWindows: Bool { id & Self.appMarker != 0 }
}

/// Pure, unit tested.
public enum WindowlessApps {
    public struct App: Sendable {
        public let pid: pid_t
        public let bundleID: String
        public let name: String

        public init(pid: pid_t, bundleID: String, name: String) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
        }
    }

    /// Finder always runs (it draws the desktop), so without a window it is not listed.
    public static let alwaysRunning: Set<String> = ["com.apple.finder"]

    /// Stand-ins for `apps` that own none of `windows`, most recently activated first
    /// (`recentPIDs`), the rest by name.
    public static func standIns(apps: [App], windows: [DockWindow], recentPIDs: [pid_t]) -> [DockWindow] {
        let withWindows = Set(windows.map(\.pid))
        let rank = Dictionary(recentPIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return apps
            .filter { !withWindows.contains($0.pid) && !alwaysRunning.contains($0.bundleID) }
            .sorted { lhs, rhs in
                let l = rank[lhs.pid] ?? Int.max, r = rank[rhs.pid] ?? Int.max
                return l != r ? l < r : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { DockWindow.appWithoutWindows(pid: $0.pid, bundleID: $0.bundleID, appName: $0.name) }
    }

    /// `ordered` (windows by recency, minimized last) with `standIns` placed after the open
    /// windows and before the minimized ones.
    public static func inserting(_ standIns: [DockWindow], into ordered: [DockWindow]) -> [DockWindow] {
        var result = ordered
        let index = result.firstIndex(where: \.isMinimized) ?? result.endIndex
        result.insert(contentsOf: standIns, at: index)
        return result
    }
}
