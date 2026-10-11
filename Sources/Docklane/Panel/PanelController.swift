import AppKit
import DocklaneCore
import Observation
import SwiftUI

/// Owns one panel per display: placement, auto-hide and the show/hide shortcut.
@MainActor
@Observable
final class PanelController {
    static let shared = PanelController()

    /// Called when the panel's position or size changed (to keep windows clear of it).
    @ObservationIgnored var onLayoutChanged: (() -> Void)?
    /// Tile selected with the keyboard (highlighted in the panel), nil when not navigating.
    private(set) var navigationSelection: WindowNumber?
    @ObservationIgnored private var navigationItems: [DockWindow] = []
    @ObservationIgnored private var navigationDisplay: CGDirectDisplayID?
    @ObservationIgnored private var navigationMonitor: Any?
    @ObservationIgnored private var navigationPreviousApp: NSRunningApplication?

    @ObservationIgnored private var panels: [CGDirectDisplayID: (screen: NSScreen, panel: DockPanel)] = [:]
    @ObservationIgnored private var revealed: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var hideDeadlines: [CGDirectDisplayID: Date] = [:]
    @ObservationIgnored private var revealedAt: [CGDirectDisplayID: Date] = [:]
    /// Natural length of each panel's tiles along the edge, reported by its DockView.
    @ObservationIgnored private var contentLengths: [CGDirectDisplayID: CGFloat] = [:]
    @ObservationIgnored private var mouseMonitors: [Any] = []
    @ObservationIgnored private var hideTimer: Timer?
    /// Top edge only: when the pointer entered a reveal zone; it reveals after `topRevealDwell`
    /// so passing through on the way to the menu bar doesn't.
    @ObservationIgnored private var zoneEnteredAt: [CGDirectDisplayID: Date] = [:]
    @ObservationIgnored private var dwellTimer: Timer?
    static let topRevealDwell: TimeInterval = 0.15
    /// While appearance settings change the panel stays visible briefly, even when hidden.
    @ObservationIgnored private var previewUntil: Date?
    @ObservationIgnored private var previewTimer: Timer?
    private static let previewDuration: TimeInterval = 1.5
    /// An auto-hidden panel stays at least this long once revealed, even if the pointer
    /// moves straight on.
    static let minimumRevealDuration: TimeInterval = 2

    private var settings: AppSettings { .shared }

    private init() {}

    func start() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endNavigation(activate: false) }
        }
        registerHotKeys()
        observeLayout()
        observeAppearance()
    }

    /// "Hide Panel" / "Show Panel" and the shortcut: turn auto-hide on or off, like the Dock's
    /// "Turn Hiding On/Off" (⌥⌘D). One switch, so the menu and the setting can't disagree.
    func toggle() {
        settings.autoHide.toggle()
    }

    private func registerHotKeys() {
        HotKeyCenter.shared.register(settings.hotKey, for: .toggleHiding) { [weak self] in self?.toggle() }
        HotKeyCenter.shared.register(settings.navigationHotKey, for: .navigate) { [weak self] in self?.beginNavigation() }
    }

    /// The panel window on `screen`, for placing the peek preview next to it.
    func panelFrame(on screen: NSScreen) -> CGRect? {
        guard let displayID = screen.displayID else { return nil }
        return panels[displayID]?.panel.frame
    }

    // MARK: - Keyboard navigation

    /// Opens the panel under the pointer for arrow-key navigation: arrows or Tab move,
    /// Return switches to the window, Esc leaves.
    func beginNavigation() {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(mouse) }) ?? screens.first,
              let displayID = screen.displayID, let entry = panels[displayID] else { return }

        let windows = WindowEngine.shared.panelWindows(
            screenFrame: screen.frame, isMainScreen: screen == screens.first, isOnlyScreen: screens.count == 1
        )
        let arrangement = DockOrdering.arrange(windows, pinned: settings.pinnedApps,
                                               manualOrder: WindowEngine.shared.memory.manualOrder)
        navigationItems = arrangement.open + arrangement.minimized
        guard !navigationItems.isEmpty else { return }

        navigationPreviousApp = NSWorkspace.shared.frontmostApplication
        navigationDisplay = displayID
        let focused = WindowEngine.shared.focusedWindow
        navigationSelection = navigationItems.first { $0.id == focused }?.id ?? navigationItems.first?.id
        applyVisibility()

        NSApp.activate()
        entry.panel.makeKeyAndOrderFront(nil)
        if navigationMonitor == nil {
            navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleNavigationKey(event) ?? false }
                return handled ? nil : event
            }
        }
    }

    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard navigationSelection != nil else { return false }
        switch Int(event.keyCode) {
        case 123, 126: moveNavigation(-1)                         // ← ↑
        case 124, 125: moveNavigation(1)                          // → ↓
        case 48: moveNavigation(event.modifierFlags.contains(.shift) ? -1 : 1) // Tab
        case 36, 76, 49: endNavigation(activate: true)            // Return, Enter, Space
        case 53: endNavigation(activate: false)                   // Esc
        default: return false
        }
        return true
    }

    private func moveNavigation(_ delta: Int) {
        guard let current = navigationItems.firstIndex(where: { $0.id == navigationSelection }) else { return }
        let count = navigationItems.count
        navigationSelection = navigationItems[((current + delta) % count + count) % count].id
    }

    private func endNavigation(activate: Bool) {
        guard navigationSelection != nil || navigationMonitor != nil else { return }
        let target = navigationItems.first { $0.id == navigationSelection }
        if let navigationMonitor { NSEvent.removeMonitor(navigationMonitor) }
        navigationMonitor = nil
        navigationSelection = nil
        navigationDisplay = nil
        navigationItems = []
        applyVisibility()
        if activate, let target, WindowFocuser.focus(target) {
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            navigationPreviousApp?.activate()
        }
    }

    /// Shows every panel for a moment so a settings change can be seen.
    func preview() {
        previewUntil = Date().addingTimeInterval(Self.previewDuration)
        applyVisibility()
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: Self.previewDuration + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.previewUntil = nil
                self?.applyVisibility()
            }
        }
    }

    // MARK: - Panels

    private func rebuild() {
        for (_, entry) in panels { entry.panel.close() }
        panels.removeAll()
        revealed.removeAll()
        hideDeadlines.removeAll()
        revealedAt.removeAll()

        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() {
            guard let displayID = screen.displayID else { continue }
            let panel = DockPanel(frame: frame(for: screen))
            panel.contentView = FirstClickHostingView(rootView: DockView(
                displayID: displayID,
                screenFrame: screen.frame,
                isMainScreen: index == 0,
                isOnlyScreen: screens.count == 1
            // Tile geometry and edge placement are computed in screen coordinates; keep them
            // left-to-right in right-to-left languages too (text inside still flows naturally).
            ).environment(\.layoutDirection, .leftToRight))
            panels[displayID] = (screen, panel)
        }
        applyVisibility()
        configureAutoHide()
    }

    private func frame(for screen: NSScreen) -> NSRect {
        PanelLayout.frames(
            edge: settings.edge,
            thickness: settings.metrics.thickness(for: settings.edge, background: settings.showBackground),
            visibleFrame: panelArea(on: screen),
            autoHide: settings.autoHide,
            contentLength: screen.displayID.flatMap { contentLengths[$0] }
        ).panel
    }

    /// Where the panel may go: the visible frame, except that a full-screen app hides the menu
    /// bar, so a top panel then starts at the very top of the screen.
    private func panelArea(on screen: NSScreen) -> CGRect {
        var area = screen.visibleFrame
        guard settings.edge == .top, Self.showsFullScreenSpace(screen) else { return area }
        area.size.height = screen.frame.maxY - area.minY
        return area
    }

    private static func showsFullScreenSpace(_ screen: NSScreen) -> Bool {
        let shown = WindowEngine.shared.spaces.filter(\.isShown)
        let mine = shown.first { DisplayLookup.displayID(for: $0.display) == screen.displayID }
        // One shared set of spaces ("Displays have separate Spaces" off) has no display UUID.
        let space = mine ?? (screen == NSScreen.screens.first ? shown.first : nil)
        return space?.isFullScreen ?? false
    }

    /// The panel window covers only its tiles; it is resized whenever their length changes.
    func contentLengthChanged(_ length: CGFloat, on displayID: CGDirectDisplayID) {
        guard abs((contentLengths[displayID] ?? -1) - length) > 0.5 else { return }
        contentLengths[displayID] = length
        // Outside SwiftUI's layout pass, which reported the length.
        Task { @MainActor in
            guard let entry = self.panels[displayID] else { return }
            entry.panel.setFrame(self.frame(for: entry.screen), display: true)
        }
    }

    private func relayout() {
        for (_, entry) in panels {
            entry.panel.setFrame(frame(for: entry.screen), display: true)
        }
    }

    /// Re-place panels when layout settings change; SwiftUI content updates on its own.
    private func observeLayout() {
        withObservationTracking {
            _ = settings.size
            _ = settings.edge
            _ = settings.autoHide
            _ = settings.hotKey
            _ = settings.navigationHotKey
            _ = settings.keepWindowsClear
            // Entering or leaving a full-screen space moves a top panel.
            _ = WindowEngine.shared.spaces
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.registerHotKeys()
                self.relayout()
                self.applyVisibility()
                self.configureAutoHide()
                self.onLayoutChanged?()
                self.observeLayout()
            }
        }
    }

    /// Size, position and look changes preview the panel even while it auto-hides.
    private func observeAppearance() {
        withObservationTracking {
            _ = settings.size
            _ = settings.edge
            _ = settings.showBackground
            _ = settings.alwaysShowTitles
            _ = settings.labelOtherDesktops
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.preview()
                WindowEngine.shared.refreshAllThumbnails()
                self.observeAppearance()
            }
        }
    }

    // MARK: - Visibility

    private func applyVisibility() {
        for (displayID, entry) in panels {
            let previewing = previewUntil.map { $0 > Date() } ?? false
            let visible = previewing || !settings.autoHide || revealed.contains(displayID) || navigationDisplay == displayID
            setVisible(entry.panel, visible)
            if !visible { PeekController.shared.hide() }
        }
    }

    /// True while at least one panel is on screen.
    var isAnyPanelVisible: Bool {
        panels.values.contains { Self.isShown($0.panel) }
    }

    /// Only acts on a change (it used to run on every mouse move). A hidden panel stays ordered
    /// in, fully transparent: ordering it out would keep it from coming back on a full-screen
    /// app's space.
    private func setVisible(_ panel: DockPanel, _ visible: Bool) {
        guard visible != Self.isShown(panel) || (visible && !panel.isVisible) else { return }
        if visible && !Self.isShown(panel) { WindowEngine.shared.viewerAppeared() }
        panel.alphaValue = visible ? 1 : 0
        panel.ignoresMouseEvents = !visible
        if visible { panel.orderFrontRegardless() }
    }

    private static func isShown(_ panel: DockPanel) -> Bool { panel.isVisible && panel.alphaValue > 0 }

    // MARK: - Auto-hide

    /// Event-driven: reacts to pointer movement only, so there are no wake-ups while the
    /// mouse is still. Panels appear and disappear instantly (no animation).
    private func configureAutoHide() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        hideTimer?.invalidate()
        guard settings.autoHide else { return }

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAutoHide() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateAutoHide() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func updateAutoHide() {
        let pointer = NSEvent.mouseLocation
        // Most pointer movement is nowhere near a panel: nothing to do then.
        if revealed.isEmpty && hideDeadlines.isEmpty && zoneEnteredAt.isEmpty
            && !panels.values.contains(where: { $0.panel.frame.insetBy(dx: -48, dy: -48).contains(pointer) }) {
            return
        }
        let now = Date()

        for (displayID, entry) in panels {
            let inZone = PanelLayout.revealZones(edge: settings.edge, screenFrame: entry.screen.frame,
                                                 visibleFrame: panelArea(on: entry.screen),
                                                 panel: entry.panel.frame).contains { $0.contains(pointer) }
            let overPanel = entry.panel.frame.insetBy(dx: -12, dy: -12).contains(pointer)
            let isRevealed = revealed.contains(displayID)

            var inRevealZone = inZone
            if inZone && !isRevealed && settings.edge == .top {
                let entered = zoneEnteredAt[displayID] ?? now
                zoneEnteredAt[displayID] = entered
                inRevealZone = now.timeIntervalSince(entered) >= Self.topRevealDwell
                if !inRevealZone { scheduleDwellCheck(at: entered.addingTimeInterval(Self.topRevealDwell)) }
            } else if !inZone {
                zoneEnteredAt[displayID] = nil
            }

            if inRevealZone || (isRevealed && overPanel) {
                hideDeadlines[displayID] = nil
                if !isRevealed { revealedAt[displayID] = now }
                revealed.insert(displayID)
            } else if isRevealed {
                let deadline = hideDeadlines[displayID] ?? PanelLayout.hideDeadline(
                    revealedAt: revealedAt[displayID] ?? now, leftAt: now,
                    minimumVisible: Self.minimumRevealDuration, delay: settings.autoHideDelay)
                hideDeadlines[displayID] = deadline
                if now >= deadline {
                    hideDeadlines[displayID] = nil
                    revealed.remove(displayID)
                }
            }
        }
        applyVisibility()
        scheduleHideCheck()
    }

    /// A pointer resting at the top sends no more events: check once the dwell is over.
    private func scheduleDwellCheck(at date: Date) {
        guard dwellTimer == nil else { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: max(date.timeIntervalSinceNow, 0) + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dwellTimer = nil
                self?.updateAutoHide()
            }
        }
    }

    /// The pointer may stop right after leaving a panel: check again when the earliest
    /// hide deadline passes (one one-shot timer, not a polling loop).
    private func scheduleHideCheck() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let next = hideDeadlines.values.min() else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSinceNow, 0) + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAutoHide() }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
