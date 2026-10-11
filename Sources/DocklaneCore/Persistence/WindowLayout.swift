import CoreGraphics
import Foundation

/// A display as layouts see it (Cocoa coordinates, origin bottom-left of the main display).
public struct DisplayInfo: Equatable, Sendable {
    public let id: String
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Geometry for saving and restoring window layouts across display changes. Pure, unit tested.
public enum WindowLayoutMath {
    /// Identifies a set of connected displays, whatever their order.
    public static func displaySetKey(_ displays: [DisplayInfo]) -> String {
        displays.map(\.id).sorted().joined(separator: "+")
    }

    /// The display showing most of `frame`; the main (first) display if none does.
    public static func display(for frame: CGRect, among displays: [DisplayInfo]) -> DisplayInfo? {
        let best = displays.max { area($0.frame.intersection(frame)) < area($1.frame.intersection(frame)) }
        if let best, area(best.frame.intersection(frame)) > 0 { return best }
        return displays.first
    }

    /// `frame` as fractions of `visible`.
    public static func relative(_ frame: CGRect, in visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return .zero }
        return CGRect(x: (frame.minX - visible.minX) / visible.width, y: (frame.minY - visible.minY) / visible.height,
                      width: frame.width / visible.width, height: frame.height / visible.height)
    }

    /// Where a saved window goes now: its own frame if its display is still there and
    /// unchanged; scaled to that display if it changed; otherwise onto the display it mostly
    /// overlaps, or the main one, by its relative frame. Always kept inside a visible area.
    public static func resolve(_ saved: SavedWindow, displays: [DisplayInfo]) -> CGRect {
        guard !displays.isEmpty else { return saved.frame }
        if let id = saved.display, let display = displays.first(where: { $0.id == id }) {
            if display.visibleFrame.contains(saved.frame) { return saved.frame }
            if let relative = saved.relativeFrame { return clamp(absolute(relative, in: display.visibleFrame), into: display.visibleFrame) }
            return clamp(saved.frame, into: display.visibleFrame)
        }
        let overlapping = displays.first { area($0.visibleFrame.intersection(saved.frame)) > area(saved.frame) * 0.5 }
        if let overlapping { return clamp(saved.frame, into: overlapping.visibleFrame) }
        let target = displays[0].visibleFrame
        if let relative = saved.relativeFrame { return clamp(absolute(relative, in: target), into: target) }
        return clamp(saved.frame, into: target)
    }

    /// Fits `frame` inside `visible`: no larger, and moved in from the edges.
    public static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    private static func absolute(_ relative: CGRect, in visible: CGRect) -> CGRect {
        CGRect(x: visible.minX + relative.minX * visible.width, y: visible.minY + relative.minY * visible.height,
               width: relative.width * visible.width, height: relative.height * visible.height)
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}

/// Recent layouts with the time they were seen, so a display change can use the layout from
/// just before it (macOS starts moving windows the moment a display goes away).
public struct LayoutRecorder: Sendable {
    public private(set) var entries: [(date: Date, layout: [SavedWindow])] = []
    private let limit = 8

    public init() {}

    public mutating func record(_ layout: [SavedWindow], at date: Date) {
        if entries.last?.layout == layout { return }
        entries.append((date, layout))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// The newest layout seen before `date`.
    public func layout(before date: Date) -> [SavedWindow]? {
        entries.last { $0.date < date }?.layout
    }
}

/// Layouts to go back to with Undo, newest last.
public struct LayoutHistory: Sendable {
    public private(set) var entries: [[SavedWindow]] = []
    private let limit = 10

    public init() {}

    public mutating func push(_ layout: [SavedWindow]) {
        guard !layout.isEmpty else { return }
        entries.append(layout)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    public mutating func pop() -> [SavedWindow]? { entries.popLast() }
}

/// The last layout used with each set of displays, stored as versioned JSON.
public struct DisplayLayoutStore: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = DisplayLayoutStore.currentVersion
    public var layouts: [String: [SavedWindow]] = [:]

    public init() {}

    public static func load(from defaults: UserDefaults, key: String) -> DisplayLayoutStore {
        guard let data = defaults.data(forKey: key),
              let store = try? JSONDecoder().decode(DisplayLayoutStore.self, from: data),
              store.version <= currentVersion
        else { return DisplayLayoutStore() }
        return store
    }

    public func save(to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}
