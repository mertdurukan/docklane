import AppKit
import DocklaneCore
import Observation

/// Saves the current window layout under a name and brings it back: opens apps that are not
/// running, then moves each window (matched by title, else by app) to its saved frame.
@MainActor
@Observable
final class WorkspaceManager {
    static let shared = WorkspaceManager()

    private(set) var library: WorkspaceLibrary
    private(set) var restoringID: UUID?

    private static let key = "workspaces"

    private init() {
        library = WorkspaceLibrary.load(from: .standard, key: Self.key)
    }

    var profiles: [WorkspaceProfile] { library.profiles }

    func saveCurrentLayout(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let windows = WindowEngine.shared.windows
            .filter { !$0.isMinimized && !$0.bundleID.isEmpty }
            .map { SavedWindow(bundleID: $0.bundleID, appName: $0.appName, title: $0.title,
                               frame: WindowActions.cocoaFrame(of: $0)) }
        guard !windows.isEmpty else { return }
        // Saving under an existing name replaces that profile.
        library.profiles.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        library.profiles.append(WorkspaceProfile(name: trimmed, windows: windows))
        persist()
    }

    func delete(_ profile: WorkspaceProfile) {
        library.profiles.removeAll { $0.id == profile.id }
        persist()
    }

    func restore(_ profile: WorkspaceProfile) {
        guard restoringID == nil else { return }
        restoringID = profile.id
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let missing = profile.bundleIDs.filter { !running.contains($0) }
        for bundleID in missing {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }

        Task { [weak self] in
            // Give freshly launched apps time to open their windows.
            if !missing.isEmpty { try? await Task.sleep(for: .seconds(2.5)) }
            let engine = WindowEngine.shared
            engine.refresh()
            for pair in WorkspaceMatcher.match(saved: profile.windows, live: engine.windows) {
                WindowActions.fill(pair.window, frame: pair.saved.frame, restoreIfMinimized: true)
            }
            engine.scheduleRefresh(after: .milliseconds(400))
            self?.restoringID = nil
        }
    }

    private func persist() {
        library.save(to: .standard, key: Self.key)
    }
}

/// Asks for a workspace name, then saves the current layout.
@MainActor
enum SaveWorkspaceDialog {
    static func run() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Workspace")
        alert.informativeText = String(localized: "Save the current window layout as:")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Work")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            WorkspaceManager.shared.saveCurrentLayout(named: field.stringValue)
        }
    }
}
