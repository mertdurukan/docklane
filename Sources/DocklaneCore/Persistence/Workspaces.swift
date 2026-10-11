import CoreGraphics
import Foundation

/// A saved window: which app, which window (by title) and where it was.
public struct SavedWindow: Codable, Equatable, Sendable {
    public let bundleID: String
    public let appName: String
    public let title: String
    /// Cocoa coordinates (origin bottom-left of the main display).
    public let frame: CGRect
    /// Display the window was on (its UUID), when known.
    public let display: String?
    /// The frame as fractions (0…1) of that display's visible area, so the layout survives a
    /// change of resolution or a display that comes back somewhere else.
    public let relativeFrame: CGRect?

    public init(bundleID: String, appName: String, title: String, frame: CGRect,
                display: String? = nil, relativeFrame: CGRect? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.display = display
        self.relativeFrame = relativeFrame
    }
}

/// A named window layout ("Work", "Study") that can be restored with one click.
public struct WorkspaceProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let windows: [SavedWindow]
    /// 1–9: restored from anywhere with ⌃⌥⌘ and this number.
    public var hotKey: Int?
    /// Restoring also hides every app that is not part of the workspace.
    public var hidesOthers: Bool?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), windows: [SavedWindow],
                hotKey: Int? = nil, hidesOthers: Bool? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.windows = windows
        self.hotKey = hotKey
        self.hidesOthers = hidesOthers
    }

    /// The first number 1–9 no other profile uses.
    public static func freeHotKey(among profiles: [WorkspaceProfile]) -> Int? {
        let used = Set(profiles.compactMap(\.hotKey))
        return (1...9).first { !used.contains($0) }
    }

    /// Apps the profile needs, in first-seen order.
    public var bundleIDs: [String] {
        var seen = Set<String>()
        return windows.map(\.bundleID).filter { seen.insert($0).inserted }
    }
}

/// Pairs saved windows with live ones. Pure, unit tested.
public enum WorkspaceMatcher {
    /// Exact app + title matches first; remaining saved windows of an app take that app's
    /// remaining live windows in order. Each live window is used at most once.
    public static func match(saved: [SavedWindow], live: [DockWindow]) -> [(saved: SavedWindow, window: DockWindow)] {
        var used = Set<WindowNumber>()
        var pairs: [(SavedWindow, DockWindow)] = []
        var unmatched: [SavedWindow] = []

        for item in saved {
            if let window = live.first(where: { !used.contains($0.id) && $0.bundleID == item.bundleID && $0.title == item.title && !item.title.isEmpty }) {
                used.insert(window.id)
                pairs.append((item, window))
            } else {
                unmatched.append(item)
            }
        }
        for item in unmatched {
            if let window = live.first(where: { !used.contains($0.id) && $0.bundleID == item.bundleID }) {
                used.insert(window.id)
                pairs.append((item, window))
            }
        }
        return pairs
    }
}

/// All saved profiles, stored as versioned JSON.
public struct WorkspaceLibrary: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = WorkspaceLibrary.currentVersion
    public var profiles: [WorkspaceProfile] = []

    public init() {}

    public static func load(from defaults: UserDefaults, key: String) -> WorkspaceLibrary {
        guard let data = defaults.data(forKey: key),
              let library = try? JSONDecoder().decode(WorkspaceLibrary.self, from: data),
              library.version <= currentVersion
        else { return WorkspaceLibrary() }
        return library
    }

    public func save(to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

/// What happened when a saved layout was opened, so the user hears about apps that could not
/// be brought back instead of a silent partial result. Pure, unit tested.
public struct RestoreReport: Equatable, Sendable {
    /// Apps of the layout that are not installed on this Mac (names, in layout order).
    public let notInstalled: [String]
    /// Installed apps that ended up with no window to put in place.
    public let withoutWindows: [String]
    public let placedWindows: Int
    public let savedWindows: Int

    public init(notInstalled: [String], withoutWindows: [String], placedWindows: Int, savedWindows: Int) {
        self.notInstalled = notInstalled
        self.withoutWindows = withoutWindows
        self.placedWindows = placedWindows
        self.savedWindows = savedWindows
    }

    /// `missingBundleIDs`: apps with no installed copy. `placedBundleIDs`: apps that had at
    /// least one window moved into place.
    public init(saved: [SavedWindow], missingBundleIDs: Set<String>, placedBundleIDs: Set<String>, placedWindows: Int) {
        var seen = Set<String>()
        let apps = saved.filter { seen.insert($0.bundleID).inserted }
        notInstalled = apps.filter { missingBundleIDs.contains($0.bundleID) }.map(\.appName)
        withoutWindows = apps.filter { !missingBundleIDs.contains($0.bundleID) && !placedBundleIDs.contains($0.bundleID) }
            .map(\.appName)
        self.placedWindows = placedWindows
        savedWindows = saved.count
    }

    /// Every app of the layout got its windows back (an app may have fewer windows open now).
    public var isComplete: Bool { notInstalled.isEmpty && withoutWindows.isEmpty }
    public var placedNothing: Bool { placedWindows == 0 }
}
