import AppKit
import DocklaneCore
import Observation

/// Single source of truth for the panel: the window list in a stable order, thumbnails,
/// focus, Dock badges and the user's manual layout.
///
/// Accessibility and workspace events trigger a refresh shortly after (a Space change once its
/// slide is over); a light scan catches anything events miss (every 2 s while the panel or a
/// switcher is on screen, 6 s otherwise), and a viewer that appears refreshes first if anything
/// is pending. Thumbnails, audio and badges are only taken while something shows them.
/// Everything pauses while displays sleep or the session is locked.
@MainActor
@Observable
final class WindowEngine {
    static let shared = WindowEngine()

    private(set) var windows: [DockWindow] = []
    private(set) var thumbnails: [WindowNumber: NSImage] = [:]
    private(set) var focusedWindow: WindowNumber?
    /// Every desktop and full-screen space, in Mission Control order.
    private(set) var spaces: [SpaceInfo] = []
    /// Space ids, most recently shown first (for the desktop switcher).
    @ObservationIgnored private(set) var recentSpaces: [UInt64] = []
    private(set) var badges: [String: String] = [:]
    /// Bundle identifiers of processes playing sound (helpers included).
    private(set) var audioBundles: Set<String> = []
    private(set) var memory: LayoutMemory

    /// Called after the window list changed (used to keep windows clear of the panel).
    @ObservationIgnored var onWindowsChanged: (() -> Void)?
    /// Windows that appeared since the last scan (not the ones found when Docklane started).
    @ObservationIgnored var onWindowsAdded: (([DockWindow]) -> Void)?
    @ObservationIgnored private var hasScanned = false
    /// Called when a window of `pid` moved or was resized.
    @ObservationIgnored var onGeometryChanged: ((pid_t) -> Void)?
    /// Whether any thumbnail is on screen (panel visible or switcher open). Periodic captures
    /// are skipped while nobody can see them; showing the panel refreshes them right away.
    @ObservationIgnored var isAnyoneLooking: () -> Bool = { true }
    @ObservationIgnored private var lastFullRefresh = Date.distantPast

    /// Most recently focused windows first (for the window switcher).
    @ObservationIgnored private var recentWindows = RecentWindows()
    /// Apps by activation, most recent first (orders apps without windows in the switcher).
    @ObservationIgnored private var recentAppPIDs: [pid_t] = []
    @ObservationIgnored private let capturer = WindowCapturer()
    @ObservationIgnored private var fingerprints: [WindowNumber: UInt64] = [:]
    /// When each thumbnail was last taken.
    @ObservationIgnored private var captureDates: [WindowNumber: Date] = [:]
    /// Captures under way: a window already being captured is not asked for again.
    @ObservationIgnored private var capturing: Set<WindowNumber> = []
    /// Windows whose capture failed recently: not retried for `failureBackoff` (a failed
    /// single-frame capture falls back to a costly ScreenCaptureKit query).
    @ObservationIgnored private var captureFailures: [WindowNumber: Date] = [:]
    private static let failureBackoff: TimeInterval = 10
    /// For diagnostics: captures since launch.
    @ObservationIgnored private(set) var capturesSucceeded = 0
    @ObservationIgnored private(set) var capturesFailed = 0
    @ObservationIgnored private(set) var lastCaptureFailure: Date?
    @ObservationIgnored private var watcher: AppEventWatcher?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var scanTicks = 0
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    /// Something changed that only matters once a viewer appears (focus moved while nobody
    /// looked); the next viewer refreshes first.
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var pendingMemoryRelief: Task<Void, Never>?
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var isStarted = false

    private static let memoryKey = "layoutMemory"
    private static let scanInterval: TimeInterval = 2
    private static let badgeInterval: TimeInterval = 5
    /// While something shows thumbnails, those older than this are taken again; nothing is
    /// captured while nobody looks.
    static let thumbnailMaxAge: TimeInterval = 30
    private static let thumbnailInterval: TimeInterval = 30

    private init() {
        memory = LayoutMemory.load(from: .standard, key: Self.memoryKey)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let watcher = AppEventWatcher { [weak self] event in self?.handle(event) }
        watcher.sync()
        self.watcher = watcher

        observeWorkspace()
        refresh()
        // No thumbnails yet: they are taken when the panel or a switcher first appears.

        timers = [
            // Changes arrive as events; the scan is a safety net, every 2 s while someone looks
            // at Docklane and every 6 s otherwise.
            repeating(Self.scanInterval) { engine in
                engine.scanTicks += 1
                guard engine.isAnyoneLooking() || engine.scanTicks % 3 == 0 else { return }
                engine.refresh()
            },
            repeating(Self.badgeInterval) { engine in
                guard engine.isAnyoneLooking() else { return }
                engine.refreshIndicators()
            },
            repeating(Self.thumbnailInterval) { engine in
                guard engine.isAnyoneLooking() else { return }
                engine.refreshStaleThumbnails()
            },
        ]
    }

    // MARK: - Window list

    /// Coalesces bursts of events into one refresh.
    /// Freed thumbnails leave dirty pages in the allocator; once windows stop closing, hand
    /// the free pages back to the system so the footprint returns to its resting size.
    private func scheduleMemoryRelief() {
        pendingMemoryRelief?.cancel()
        pendingMemoryRelief = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    func scheduleRefresh(after delay: Duration = .milliseconds(60)) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Brings the list up to date now if a refresh is waiting, so a panel or switcher that
    /// just opened never shows a list from before the last change.
    func refreshIfPending() {
        guard pendingRefresh != nil || needsRefresh else { return }
        refresh()
    }

    func refresh() {
        guard !isPaused else { return }
        pendingRefresh?.cancel()
        pendingRefresh = nil
        needsRefresh = false
        let catalog = WindowCatalog.snapshot(knownMinimized: Set(windows.lazy.filter(\.isMinimized).map(\.id)))
        let snapshot = catalog.windows
        if catalog.spaces != spaces {
            spaces = catalog.spaces
            let shown = catalog.spaces.filter(\.isShown).map(\.id)
            recentSpaces = shown + recentSpaces.filter { !shown.contains($0) }
        }
        let previous = windows
        let merged = Self.merge(previous: previous, snapshot: snapshot)

        // Drop the thumbnail of every window that vanished, including those of apps that quit.
        let current = Set(merged.map(\.id))
        let vanished = previous.filter { !current.contains($0.id) }
        for window in vanished {
            thumbnails[window.id] = nil
            fingerprints[window.id] = nil
            captureDates[window.id] = nil
            captureFailures[window.id] = nil
        }
        if !vanished.isEmpty { scheduleMemoryRelief() }
        // Windows that vanished while their app keeps running were closed: forget their
        // manual position and label so a reused window number can't inherit them.
        let closed = vanished.filter { NSRunningApplication(processIdentifier: $0.pid) != nil }
        if !closed.isEmpty {
            memory.forget(Set(closed.map(\.id)))
            saveMemory()
        }

        if merged != previous {
            windows = merged
            let known = Set(previous.map(\.id))
            let added = merged.filter { !known.contains($0.id) }
            if hasScanned && !added.isEmpty { onWindowsAdded?(added) }
            if !added.isEmpty && isAnyoneLooking() { refreshThumbnails(added) }
            onWindowsChanged?()
        }
        hasScanned = true
        updateFocus()
    }

    /// The panel or a switcher just appeared: bring what it shows up to date.
    func viewerAppeared() {
        refreshIfPending()
        refreshStaleThumbnails()
        refreshIndicators()
    }

    /// Audio and Dock badges, read only while something shows them.
    func refreshIndicators() {
        refreshAudio()
        refreshBadges()
    }

    private func refreshAudio() {
        let playing = AppSettings.shared.showAudioIndicator ? AudioActivity.playingBundleIDs() : []
        if playing != audioBundles { audioBundles = playing }
    }

    func isPlayingAudio(_ window: DockWindow) -> Bool {
        AudioActivity.isPlaying(window.bundleID, in: audioBundles)
    }

    /// Windows a panel on `screenFrame` shows. With several displays each panel shows the
    /// windows centred on its display (windows on no display go to the main one); the
    /// "this desktop only" setting drops windows on other desktops and full-screen spaces.
    func panelWindows(screenFrame: CGRect, isMainScreen: Bool, isOnlyScreen: Bool) -> [DockWindow] {
        var result = windows
        if AppSettings.shared.panelCurrentDesktopOnly {
            result = result.filter { $0.space == .current }
        }
        guard !isOnlyScreen, let mainHeight = NSScreen.screens.first?.frame.height else { return result }
        let screens = NSScreen.screens.map(\.frame)
        return result.filter { window in
            let center = CGPoint(x: window.bounds.midX, y: mainHeight - window.bounds.midY)
            if screenFrame.contains(center) { return true }
            return isMainScreen && !screens.contains { $0.contains(center) }
        }
    }

    /// Keeps the existing order (so tiles don't jump when z-order changes) and appends new
    /// windows in the order the WindowServer reports them.
    static func merge(previous: [DockWindow], snapshot: [DockWindow]) -> [DockWindow] {
        let byID = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = previous.compactMap { byID[$0.id] }
        let kept = Set(result.map(\.id))
        result.append(contentsOf: snapshot.filter { !kept.contains($0.id) })
        return result
    }

    private func updateFocus() {
        // Docklane's own panels (⌘Tab, menus) are not windows of the list; keep the last real one.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() else { return }
        let focused = AccessibilityInspector.focusedWindowNumber()
        guard focused != focusedWindow else { return }
        let previous = focusedWindow
        focusedWindow = focused
        if let focused {
            recentWindows.focused(focused)
        }
        // "Last seen" image of the window the user left, fresh image of the new one — only
        // while the panel or a switcher is on screen; otherwise they refresh when one appears.
        let changed = windows.filter { $0.id == previous || $0.id == focused }
        if !changed.isEmpty && isAnyoneLooking() {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.refreshThumbnails(changed)
            }
        }
    }

    /// Window switcher order: most recently used first, then the rest in panel order,
    /// minimized windows last.
    func switcherOrder() -> [DockWindow] {
        let source = AppSettings.shared.switcherCurrentDesktopOnly ? windows.filter { $0.space == .current } : windows
        let ordered = byRecency(source)
        guard AppSettings.shared.switcherShowsAppsWithoutWindows else { return ordered }
        // Apps own no desktop, so they are listed whatever the desktop filter says; an app with
        // windows only on another desktop is not "without windows".
        let apps = AppDirectory.shared.regularApps.values.map {
            WindowlessApps.App(pid: $0.pid, bundleID: $0.bundleID, name: $0.name)
        }
        let standIns = WindowlessApps.standIns(apps: apps, windows: windows, recentPIDs: recentAppPIDs)
        return WindowlessApps.inserting(standIns, into: ordered)
    }

    /// Every window, most recently used first, minimized windows last.
    func windowsByRecency() -> [DockWindow] { byRecency(windows) }

    private func byRecency(_ source: [DockWindow]) -> [DockWindow] { recentWindows.sorted(source) }

    // MARK: - Thumbnails

    func refreshAllThumbnails() {
        lastFullRefresh = Date()
        refreshThumbnails(windows)
    }

    /// Takes again only the thumbnails that are missing or older than `thumbnailMaxAge`.
    func refreshStaleThumbnails(among targets: [DockWindow]? = nil) {
        let now = Date()
        let stale = (targets ?? windows).filter { window in
            guard let taken = captureDates[window.id] else { return true }
            return now.timeIntervalSince(taken) > Self.thumbnailMaxAge
        }
        refreshThumbnails(stale)
    }

    func refreshThumbnails(_ targets: [DockWindow]) {
        // Without Screen Recording every capture fails; don't keep asking.
        guard !isPaused, PermissionMonitor.shared.state.screenRecording else { return }
        let now = Date()
        let wanted = targets.filter { window in
            !window.isAppWithoutWindows && !capturing.contains(window.id)
                && (captureFailures[window.id].map { now.timeIntervalSince($0) > Self.failureBackoff } ?? true)
        }
        guard !wanted.isEmpty else { return }
        capturing.formUnion(wanted.map(\.id))
        let bounds = thumbnailPixelSizes(wanted)
        Task { [weak self, capturer] in
            let images = await capturer.capture(wanted, within: bounds)
            guard let self else { return }
            self.capturing.subtract(wanted.map(\.id))
            let failedAt = Date()
            for window in wanted where images[window.id] == nil { self.captureFailures[window.id] = failedAt }
            self.capturesSucceeded += images.count
            let failed = wanted.count - images.count
            if failed > 0 {
                self.capturesFailed += failed
                self.lastCaptureFailure = failedAt
            }
            for id in images.keys { self.captureFailures[id] = nil }
            self.apply(images)
        }
    }

    /// Thumbnails are captured only as large as a panel tile or switcher card shows them.
    private func thumbnailPixelSizes(_ targets: [DockWindow]) -> [WindowNumber: CGSize] {
        let settings = AppSettings.shared
        let metrics = settings.metrics
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return Dictionary(targets.map { window in
            (window.id, metrics.thumbnailPixelSize(for: window.bounds.size, edge: settings.edge, scale: scale,
                                                   otherImage: SwitcherLayout.thumbnailSize))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func apply(_ images: [WindowNumber: WindowImage]) {
        let live = Set(windows.map(\.id))
        let now = Date()
        for id in images.keys where live.contains(id) { captureDates[id] = now }
        for (id, image) in images where live.contains(id)
            && (fingerprints[id] != image.fingerprint || thumbnails[id]?.size != image.size) {
            fingerprints[id] = image.fingerprint
            thumbnails[id] = NSImage(cgImage: image.cgImage, size: image.size)
        }
    }

    // MARK: - Badges

    private func refreshBadges() {
        guard !isPaused else { return }
        let latest = DockBadgeReader.badges()
        if latest != badges { badges = latest }
    }

    // MARK: - Layout memory

    func label(for window: DockWindow) -> String? { memory.label(for: window) }

    func setLabel(_ text: String?, for window: DockWindow) {
        memory.setLabel(text, for: window)
        saveMemory()
    }

    func move(_ window: WindowNumber, before target: WindowNumber?, currentOrder: [WindowNumber]) {
        memory.move(window, before: target, currentOrder: currentOrder)
        saveMemory()
    }

    func resetOrder() {
        memory.resetOrder()
        saveMemory()
    }

    private func saveMemory() {
        memory.save(to: .standard, key: Self.memoryKey)
    }

    // MARK: - Events

    private func handle(_ event: AppEventWatcher.Event) {
        switch event {
        case .windowsChanged:
            scheduleRefresh()
        case .focusChanged:
            updateFocus()
            // Focus moves all the time; a full scan only matters to something on screen.
            if isAnyoneLooking() { scheduleRefresh(after: .milliseconds(150)) } else { needsRefresh = true }
        case .geometryChanged(let pid):
            onGeometryChanged?(pid)
            scheduleRefresh(after: .milliseconds(300))
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let appEvents: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in appEvents {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    AppDirectory.shared.invalidate()
                    self?.watcher?.sync()
                    self?.scheduleRefresh(after: .milliseconds(300))
                }
            }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid, pid != getpid() {
                    self.recentAppPIDs.removeAll { $0 == pid }
                    self.recentAppPIDs.insert(pid, at: 0)
                    self.recentAppPIDs = Array(self.recentAppPIDs.prefix(100))
                }
                self.updateFocus()
            }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // After the slide: scanning during it competes with the transition for the
                // window server and the apps being asked. A viewer opening sooner refreshes first.
                self.scheduleRefresh(after: .milliseconds(350))
                if self.isAnyoneLooking() {
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard let self, self.isAnyoneLooking() else { return }
                        self.refreshThumbnails(self.windows.filter(\.isOnScreen))
                    }
                }
            }
        }

        let pause: [Notification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
        let resume: [Notification.Name] = [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pause {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPaused = true }
            }
        }
        for name in resume {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPaused = true }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
    }

    /// Accessibility came back: observers made without it never fire, so subscribe again.
    func accessibilityRestored() {
        watcher?.unwatchAll()
        watcher?.sync()
        refresh()
    }

    private func resume() {
        isPaused = false
        refresh()
    }

    private func repeating(_ interval: TimeInterval, _ action: @escaping @MainActor (WindowEngine) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        timer.tolerance = interval * 0.2 // lets macOS batch wake-ups
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
