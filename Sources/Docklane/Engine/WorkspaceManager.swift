import AppKit
import Carbon.HIToolbox
import DocklaneCore
import Observation

/// Window memory: named workspaces (save the layout, bring it back from the menu or with
/// ⌃⌥⌘1–9, optionally hiding everything else), the last layout of each set of displays
/// (restored when a display is connected or disconnected), and Undo (⌃⌥Z) for any of these.
@MainActor
@Observable
final class WorkspaceManager {
    static let shared = WorkspaceManager()

    private(set) var library: WorkspaceLibrary
    private(set) var restoringID: UUID?
    private(set) var canUndo = false

    @ObservationIgnored private var history = LayoutHistory()
    @ObservationIgnored private var recorder = LayoutRecorder()
    @ObservationIgnored private var displayLayouts: DisplayLayoutStore
    @ObservationIgnored private var displaySetKey = ""
    @ObservationIgnored private var displayChange: Task<Void, Never>?

    private static let key = "workspaces"
    private static let displayLayoutsKey = "displayLayouts"
    private static let undoHotKeyID: UInt32 = 110
    private static func workspaceHotKeyID(_ number: Int) -> UInt32 { UInt32(100 + number) }
    private static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    private init() {
        library = WorkspaceLibrary.load(from: .standard, key: Self.key)
        displayLayouts = DisplayLayoutStore.load(from: .standard, key: Self.displayLayoutsKey)
    }

    var profiles: [WorkspaceProfile] { library.profiles }

    func start() {
        registerHotKeys()
        displaySetKey = WindowLayoutMath.displaySetKey(Displays.current())
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberCurrentDisplayLayout() }
        }
    }

    // MARK: - Workspaces

    enum SaveResult { case saved, missingName, noWindows }

    @discardableResult
    func saveCurrentLayout(named name: String) -> SaveResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missingName }
        let windows = currentLayout()
        guard !windows.isEmpty else { return .noWindows }
        // Saving under an existing name replaces that profile, keeping its shortcut and options.
        let previous = library.profiles.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        library.profiles.removeAll { $0.id == previous?.id }
        let hotKey = previous?.hotKey ?? WorkspaceProfile.freeHotKey(among: library.profiles)
        library.profiles.append(WorkspaceProfile(name: trimmed, windows: windows, hotKey: hotKey,
                                                 hidesOthers: previous?.hidesOthers))
        persist()
        return .saved
    }

    /// False when the name is empty or another layout already has it.
    @discardableResult
    func rename(_ profile: WorkspaceProfile, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !library.profiles.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }),
              let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        library.profiles[index].name = trimmed
        persist()
        return true
    }

    /// Replaces the layout's windows with the current ones; name, shortcut and options stay.
    @discardableResult
    func update(_ profile: WorkspaceProfile) -> SaveResult {
        let windows = currentLayout()
        guard !windows.isEmpty else { return .noWindows }
        guard let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else { return .saved }
        let old = library.profiles[index]
        library.profiles[index] = WorkspaceProfile(id: old.id, name: old.name, createdAt: old.createdAt, windows: windows,
                                                   hotKey: old.hotKey, hidesOthers: old.hidesOthers)
        persist()
        return .saved
    }

    func delete(_ profile: WorkspaceProfile) {
        library.profiles.removeAll { $0.id == profile.id }
        persist()
    }

    func setHotKey(_ number: Int?, for profile: WorkspaceProfile) {
        for index in library.profiles.indices {
            if library.profiles[index].id == profile.id {
                library.profiles[index].hotKey = number
            } else if number != nil, library.profiles[index].hotKey == number {
                library.profiles[index].hotKey = nil  // one workspace per number
            }
        }
        persist()
    }

    func setHidesOthers(_ hides: Bool, for profile: WorkspaceProfile) {
        guard let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        library.profiles[index].hidesOthers = hides
        persist()
    }

    func restore(_ profile: WorkspaceProfile) {
        guard restoringID == nil else { return }
        restoringID = profile.id
        Task {
            let report = await apply(profile.windows, launchMissing: true, hideOthers: profile.hidesOthers == true)
            restoringID = nil
            if !report.isComplete { RestoreReportAlert.show(report, layout: profile.name) }
        }
    }

    // MARK: - Undo

    func undo() {
        guard restoringID == nil, let layout = history.pop() else { return }
        canUndo = !history.entries.isEmpty
        Task { await apply(layout, launchMissing: false, hideOthers: false, recordUndo: false) }
    }

    /// Call before Docklane moves windows on its own, so ⌃⌥Z can put them back.
    func recordUndoPoint() {
        history.push(currentLayout())
        canUndo = !history.entries.isEmpty
    }

    // MARK: - Displays

    /// Called whenever the window list changes (moves included).
    func windowsChanged() {
        recorder.record(currentLayout(), at: Date())
    }

    private func displaysChanged() {
        let newKey = WindowLayoutMath.displaySetKey(Displays.current())
        guard newKey != displaySetKey else { return }
        // macOS starts piling windows up as the display changes: use the layout from before.
        if let before = recorder.layout(before: Date().addingTimeInterval(-2)) {
            displayLayouts.layouts[displaySetKey] = before
        }
        displaySetKey = newKey
        displayLayouts.save(to: .standard, key: Self.displayLayoutsKey)

        displayChange?.cancel()
        guard AppSettings.shared.rememberDisplayLayouts, let saved = displayLayouts.layouts[newKey] else { return }
        displayChange = Task {
            // Let macOS finish rearranging before putting the windows back.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await apply(saved, launchMissing: false, hideOthers: false)
        }
    }

    private func rememberCurrentDisplayLayout() {
        let layout = currentLayout()
        guard !layout.isEmpty else { return }
        displayLayouts.layouts[displaySetKey] = layout
        displayLayouts.save(to: .standard, key: Self.displayLayoutsKey)
    }

    // MARK: - Capture and apply

    /// Every visible window with its frame, display and place on that display.
    func currentLayout() -> [SavedWindow] {
        let displays = Displays.current()
        return WindowEngine.shared.windows
            .filter { !$0.isMinimized && !$0.bundleID.isEmpty }
            .map { window in
                let frame = WindowActions.cocoaFrame(of: window)
                let display = WindowLayoutMath.display(for: frame, among: displays)
                return SavedWindow(bundleID: window.bundleID, appName: window.appName, title: window.title,
                                   frame: frame, display: display?.id,
                                   relativeFrame: display.map { WindowLayoutMath.relative(frame, in: $0.visibleFrame) })
            }
    }

    /// Opens missing apps (waiting until their windows appear, up to 10 s), then moves each
    /// window to its saved place on the displays connected now.
    @discardableResult
    private func apply(_ layout: [SavedWindow], launchMissing: Bool, hideOthers: Bool, recordUndo: Bool = true) async -> RestoreReport {
        if recordUndo { recordUndoPoint() }
        let wanted = Set(layout.map(\.bundleID))
        var notInstalled = Set<String>()
        if launchMissing {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let missing = wanted.subtracting(running)
            for bundleID in missing {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                    notInstalled.insert(bundleID)
                    continue
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            }
            let launched = missing.subtracting(notInstalled)
            if !launched.isEmpty { await waitForWindows(of: launched) }
        }
        if hideOthers {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
                && app.processIdentifier != getpid() && !wanted.contains(app.bundleIdentifier ?? "") {
                app.hide()
            }
        }
        let engine = WindowEngine.shared
        engine.refresh()
        let displays = Displays.current()
        let pairs = WorkspaceMatcher.match(saved: layout, live: engine.windows)
        for pair in pairs {
            WindowActions.fill(pair.window, frame: WindowLayoutMath.resolve(pair.saved, displays: displays),
                               restoreIfMinimized: true)
        }
        engine.scheduleRefresh(after: .milliseconds(400))
        return RestoreReport(saved: layout, missingBundleIDs: notInstalled,
                             placedBundleIDs: Set(pairs.map(\.window.bundleID)), placedWindows: pairs.count)
    }

    private func waitForWindows(of bundleIDs: Set<String>) async {
        let engine = WindowEngine.shared
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            engine.refresh()
            let ready = Set(engine.windows.map(\.bundleID))
            if bundleIDs.isSubset(of: ready) { return }
        }
    }

    // MARK: - Shortcuts

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        let modifiers = controlKey | optionKey | cmdKey
        for number in 1...9 { center.unregister(id: Self.workspaceHotKeyID(number)) }
        for profile in library.profiles {
            guard let number = profile.hotKey, (1...9).contains(number) else { continue }
            let id = profile.id
            center.register(id: Self.workspaceHotKeyID(number), keyCode: Self.digitKeys[number - 1], modifiers: modifiers) { [weak self] in
                guard let self, let profile = self.library.profiles.first(where: { $0.id == id }) else { return }
                self.restore(profile)
            }
        }
        center.register(id: Self.undoHotKeyID, keyCode: kVK_ANSI_Z, modifiers: controlKey | optionKey) { [weak self] in
            self?.undo()
        }
    }

    private func persist() {
        library.save(to: .standard, key: Self.key)
        registerHotKeys()
    }
}

/// Connected displays for layouts.
@MainActor
enum Displays {
    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return DisplayInfo(id: text, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}

/// Asks for a layout name, then saves the current layout; says why when nothing could be saved.
@MainActor
enum SaveWorkspaceDialog {
    static func run() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Window Layout")
        alert.informativeText = String(localized: "Saves the open apps and where each window is. Layout name:")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "e.g. Work, Meeting")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        while alert.runModal() == .alertFirstButtonReturn {
            switch WorkspaceManager.shared.saveCurrentLayout(named: field.stringValue) {
            case .saved: return
            case .missingName: alert.informativeText = String(localized: "Enter a layout name to save.")
            case .noWindows:
                alert.informativeText = String(localized: "There are no open windows to save.")
            }
        }
    }
}

/// Tells what could not be brought back when a layout opened only partly.
@MainActor
enum RestoreReportAlert {
    static func show(_ report: RestoreReport, layout: String) {
        let alert = NSAlert()
        alert.messageText = report.placedNothing
            ? String(localized: "“\(layout)” couldn't be opened")
            : String(localized: "“\(layout)” opened in part")
        var lines: [String] = []
        let list = { (names: [String]) in ListFormatter.localizedString(byJoining: names) }
        if !report.notInstalled.isEmpty {
            lines.append(String(localized: "Not installed on this Mac: \(list(report.notInstalled))."))
        }
        if !report.withoutWindows.isEmpty {
            lines.append(String(localized: "Opened no window to put back: \(list(report.withoutWindows))."))
        }
        if !report.placedNothing {
            lines.append(String(localized: "The other windows were put back in place."))
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }
}
