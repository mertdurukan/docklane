import AppKit
import DocklaneCore

/// Keeps windows out of the panel's area while the panel is always visible (like a Dock that
/// doesn't auto-hide). Only touches on-screen windows that actually overlap the panel, never
/// full-screen windows, and each window at most once every few seconds so it can't fight an
/// app that insists on its own frame.
@MainActor
final class WindowClearance {
    private var lastAdjusted: [WindowNumber: Date] = [:]
    private let cooldown: TimeInterval = 3
    private var pending: Task<Void, Never>?

    /// For changes that come in bursts (dragging the Size slider): enforce once they stop,
    /// instead of moving windows at every step.
    func enforceSoon(_ windows: @escaping @MainActor () -> [DockWindow]) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.enforce(windows())
        }
    }

    func enforce(_ windows: [DockWindow], onlyPID: pid_t? = nil) {
        let settings = AppSettings.shared
        guard settings.keepWindowsClear, !settings.autoHide, AccessibilityInspector.isTrusted,
              let mainHeight = NSScreen.screens.first?.frame.height else { return }

        let now = Date()
        lastAdjusted = lastAdjusted.filter { now.timeIntervalSince($0.value) < cooldown }
        let thickness = settings.metrics.thickness(for: settings.edge, background: settings.showBackground)

        for window in windows where window.isOnScreen && !window.isMinimized && window.space == .current {
            if let onlyPID, window.pid != onlyPID { continue }
            guard lastAdjusted[window.id] == nil else { continue }

            // WindowServer bounds are top-left based; convert to Cocoa (bottom-left).
            let frame = CGRect(x: window.bounds.minX, y: mainHeight - window.bounds.maxY,
                               width: window.bounds.width, height: window.bounds.height)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
                  frame != screen.frame else { continue }

            let layout = PanelLayout.frames(edge: settings.edge, thickness: thickness,
                                            visibleFrame: screen.visibleFrame, autoHide: false)
            let overlap = frame.intersection(layout.reserved)
            guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { continue }

            WindowActions.fill(window, frame: Self.cleared(frame, usable: layout.usable, edge: settings.edge))
            lastAdjusted[window.id] = now
        }
    }

    /// Smallest change that moves `frame` out of the panel: shift first, shrink only if needed.
    static func cleared(_ frame: CGRect, usable: CGRect, edge: PanelEdge) -> CGRect {
        var result = frame
        switch edge {
        case .left:
            result.origin.x = max(frame.minX, usable.minX)
            result.size.width = min(frame.width, usable.maxX - result.minX)
        case .right:
            result.size.width = min(frame.width, usable.width)
            result.origin.x = min(frame.minX, usable.maxX - result.width)
        case .bottom:
            result.origin.y = max(frame.minY, usable.minY)
            result.size.height = min(frame.height, usable.maxY - result.minY)
        case .top:
            result.size.height = min(frame.height, usable.height)
            result.origin.y = min(frame.minY, usable.maxY - result.height)
        }
        return result
    }
}
