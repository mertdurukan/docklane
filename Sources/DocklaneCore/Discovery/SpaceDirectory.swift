import CoreGraphics
import Foundation

/// Which desktop or full-screen space each window is on (private SkyLight calls).
public enum SpaceDirectory {
    /// Placement for each window. Windows on a space that is currently shown are `.current`.
    public static func placements(for windows: [WindowNumber]) -> [WindowNumber: SpacePlacement] {
        guard !windows.isEmpty,
              let mainConnection = PrivateSymbols.mainConnectionID,
              let copyDisplaySpaces = PrivateSymbols.copyManagedDisplaySpaces,
              let copySpacesForWindows = PrivateSymbols.copySpacesForWindows,
              let getActiveSpace = PrivateSymbols.getActiveSpace
        else { return [:] }

        let connection = mainConnection()
        guard let displays = copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }

        let allSpacesMask: Int32 = 0x7
        var windowSpaces: [WindowNumber: UInt64] = [:]
        for window in windows {
            let spaces = copySpacesForWindows(connection, allSpacesMask, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
            if let space = spaces?.first?.uint64Value { windowSpaces[window] = space }
        }
        return placements(displays: displays, activeSpace: getActiveSpace(connection), windowSpaces: windowSpaces)
    }

    /// Pure part, unit tested: numbers normal desktops 1, 2, … in Mission Control order
    /// (across displays), marks full-screen spaces and leaves currently shown spaces `.current`.
    public static func placements(
        displays: [[String: Any]],
        activeSpace: UInt64,
        windowSpaces: [WindowNumber: UInt64]
    ) -> [WindowNumber: SpacePlacement] {
        let fullScreenType = 4
        var spaceKinds: [UInt64: SpacePlacement] = [:]
        var shownSpaces: Set<UInt64> = [activeSpace]
        var desktopNumber = 0

        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value {
                shownSpaces.insert(id)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                if (space["type"] as? NSNumber)?.intValue == fullScreenType {
                    spaceKinds[id] = .fullScreen
                } else {
                    desktopNumber += 1
                    spaceKinds[id] = .desktop(desktopNumber)
                }
            }
        }

        var result: [WindowNumber: SpacePlacement] = [:]
        for (window, space) in windowSpaces {
            guard !shownSpaces.contains(space), let kind = spaceKinds[space] else {
                result[window] = .current
                continue
            }
            result[window] = kind
        }
        return result
    }
}
