import CoreGraphics
import Foundation

public typealias WindowNumber = CGWindowID

/// One user window, as Docklane shows it. Plain value type: safe to pass between actors.
public struct DockWindow: Identifiable, Hashable, Sendable {
    public let id: WindowNumber
    public let pid: pid_t
    public let bundleID: String
    public let appName: String
    public var title: String
    /// WindowServer bounds: global coordinates, origin at the top-left of the main display.
    public var bounds: CGRect
    /// Visible on a currently shown space (not minimized, not on another desktop).
    public var isOnScreen: Bool
    public var isMinimized: Bool
    public var space: SpacePlacement
    /// Spaces the window is on (several when assigned to all desktops); empty if unknown.
    public var spaceIDs: [UInt64]

    public init(
        id: WindowNumber,
        pid: pid_t,
        bundleID: String,
        appName: String,
        title: String,
        bounds: CGRect,
        isOnScreen: Bool,
        isMinimized: Bool = false,
        space: SpacePlacement = .current,
        spaceIDs: [UInt64] = []
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.space = space
        self.spaceIDs = spaceIDs
    }

    /// Title for labels: the window title, or the app name when the window has none.
    public var displayTitle: String { title.isEmpty ? appName : title }
}

/// Where a window lives relative to what the user sees right now.
public enum SpacePlacement: Hashable, Sendable {
    /// On a space that is currently shown (or unknown).
    case current
    /// On another desktop, numbered as in Mission Control (1-based).
    case desktop(Int)
    /// In its own full-screen space.
    case fullScreen
}

/// Screen edge for the panel. `left`, `bottom` and `right` match the Dock's `orientation`
/// preference strings; `top` (below the menu bar) is Docklane-only.
public enum PanelEdge: String, CaseIterable, Codable, Sendable {
    case left, top, bottom, right

    public var isVertical: Bool { self == .left || self == .right }
}
