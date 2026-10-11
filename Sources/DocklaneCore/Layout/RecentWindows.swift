/// Most recently focused windows first, for the window and desktop switchers. Pure, unit tested.
public struct RecentWindows: Equatable, Sendable {
    public static let limit = 200
    public private(set) var order: [WindowNumber] = []

    public init(order: [WindowNumber] = []) {
        self.order = Array(order.prefix(Self.limit))
    }

    /// `window` got focus: it moves to the front.
    public mutating func focused(_ window: WindowNumber) {
        order.removeAll { $0 == window }
        order.insert(window, at: 0)
        if order.count > Self.limit { order.removeLast(order.count - Self.limit) }
    }

    /// Open windows by recency (never-focused ones keep their given order after the known
    /// ones), minimized windows last.
    public func sorted(_ windows: [DockWindow]) -> [DockWindow] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return windows.enumerated().sorted { lhs, rhs in
            if lhs.element.isMinimized != rhs.element.isMinimized { return !lhs.element.isMinimized }
            let l = rank[lhs.element.id] ?? Int.max
            let r = rank[rhs.element.id] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }
}
