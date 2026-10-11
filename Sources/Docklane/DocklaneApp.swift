import AppKit
import DocklaneCore
import SwiftUI

@main
struct DocklaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            QuickControls()
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel(Text(verbatim: "Docklane"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// The menu bar popover: the controls people reach for every day, one click away.
private struct QuickControls: View {
    @Bindable private var settings = AppSettings.shared
    private var panels: PanelController { .shared }
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(verbatim: "Docklane").font(.headline)
                Spacer()
                Button {
                    panels.toggle()
                } label: {
                    Label(settings.autoHide ? "Show Panel" : "Hide Panel",
                          systemImage: settings.autoHide ? "eye" : "eye.slash")
                }
                .help(settings.autoHide ? "Keep the panel always visible" : "Hide the panel until the pointer reaches the screen edge")
                .controlSize(.regular)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Panel size").font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.grid.1x2").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $settings.size, in: 0...1)
                    Image(systemName: "rectangle.grid.1x2.fill").foregroundStyle(.secondary)
                }
            }

            Picker("Panel position", selection: $settings.edge) {
                Text("Left").tag(PanelEdge.left)
                Text("Top").tag(PanelEdge.top)
                Text("Bottom").tag(PanelEdge.bottom)
                Text("Right").tag(PanelEdge.right)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show panel background", isOn: $settings.showBackground)
                Toggle("Always show window titles", isOn: $settings.alwaysShowTitles)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Picker("Window switcher shortcut", selection: $settings.switcherShortcut) {
                ForEach(SwitcherShortcut.allCases) { Text($0.title).tag($0) }
            }

            Menu {
                ForEach(WorkspaceManager.shared.profiles) { profile in
                    if let number = profile.hotKey {
                        Button(profile.name) { WorkspaceManager.shared.restore(profile) }
                            .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [.control, .option, .command])
                    } else {
                        Button(profile.name) { WorkspaceManager.shared.restore(profile) }
                    }
                }
                if !WorkspaceManager.shared.profiles.isEmpty { Divider() }
                Button("Save Layout…") { SaveWorkspaceDialog.run() }
                Button("Undo Last Arrangement") { WorkspaceManager.shared.undo() }
                    .keyboardShortcut("z", modifiers: [.control, .option])
                    .disabled(!WorkspaceManager.shared.canUndo)
            } label: {
                Label("Window Layouts", systemImage: "rectangle.3.group")
            }

            Divider()

            HStack {
                Button("Settings…") {
                    openSettings()
                    SettingsWindow.bringToFront()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit Docklane") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// The Settings window of an accessory app opens behind other apps and is not raised when it
/// is already open; activate Docklane and bring it to the front every time.
@MainActor
enum SettingsWindow {
    static func bringToFront() {
        NSApp.activate()
        Task { @MainActor in
            // The window is created asynchronously on first open.
            for _ in 0..<10 {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("Settings") == true && $0.isVisible }) {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissionsWindow = PermissionsWindow()
    private let clearance = WindowClearance()
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Permissions.allGranted {
            start()
        } else {
            permissionsWindow.show()
            Permissions.promptForMissing()
            waitForPermissions()
        }
    }

    private func waitForPermissions() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Permissions.allGranted else { return }
                self.permissionTimer?.invalidate()
                self.permissionsWindow.close()
                self.start()
            }
        }
    }

    private func start() {
        let engine = WindowEngine.shared
        let panels = PanelController.shared
        engine.onWindowsChanged = { [weak self] in
            self?.clearance.enforce(engine.windows)
            WorkspaceManager.shared.windowsChanged()
            LivePins.shared.windowsChanged(engine.windows)
        }
        engine.isAnyoneLooking = { panels.isAnyPanelVisible || WindowSwitcher.shared.isOpen || DesktopSwitcher.shared.isOpen }
        panels.onLayoutChanged = { [weak self] in self?.clearance.enforce(engine.windows) }
        engine.start()
        panels.start()
        WindowSwitcher.shared.start()
        DesktopSwitcher.shared.start()
        WorkspaceManager.shared.start()
        KeyboardPlacer.start()
        WindowRules.start()
    }
}
