import AppKit
import Carbon.HIToolbox
import DocklaneCore

/// Arranges the front window from the keyboard: ⌃⌥←/→/↑/↓ halves (again: ⅓, ⅔), ⌃⌥↩ fill,
/// ⌃⌥C center, ⌃⌥⌘←/→ to the previous / next display. Each move can be undone with ⌃⌥Z.
@MainActor
enum KeyboardPlacer {
    private static let firstID: UInt32 = 120
    private static let shortcuts: [(key: Int, modifiers: Int, action: Action)] = [
        (kVK_LeftArrow, controlKey | optionKey, .place(.left)),
        (kVK_RightArrow, controlKey | optionKey, .place(.right)),
        (kVK_UpArrow, controlKey | optionKey, .place(.up)),
        (kVK_DownArrow, controlKey | optionKey, .place(.down)),
        (kVK_Return, controlKey | optionKey, .place(.fill)),
        (kVK_ANSI_C, controlKey | optionKey, .place(.center)),
        (kVK_LeftArrow, controlKey | optionKey | cmdKey, .display(-1)),
        (kVK_RightArrow, controlKey | optionKey | cmdKey, .display(1)),
    ]

    enum Action {
        case place(KeyboardPlacement)
        case display(Int)
    }

    static func start() {
        apply()
        observe()
    }

    private static func observe() {
        withObservationTracking {
            _ = AppSettings.shared.keyboardPlacement
        } onChange: {
            Task { @MainActor in
                apply()
                observe()
            }
        }
    }

    private static func apply() {
        let center = HotKeyCenter.shared
        for (index, shortcut) in shortcuts.enumerated() {
            let id = firstID + UInt32(index)
            if AppSettings.shared.keyboardPlacement {
                center.register(id: id, keyCode: shortcut.key, modifiers: shortcut.modifiers) { perform(shortcut.action) }
            } else {
                center.unregister(id: id)
            }
        }
    }

    static func perform(_ action: Action) {
        guard let window = frontWindow() else { return NSSound.beep() }
        let current = WindowActions.cocoaFrame(of: window)
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard let screen = screens.max(by: { overlap($0, current) < overlap($1, current) }) else { return }
        let frame: CGRect
        switch action {
        case .place(let placement):
            frame = PlacementCycle.frame(for: placement, current: current, usable: usableArea(on: screen))
        case .display(let step):
            guard screens.count > 1, let index = screens.firstIndex(of: screen) else { return NSSound.beep() }
            let target = screens[(index + step + screens.count) % screens.count]
            frame = PlacementCycle.move(current, from: usableArea(on: screen), to: usableArea(on: target))
        }
        WorkspaceManager.shared.recordUndoPoint()
        WindowActions.fill(window, frame: frame, restoreIfMinimized: true)
        WindowEngine.shared.scheduleRefresh(after: .milliseconds(300))
    }

    /// The focused window of the frontmost app (never Docklane's own).
    private static func frontWindow() -> DockWindow? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),
              let number = AccessibilityInspector.focusedWindowNumber() else { return nil }
        let engine = WindowEngine.shared
        if let window = engine.windows.first(where: { $0.id == number }) { return window }
        engine.refresh()
        return engine.windows.first { $0.id == number }
    }

    /// The screen minus the strip a pinned (not auto-hiding) panel keeps clear.
    static func usableArea(on screen: NSScreen) -> CGRect {
        let settings = AppSettings.shared
        return PanelLayout.frames(edge: settings.edge,
                                  thickness: settings.metrics.thickness(for: settings.edge, background: settings.showBackground),
                                  visibleFrame: screen.visibleFrame, autoHide: settings.autoHide).usable
    }

    private static func overlap(_ screen: NSScreen, _ frame: CGRect) -> CGFloat {
        let area = screen.frame.intersection(frame)
        return area.isNull ? 0 : area.width * area.height
    }
}

/// Places new windows of apps that have a rule ("Chrome: left half"), once, as they appear.
@MainActor
enum WindowRules {
    static func start() {
        WindowEngine.shared.onWindowsAdded = { added in
            let pending = WindowRule.placements(for: added, rules: AppSettings.shared.windowRules)
            guard !pending.isEmpty else { return }
            // Let the app finish opening and sizing the window first.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                for (window, placement) in pending { place(window, placement) }
                WindowEngine.shared.scheduleRefresh(after: .milliseconds(300))
            }
        }
    }

    private static func place(_ window: DockWindow, _ placement: PlacementPreset) {
        let current = WindowActions.cocoaFrame(of: window)
        let screen = NSScreen.screens.max { area($0.frame.intersection(current)) < area($1.frame.intersection(current)) }
            ?? NSScreen.main
        guard let screen else { return }
        WindowActions.fill(window, frame: placement.frame(in: KeyboardPlacer.usableArea(on: screen), current: current))
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}
