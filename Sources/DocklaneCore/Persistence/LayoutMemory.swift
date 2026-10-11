import Foundation

/// What the user arranged by hand: tile order and custom labels. Stored as versioned JSON.
///
/// Window numbers are only unique within a login session and may be reused after a restart,
/// so a label also records the app it belongs to and only applies to a window of that app.
public struct LayoutMemory: Codable, Equatable, Sendable {
    public struct Label: Codable, Equatable, Sendable {
        public let window: WindowNumber
        public let bundleID: String
        public let text: String
    }

    public static let currentVersion = 1
    public static let maxEntries = 200

    public var version = LayoutMemory.currentVersion
    public private(set) var manualOrder: [WindowNumber] = []
    public private(set) var labels: [Label] = []
    /// Login session the window numbers belong to (`LoginSession.current`); nil in data saved
    /// before this was recorded.
    public private(set) var session: String?

    public init() {}

    public func label(for window: DockWindow) -> String? {
        labels.first { $0.window == window.id && $0.bundleID == window.bundleID }?.text
    }

    public mutating func setLabel(_ text: String?, for window: DockWindow) {
        labels.removeAll { $0.window == window.id }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            labels.append(Label(window: window.id, bundleID: window.bundleID, text: trimmed))
        }
        labels = Array(labels.suffix(Self.maxEntries))
    }

    /// Moves `window` in front of `target` (or to the end when `target` is nil), starting from
    /// the order currently on screen.
    public mutating func move(_ window: WindowNumber, before target: WindowNumber?, currentOrder: [WindowNumber]) {
        var order = currentOrder
        order.removeAll { $0 == window }
        if let target, let index = order.firstIndex(of: target) {
            order.insert(window, at: index)
        } else {
            order.append(window)
        }
        manualOrder = Array(order.suffix(Self.maxEntries))
    }

    public mutating func resetOrder() {
        manualOrder = []
    }

    /// Drops entries for windows that are gone for good (their app is still running but the
    /// window is not), so stale numbers can't match a future window.
    public mutating func forget(_ windows: Set<WindowNumber>) {
        guard !windows.isEmpty else { return }
        manualOrder.removeAll { windows.contains($0) }
        labels.removeAll { windows.contains($0.window) }
    }

    // MARK: - Storage

    /// Window numbers from another login session point at other windows now, so the order
    /// and labels of an earlier session are dropped. Unreadable data is backed up.
    public static func load(from defaults: UserDefaults, key: String,
                            session: String = LoginSession.current, now: Date = Date()) -> LayoutMemory {
        var memory = StoredJSON.load(LayoutMemory.self, from: defaults, key: key, now: now,
                                     isAcceptable: { $0.version <= currentVersion }).value ?? LayoutMemory()
        if let saved = memory.session, saved != session {
            memory.manualOrder = []
            memory.labels = []
        }
        memory.session = session
        return memory
    }

    public func save(to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: key)
        }
    }
}
