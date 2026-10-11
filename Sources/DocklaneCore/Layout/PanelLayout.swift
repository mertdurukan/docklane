import Foundation
import CoreGraphics

/// Tile and panel measurements derived from the single Size slider (0 = small, 1 = large),
/// so the panel window and the SwiftUI content always agree.
public struct PanelMetrics: Equatable, Sendable {
    /// Fixed tile width on vertical (left/right) panels.
    public let tileWidth: CGFloat
    /// Fixed tile height on horizontal (bottom) panels.
    public let tileHeight: CGFloat
    /// App icon overlapping a tile's corner.
    public let iconSize: CGFloat
    public let spacing: CGFloat
    public let fontSize: CGFloat

    /// Gap between the screen edge and the tiles.
    public static let edgeInset: CGFloat = 8
    /// Room around each tile for its shadow and the overhanging app icon.
    public static let tileInset: CGFloat = 8

    public init(size: Double) {
        let s = CGFloat(min(max(size, 0), 1))
        tileWidth = (120 + s * 240).rounded()
        tileHeight = (tileWidth * 0.6).rounded()
        iconSize = min(max(tileWidth * 0.16, 22), 44).rounded()
        spacing = (6 + s * 6).rounded()
        fontSize = (11 + s * 3).rounded()
    }

    /// Height-to-width ratios tiles are clamped to.
    public static let minimumAspect: CGFloat = 0.4
    public static let maximumAspect: CGFloat = 1.1

    /// Pixel size to capture a window of `source` size (points) at, so that neither its
    /// panel tile (which fills, cropping extreme shapes) nor `otherImage` (the window
    /// switcher's box, which fits) shows it larger than captured, at backing `scale`.
    /// Capturing more only costs memory.
    public func thumbnailPixelSize(for source: CGSize, edge: PanelEdge, scale: CGFloat,
                                   otherImage: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 1, height: 1) }
        let tile = tileSize(imageSize: source, edge: edge)
        let fill = max(tile.width / source.width, tile.height / source.height)
        let fit = min(otherImage.width / source.width, otherImage.height / source.height)
        let factor = max(fill, fit) * scale
        return CGSize(width: (source.width * factor).rounded(.up), height: (source.height * factor).rounded(.up))
    }

    /// Gap between the screen edge and the tiles: minimal, like the Dock's.
    public static let edgeGap: CGFloat = 4

    /// How far the app icon overhangs a tile's bottom-left corner.
    public var iconOverhang: CGFloat { (iconSize * 0.25).rounded(.up) }

    /// Space between the screen edge and the tiles: the minimal gap, plus the icon's overhang
    /// where that corner faces the edge (left, bottom), plus the tile margin inside a
    /// background so tiles don't touch its border.
    public func edgeSideInset(for edge: PanelEdge, background: Bool = false) -> CGFloat {
        Self.edgeGap + (edge == .left || edge == .bottom ? iconOverhang : 0) + (background ? Self.tileInset : 0)
    }

    /// Panel depth perpendicular to its edge: the edge side is minimal, the far side keeps
    /// room for shadows and the hover lift.
    public func thickness(for edge: PanelEdge, background: Bool = false) -> CGFloat {
        let tile = edge.isVertical ? tileWidth : tileHeight
        return tile + edgeSideInset(for: edge, background: background) + Self.edgeInset + Self.tileInset
    }

    /// Tile size for an image of the given aspect ratio: vertical panels fix the width,
    /// horizontal ones the height. Extreme ratios are clamped so tiles stay usable.
    public func tileSize(imageSize: CGSize?, edge: PanelEdge) -> CGSize {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: tileWidth, height: tileHeight)
        }
        let ratio = min(max(imageSize.height / imageSize.width, Self.minimumAspect), Self.maximumAspect)
        if edge.isVertical {
            return CGSize(width: tileWidth, height: (tileWidth * ratio).rounded())
        }
        return CGSize(width: (tileHeight / ratio).rounded(), height: tileHeight)
    }
}

/// Where the panel goes on one screen (Cocoa coordinates, origin bottom-left).
public struct PanelFrames: Equatable, Sendable {
    /// The panel window: only as long as its tiles, centred on the edge, so clicks beside the
    /// tiles reach the windows behind. Spans the whole edge when no content length is known.
    public let panel: CGRect
    /// Kept clear of other windows; empty when the panel auto-hides (like the Dock).
    public let reserved: CGRect
    /// What remains for other windows.
    public let usable: CGRect
}

public enum PanelLayout {
    /// Gap between the panel and windows kept clear of it.
    public static let windowGap: CGFloat = 4

    /// Room at both ends of the tiles for their shadows and overhanging app icons.
    public static let endInset: CGFloat = PanelMetrics.edgeInset + PanelMetrics.tileInset

    /// `contentLength` is the tiles' natural length along the edge (nil: not measured yet).
    /// Windows are kept clear of the whole edge strip, like the Dock, whatever the tiles' length.
    public static func frames(edge: PanelEdge, thickness: CGFloat, visibleFrame vf: CGRect, autoHide: Bool,
                              contentLength: CGFloat? = nil) -> PanelFrames {
        let strip: CGRect
        switch edge {
        case .left: strip = CGRect(x: vf.minX, y: vf.minY, width: thickness, height: vf.height)
        case .right: strip = CGRect(x: vf.maxX - thickness, y: vf.minY, width: thickness, height: vf.height)
        case .bottom: strip = CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: thickness)
        case .top: strip = CGRect(x: vf.minX, y: vf.maxY - thickness, width: vf.width, height: thickness)
        }
        let panel = contentLength.map { fitted(strip, edge: edge, length: $0 + 2 * endInset) } ?? strip
        guard !autoHide else { return PanelFrames(panel: panel, reserved: .zero, usable: vf) }
        let panelStrip = strip

        let reserved: CGRect
        let usable: CGRect
        let s = panelStrip
        switch edge {
        case .left:
            reserved = CGRect(x: s.minX, y: s.minY, width: s.width + windowGap, height: s.height)
            usable = CGRect(x: reserved.maxX, y: vf.minY, width: vf.maxX - reserved.maxX, height: vf.height)
        case .right:
            reserved = CGRect(x: s.minX - windowGap, y: s.minY, width: s.width + windowGap, height: s.height)
            usable = CGRect(x: vf.minX, y: vf.minY, width: reserved.minX - vf.minX, height: vf.height)
        case .bottom:
            reserved = CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height + windowGap)
            usable = CGRect(x: vf.minX, y: reserved.maxY, width: vf.width, height: vf.maxY - reserved.maxY)
        case .top:
            reserved = CGRect(x: s.minX, y: s.minY - windowGap, width: s.width, height: s.height + windowGap)
            usable = CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: reserved.minY - vf.minY)
        }
        return PanelFrames(panel: panel, reserved: reserved, usable: usable)
    }

    /// `length` along the edge (at most the whole strip), centred on the strip.
    static func fitted(_ strip: CGRect, edge: PanelEdge, length: CGFloat) -> CGRect {
        if edge.isVertical {
            let height = min(max(length, 0), strip.height).rounded(.up)
            return CGRect(x: strip.minX, y: (strip.midY - height / 2).rounded(), width: strip.width, height: height)
        }
        let width = min(max(length, 0), strip.width).rounded(.up)
        return CGRect(x: (strip.midX - width / 2).rounded(), y: strip.minY, width: width, height: strip.height)
    }

    /// Depth of the strip at the screen edge that reveals an auto-hidden panel: the pointer
    /// only has to get close to the edge, not hit its last pixel.
    public static let revealDepth: CGFloat = 4

    /// Height of the top-of-screen strip (inside the menu bar) that also reveals a top panel:
    /// a pointer thrown upward stops there, often without touching the strip below the bar.
    public static let menuBarRevealDepth: CGFloat = 2

    /// Every area that reveals an auto-hidden panel. For the top edge that is the strip below
    /// the menu bar and, when a menu bar is shown, the topmost pixels of the screen, both
    /// limited to the panel's stretch so menus and status items stay reachable.
    public static func revealZones(edge: PanelEdge, screenFrame f: CGRect, visibleFrame: CGRect? = nil,
                                   panel: CGRect? = nil) -> [CGRect] {
        let zone = revealZone(edge: edge, screenFrame: f, visibleFrame: visibleFrame, panel: panel)
        guard edge == .top, let visibleFrame, visibleFrame.maxY < f.maxY - menuBarRevealDepth else { return [zone] }
        // The pointer's topmost position is reported as y == maxY, which CGRect.contains leaves
        // out; reach one point past it.
        let top = CGRect(x: zone.minX, y: f.maxY - menuBarRevealDepth, width: zone.width, height: menuBarRevealDepth + 1)
        return [zone, top]
    }

    /// Strip at the screen edge that reveals an auto-hidden panel. For the top edge it sits
    /// right below the menu bar (`visibleFrame`), so the menu bar keeps working. With a `panel`
    /// frame it covers only the panel's stretch of the edge, like the Dock's.
    public static func revealZone(edge: PanelEdge, screenFrame f: CGRect, visibleFrame: CGRect? = nil,
                                  panel: CGRect? = nil) -> CGRect {
        let depth = revealDepth
        let zone: CGRect
        switch edge {
        case .left: zone = CGRect(x: f.minX, y: f.minY, width: depth, height: f.height)
        case .right: zone = CGRect(x: f.maxX - depth, y: f.minY, width: depth, height: f.height)
        case .bottom: zone = CGRect(x: f.minX, y: f.minY, width: f.width, height: depth)
        case .top:
            let top = (visibleFrame ?? f).maxY
            // With no menu bar the strip is the screen's top, whose last row reports y == maxY.
            let reach: CGFloat = top >= f.maxY ? 1 : 0
            zone = CGRect(x: f.minX, y: top - depth, width: f.width, height: depth + reach)
        }
        guard let panel else { return zone }
        if edge.isVertical {
            return CGRect(x: zone.minX, y: panel.minY, width: zone.width, height: panel.height)
        }
        return CGRect(x: panel.minX, y: zone.minY, width: panel.width, height: zone.height)
    }

    /// When an auto-hidden panel that was revealed at `revealedAt` may hide again, given that
    /// the pointer left it at `leftAt`: it stays at least `minimumVisible`, and after that
    /// `delay` past the moment the pointer left.
    public static func hideDeadline(revealedAt: Date, leftAt: Date, minimumVisible: TimeInterval,
                                    delay: TimeInterval) -> Date {
        max(revealedAt.addingTimeInterval(minimumVisible), leftAt.addingTimeInterval(delay))
    }
}
