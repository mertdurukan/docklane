import AppKit
import DocklaneCore
import ServiceManagement
import SwiftUI

/// The Settings window (⌘,), in tabs like System Settings panes.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintbrush") }
            BehaviorSettings().tabItem { Label("Behavior", systemImage: "cursorarrow.motionlines") }
            AppsSettings().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            WorkspacesSettings().tabItem { Label("Workspaces", systemImage: "rectangle.3.group") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .onAppear { NSApp.activate() }
    }
}

private struct AppearanceSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Size") {
                    HStack {
                        Text("Small").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.size, in: 0...1)
                        Text("Large").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Position on screen", selection: $settings.edge) {
                    Text("Left").tag(PanelEdge.left)
                    Text("Top").tag(PanelEdge.top)
                    Text("Bottom").tag(PanelEdge.bottom)
                    Text("Right").tag(PanelEdge.right)
                }
                .pickerStyle(.segmented)
                if settings.dockSharesEdge {
                    Label("The macOS Dock is on the same edge, so both appear together. Move it in System Settings → Desktop & Dock.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("Show background", isOn: $settings.showBackground)
                Toggle("Always show window titles", isOn: $settings.alwaysShowTitles)
                Toggle("Label windows on other desktops", isOn: $settings.labelOtherDesktops)
                Toggle("Show a speaker on apps playing sound", isOn: $settings.showAudioIndicator)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BehaviorSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Automatically hide and show the panel", isOn: $settings.autoHide)
                if settings.autoHide {
                    LabeledContent("Hide after") {
                        HStack {
                            Slider(value: $settings.autoHideDelay, in: 0...1.5, step: 0.1)
                            Text(String(format: "%.1f s", settings.autoHideDelay))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Toggle("Keep windows clear of the panel", isOn: $settings.keepWindowsClear)
                    .disabled(settings.autoHide)
                    .help("Only while the panel is always visible.")
                Toggle("Only show windows from the current desktop", isOn: $settings.panelCurrentDesktopOnly)
                Toggle("Click the front window's tile to minimize it", isOn: $settings.minimizeOnFrontClick)
            } header: {
                Text("Panel")
            }
            Section {
                Toggle("Show a large preview when hovering a tile", isOn: $settings.peekEnabled)
                if settings.peekEnabled {
                    LabeledContent("Preview after") {
                        HStack {
                            Slider(value: $settings.peekDelay, in: 0.2...2, step: 0.1)
                            Text(String(format: "%.1f s", settings.peekDelay))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Preview")
            }
            Section {
                Picker("Window switcher", selection: $settings.switcherShortcut) {
                    ForEach(SwitcherShortcut.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Only show windows from the current desktop", isOn: $settings.switcherCurrentDesktopOnly)
                    .disabled(settings.switcherShortcut == .off)
                Toggle("Desktop switcher (\(settings.switcherShortcut.desktopTitle))", isOn: $settings.desktopSwitcherEnabled)
            } header: {
                Text("Window switcher")
            } footer: {
                Text("Hold the key and press Tab to move between windows; release to switch. Press F to search. Esc cancels; Q quits, C minimizes all of the app's windows, W closes and M minimizes.")
            }
            Section {
                Picker("Show / hide panel", selection: $settings.hotKey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Navigate the panel with the keyboard", selection: $settings.navigationHotKey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Keyboard navigation: arrows or Tab move, Return switches, Esc leaves.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppsSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                if settings.pinnedApps.isEmpty {
                    Text("Right-click a window and choose Keep in Dock to pin its app.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(settings.pinnedApps, id: \.self) { bundleID in
                            HStack {
                                if let app = PinnedApp(bundleID: bundleID) {
                                    Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                                    Text(verbatim: app.name)
                                } else {
                                    Text(verbatim: bundleID).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    settings.togglePinned(bundleID)
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from Dock")
                            }
                        }
                        .onMove { settings.pinnedApps.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(minHeight: 120)
                }
            } header: {
                Text("Pinned apps")
            } footer: {
                Text("Pinned apps come first and stay in the panel even without windows. Drag to reorder.")
            }
            Section {
                if settings.privateApps.isEmpty {
                    Text("Right-click a window and choose Hide Preview to blur that app's previews.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.privateApps, id: \.self) { bundleID in
                        HStack {
                            if let app = PinnedApp(bundleID: bundleID) {
                                Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                                Text(verbatim: app.name)
                            } else {
                                Text(verbatim: bundleID).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                settings.togglePrivate(bundleID)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Show Preview")
                        }
                    }
                }
            } header: {
                Text("Hidden previews")
            } footer: {
                Text("Previews of these apps are blurred in the panel, the switcher and the large preview.")
            }
            Section {
                Toggle("Show pinned apps on all displays", isOn: $settings.pinnedOnAllDisplays)
                Button("Reset tile order") { WindowEngine.shared.resetOrder() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WorkspacesSettings: View {
    private var workspaces: WorkspaceManager { .shared }
    @Bindable private var settings = AppSettings.shared
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Name", text: $newName, prompt: Text("Work"))
                        .onSubmit(save)
                    Button("Save Current Layout", action: save)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Saves which apps are open and where each window is. Restoring opens missing apps and moves the windows back.")
            }
            Section {
                if settings.windowRules.isEmpty {
                    Text("No rules yet.").foregroundStyle(.secondary)
                }
                ForEach($settings.windowRules) { $rule in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                        }
                        Text(verbatim: rule.appName)
                        Spacer()
                        Picker("", selection: $rule.placement) {
                            ForEach(PlacementPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            settings.windowRules.removeAll { $0.bundleID == rule.bundleID }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete")
                    }
                }
                Menu("Add Rule") {
                    ForEach(ruleCandidates, id: \.bundleID) { app in
                        Button(app.name) {
                            settings.windowRules.append(WindowRule(bundleID: app.bundleID, appName: app.name, placement: .leftHalf))
                        }
                    }
                }
                .fixedSize()
                .disabled(ruleCandidates.isEmpty)
            } header: {
                Text("App rules")
            } footer: {
                Text("New windows of these apps are put in place as soon as they open.")
            }
            Section {
                Toggle("Arrange windows with ⌃⌥ and the arrow keys", isOn: $settings.keyboardPlacement)
            } footer: {
                Text("⌃⌥← → ↑ ↓ put the front window in a half; press again for a third, then two thirds. ⌃⌥↩ fills the screen, ⌃⌥C centers the window, ⌃⌥⌘← → move it to the other display.")
            }
            Section {
                Toggle("Remember window layouts per display setup", isOn: $settings.rememberDisplayLayouts)
                Button("Undo Layout Change") { workspaces.undo() }
                    .disabled(!workspaces.canUndo)
            } footer: {
                Text("When a display is connected or disconnected, windows go back to where they were the last time you used those displays.")
            }
            Section {
                if workspaces.profiles.isEmpty {
                    Text("No saved workspaces yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(workspaces.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: profile.name)
                                Text("\(profile.windows.count) windows · \(profile.bundleIDs.count) apps")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Hide other apps", isOn: Binding(
                                get: { profile.hidesOthers == true },
                                set: { workspaces.setHidesOthers($0, for: profile) }))
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                            Picker("Shortcut", selection: Binding(
                                get: { profile.hotKey },
                                set: { workspaces.setHotKey($0, for: profile) })) {
                                Text("Off").tag(Int?.none)
                                ForEach(1...9, id: \.self) { Text(verbatim: "⌃⌥⌘\($0)").tag(Int?.some($0)) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button("Restore") { workspaces.restore(profile) }
                                .disabled(workspaces.restoringID != nil)
                            Button {
                                workspaces.delete(profile)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                        }
                    }
                }
            } header: {
                Text("Saved workspaces")
            } footer: {
                Text("Press ⌃⌥⌘ and a workspace's number to restore it from anywhere; ⌃⌥Z undoes the last layout change.")
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        workspaces.saveCurrentLayout(named: newName)
        newName = ""
    }

    /// Running apps without a rule yet, by name.
    private var ruleCandidates: [(bundleID: String, name: String)] {
        let ruled = Set(settings.windowRules.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let id = app.bundleIdentifier, !ruled.contains(id), seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, value in
                    value.apply()
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("Restart Docklane to apply the language.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Docklane", action: Relauncher.relaunch)
                    }
                }
            }
            Section("Permissions") {
                permission("Accessibility", granted: accessibility, action: Permissions.requestAccessibility)
                permission("Screen & System Audio Recording", granted: screenRecording, action: Permissions.requestScreenRecording)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
        }
    }

    private func permission(_ title: LocalizedStringKey, granted: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open Settings", action: action)
            }
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text(verbatim: "Docklane").font(.title.bold())
            Text("Your workspace, always in view.").foregroundStyle(.secondary)
            Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Uses private macOS interfaces to show and switch to windows on other desktops; they may change with macOS updates.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Window capture and focus techniques follow the approach of AltTab.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: "MIT License · © 2026 Mert Durukan")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
