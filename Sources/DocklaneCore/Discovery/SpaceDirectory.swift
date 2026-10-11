import CoreGraphics
import Foundation

/// One desktop or full-screen space, in Mission Control order.
public struct SpaceInfo: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public let isFullScreen: Bool
    /// Number of a normal desktop as Mission Control counts them (1, 2, …); nil for full screen.
    public let desktopNumber: Int?
    /// Display the space belongs to (its identifier string).
    public let display: String
    /// Shown right now on its display.
    public let isShown: Bool

    public init(id: UInt64, isFullScreen: Bool, desktopNumber: Int?, display: String, isShown: Bool) {
        self.id = id
        self.isFullScreen = isFullScreen
        self.desktopNumber = desktopNumber
        self.display = display
        self.isShown = isShown
    }

    /// Where a window on this space sits relative to what the user sees.
    public var placement: SpacePlacement {
        if isShown { return .current }
        return isFullScreen ? .fullScreen : .desktop(desktopNumber ?? 0)
    }
}

/// Spaces and which windows are on them.
public struct SpaceSnapshot: Sendable {
    public let spaces: [SpaceInfo]
    /// Spaces of each window; empty for a window on no space.
    public let windowSpaces: [WindowNumber: [UInt64]]

    public init(spaces: [SpaceInfo], windowSpaces: [WindowNumber: [UInt64]]) {
        self.spaces = spaces
        self.windowSpaces = windowSpaces
    }

    /// Placement for each window that is on some space; windows on no space are left out.
    /// A window assigned to all desktops is on several; any shown one makes it current.
    public var placements: [WindowNumber: SpacePlacement] {
        let byID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WindowNumber: SpacePlacement] = [:]
        for (window, ids) in windowSpaces where !ids.isEmpty {
            let known = ids.compactMap { byID[$0] }
            if known.isEmpty || known.contains(where: \.isShown) {
                result[window] = .current
            } else {
                result[window] = known[0].placement
            }
        }
        return result
    }
}

/// Which desktop or full-screen space each window is on (private SkyLight calls).
public enum SpaceDirectory {
    /// Nil when the private calls are unavailable, so callers can tell "no space" from "unknown".
    public static func snapshot(for windows: [WindowNumber]) -> SpaceSnapshot? {
        guard let mainConnection = PrivateSymbols.mainConnectionID,
              let copyDisplaySpaces = PrivateSymbols.copyManagedDisplaySpaces,
              let copySpacesForWindows = PrivateSymbols.copySpacesForWindows,
              let getActiveSpace = PrivateSymbols.getActiveSpace
        else { return nil }

        let connection = mainConnection()
        guard let displays = copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        let allSpacesMask: Int32 = 0x7
        var windowSpaces: [WindowNumber: [UInt64]] = [:]
        for window in windows {
            let spaces = copySpacesForWindows(connection, allSpacesMask, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
            windowSpaces[window] = spaces?.map(\.uint64Value) ?? []
        }
        return SpaceSnapshot(spaces: spaces(displays: displays, activeSpace: getActiveSpace(connection)),
                             windowSpaces: windowSpaces)
    }

    /// Pure part, unit tested: every space in Mission Control order (displays in order, then
    /// their spaces), numbering normal desktops 1, 2, … across displays.
    public static func spaces(displays: [[String: Any]], activeSpace: UInt64) -> [SpaceInfo] {
        let fullScreenType = 4
        var result: [SpaceInfo] = []
        var desktopNumber = 0
        for display in displays {
            let identifier = display["Display Identifier"] as? String ?? ""
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                let isFullScreen = (space["type"] as? NSNumber)?.intValue == fullScreenType
                if !isFullScreen { desktopNumber += 1 }
                result.append(SpaceInfo(id: id, isFullScreen: isFullScreen,
                                        desktopNumber: isFullScreen ? nil : desktopNumber,
                                        display: identifier, isShown: id == current || id == activeSpace))
            }
        }
        return result
    }

    /// Pure, unit tested: placements of windows given the displays' spaces.
    public static func placements(
        displays: [[String: Any]],
        activeSpace: UInt64,
        windowSpaces: [WindowNumber: [UInt64]]
    ) -> [WindowNumber: SpacePlacement] {
        SpaceSnapshot(spaces: spaces(displays: displays, activeSpace: activeSpace), windowSpaces: windowSpaces).placements
    }
}
