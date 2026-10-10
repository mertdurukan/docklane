import AppKit
import CoreGraphics

/// Raw WindowServer entry (one row of `CGWindowListCopyWindowInfo`).
public struct WindowRecord: Hashable, Sendable {
    public let id: WindowNumber
    public let pid: pid_t
    public let title: String
    public let bounds: CGRect
    public let layer: Int
    public let alpha: Double
    public let isOnScreen: Bool

    public init(id: WindowNumber, pid: pid_t, title: String, bounds: CGRect, layer: Int, alpha: Double, isOnScreen: Bool) {
        self.id = id
        self.pid = pid
        self.title = title
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }

    init?(_ info: [String: Any]) {
        guard let id = info[kCGWindowNumber as String] as? WindowNumber,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo)
        else { return nil }
        self.id = id
        self.pid = pid
        self.title = info[kCGWindowName as String] as? String ?? ""
        self.bounds = bounds
        self.layer = info[kCGWindowLayer as String] as? Int ?? 0
        self.alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        self.isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}

/// Decides which WindowServer entries are windows a person opened. Pure, unit tested.
public enum WindowFilter {
    /// Smaller surfaces are toolbars, popovers and helper strips (e.g. Chrome's 1800x81
    /// full-screen toolbar), not windows.
    public static let minimumSide: CGFloat = 200

    public static func isUserWindow(_ record: WindowRecord, ownPID: pid_t, regularApps: Set<pid_t>) -> Bool {
        guard record.layer == 0,
              record.alpha > 0,
              record.pid != ownPID,
              regularApps.contains(record.pid),
              record.bounds.width >= minimumSide,
              record.bounds.height >= minimumSide
        else { return false }
        // Off-screen surfaces without a title are backing buffers, not windows.
        return record.isOnScreen || !record.title.isEmpty
    }

    /// Off-screen entries of one app with the same title and size are one window reported
    /// twice (full-screen apps do this). Keeps the first, preserving order.
    public static func removingDuplicates(_ records: [WindowRecord]) -> [WindowRecord] {
        var seen = Set<String>()
        return records.filter { record in
            guard !record.isOnScreen else { return true }
            let key = "\(record.pid)|\(record.title)|\(Int(record.bounds.width))x\(Int(record.bounds.height))"
            return seen.insert(key).inserted
        }
    }
}

/// Lists user windows across every desktop and full-screen space.
@MainActor
public enum WindowCatalog {
    public static func snapshot() -> [DockWindow] {
        let appsByPID = AppDirectory.shared.regularApps

        let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let records = WindowFilter.removingDuplicates(
            infos.compactMap(WindowRecord.init).filter {
                WindowFilter.isUserWindow($0, ownPID: getpid(), regularApps: Set(appsByPID.keys))
            }
        )

        let minimized = AccessibilityInspector.minimizedWindowNumbers(of: Set(records.map(\.pid)))
        let placements = SpaceDirectory.placements(for: records.map(\.id))

        return records.compactMap { record in
            guard let app = appsByPID[record.pid] else { return nil }
            let isMinimized = minimized.contains(record.id)
            return DockWindow(
                id: record.id,
                pid: record.pid,
                bundleID: app.bundleID,
                appName: app.name,
                title: record.title,
                bounds: record.bounds,
                isOnScreen: record.isOnScreen,
                isMinimized: isMinimized,
                space: isMinimized ? .current : placements[record.id] ?? .current
            )
        }
    }
}
