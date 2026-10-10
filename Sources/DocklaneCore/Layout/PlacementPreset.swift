import CoreGraphics

/// Quick window placements from the window menu. Pure geometry (Cocoa coordinates).
public enum PlacementPreset: String, CaseIterable, Sendable {
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
