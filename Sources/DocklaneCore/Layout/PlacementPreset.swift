import CoreGraphics

/// Quick window placements from the window menu. Pure geometry (Cocoa coordinates).
public enum PlacementPreset: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, center, fill

    /// Gap kept between a placed window and the edges of the usable area.
    public static let inset: CGFloat = 0

    public func frame(in usable: CGRect, current: CGRect) -> CGRect {
        let area = usable.insetBy(dx: Self.inset, dy: Self.inset)
        switch self {
        case .leftHalf:
            return CGRect(x: area.minX, y: area.minY, width: (area.width / 2).rounded(), height: area.height)
        case .rightHalf:
            let width = (area.width / 2).rounded()
            return CGRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
        case .topHalf:
            let height = (area.height / 2).rounded()
            return CGRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
        case .bottomHalf:
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: (area.height / 2).rounded())
        case .center:
            // Keep the window's size when it fits, otherwise 70 % of the area.
            let width = current.width <= area.width ? current.width : (area.width * 0.7).rounded()
            let height = current.height <= area.height ? current.height : (area.height * 0.7).rounded()
            return CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(),
                          width: width, height: height)
        case .fill:
            return area
        }
    }
}

/// A keyboard placement: ⌃⌥ + an arrow, Return or C.
public enum KeyboardPlacement: String, CaseIterable, Sendable {
    case left, right, up, down, fill, center
}

/// Frames for keyboard placement. Pressing the same arrow again cycles the size through
/// ½ → ⅓ → ⅔ of the usable area, the way window managers like Rectangle do. Pure, unit tested.
public enum PlacementCycle {
    static let fractions: [CGFloat] = [1.0 / 2, 1.0 / 3, 2.0 / 3]

    public static func frame(for placement: KeyboardPlacement, current: CGRect, usable: CGRect) -> CGRect {
        switch placement {
        case .fill: return usable
        case .center: return PlacementPreset.center.frame(in: usable, current: current)
        case .left, .right, .up, .down:
            let steps = fractions.map { side(placement, fraction: $0, in: usable) }
            if let index = steps.firstIndex(where: { isClose($0, current) }) {
                return steps[(index + 1) % steps.count]
            }
            return steps[0]
        }
    }

    private static func side(_ placement: KeyboardPlacement, fraction: CGFloat, in area: CGRect) -> CGRect {
        let width = (area.width * fraction).rounded()
        let height = (area.height * fraction).rounded()
        switch placement {
        case .left: return CGRect(x: area.minX, y: area.minY, width: width, height: area.height)
        case .right: return CGRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
        case .up: return CGRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
        default: return CGRect(x: area.minX, y: area.minY, width: area.width, height: height)
        }
    }

    /// Apps round sizes to their own steps (terminals to whole characters): allow a little slack.
    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 12 && abs(a.minY - b.minY) <= 12
            && abs(a.width - b.width) <= 12 && abs(a.height - b.height) <= 12
    }

    /// The same place on another display: same fractions of its usable area.
    public static func move(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let relative = WindowLayoutMath.relative(frame, in: from)
        let moved = CGRect(x: to.minX + relative.minX * to.width, y: to.minY + relative.minY * to.height,
                           width: relative.width * to.width, height: relative.height * to.height)
        return WindowLayoutMath.clamp(moved, into: to)
    }
}

/// "Put new windows of this app here." Stored as JSON in the settings.
public struct WindowRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let appName: String
    public var placement: PlacementPreset

    public init(bundleID: String, appName: String, placement: PlacementPreset) {
        self.bundleID = bundleID
        self.appName = appName
        self.placement = placement
    }

    /// Windows that just appeared and have a rule (minimized ones are left alone). Pure, tested.
    public static func placements(for added: [DockWindow], rules: [WindowRule]) -> [(window: DockWindow, placement: PlacementPreset)] {
        let byApp = Dictionary(rules.map { ($0.bundleID, $0.placement) }, uniquingKeysWith: { first, _ in first })
        return added.compactMap { window in
            guard !window.isMinimized, let placement = byApp[window.bundleID] else { return nil }
            return (window, placement)
        }
    }
}
