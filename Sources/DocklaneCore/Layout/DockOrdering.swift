import Foundation

/// The panel's tile order. Pure, unit tested.
public enum DockOrdering {
    public struct Arrangement: Equatable, Sendable {
        public let open: [DockWindow]
        public let minimized: [DockWindow]
    }

    /// - Pinned apps come first, in pinned order; other apps follow in order of first
    ///   appearance in `windows` (the engine keeps that order stable).
    /// - A given app's windows stay together, keeping their relative order.
    /// - Windows the user dragged into place (`manualOrder`) keep exactly that order;
    ///   windows not in it follow, arranged as above.
    /// - Minimized windows form their own section at the end.
    public static func arrange(_ windows: [DockWindow], pinned: [String], manualOrder: [WindowNumber]) -> Arrangement {
        let open = windows.filter { !$0.isMinimized }
        let minimized = windows.filter(\.isMinimized)
        return Arrangement(open: order(open, pinned: pinned, manualOrder: manualOrder), minimized: minimized)
    }

    private static func order(_ windows: [DockWindow], pinned: [String], manualOrder: [WindowNumber]) -> [DockWindow] {
        let manualRank = Dictionary(manualOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let manual = windows.filter { manualRank[$0.id] != nil }.sorted { manualRank[$0.id]! < manualRank[$1.id]! }
        let rest = windows.filter { manualRank[$0.id] == nil }
        return manual + grouped(rest, pinned: pinned)
    }

    private static func grouped(_ windows: [DockWindow], pinned: [String]) -> [DockWindow] {
        var groupOrder: [String] = []
        var groups: [String: [DockWindow]] = [:]
        for window in windows {
            if groups[window.bundleID] == nil { groupOrder.append(window.bundleID) }
            groups[window.bundleID, default: []].append(window)
        }
        let pinnedRank = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sortedGroups = groupOrder.enumerated().sorted { lhs, rhs in
            let l = pinnedRank[lhs.element] ?? Int.max
            let r = pinnedRank[rhs.element] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        return sortedGroups.flatMap { groups[$0.element] ?? [] }
    }

    /// The Dock shows one badge per app: the first tile of each app carries it.
    public static func badgeCarriers(_ windows: [DockWindow]) -> Set<WindowNumber> {
        var seen = Set<String>()
        var carriers = Set<WindowNumber>()
        for window in windows where seen.insert(window.bundleID).inserted {
            carriers.insert(window.id)
        }
        return carriers
    }
}
