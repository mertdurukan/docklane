import AppKit
import DocklaneCore
import SwiftUI

// MARK: - Window tile

/// One window: a floating live thumbnail at the window's aspect ratio with the app icon on
/// its corner, title on hover, focus ring, badge and desktop label.
struct WindowTile: View {
    let window: DockWindow
    let image: NSImage?
    let customLabel: String?
    let isFocused: Bool
    var isKeyboardSelected = false
    let badge: String?
    var isPlayingAudio = false
    let metrics: PanelMetrics
    let edge: PanelEdge
    /// Screen area outside the panel, for "Fill Screen".
    let usableFrame: CGRect

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var settings: AppSettings { .shared }

    private let corner: CGFloat = 10
    private var appIcon: NSImage? { NSRunningApplication(processIdentifier: window.pid)?.icon }
    private var title: String { customLabel ?? window.displayTitle }
    private var isPrivate: Bool { settings.isPrivate(window.bundleID) }

    var body: some View {
        let size = metrics.tileSize(imageSize: image?.size, edge: edge)
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        content(size)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(isHovered ? 0.4 : 0.16), lineWidth: 0.5))
            .overlay {
                if isKeyboardSelected {
                    shape.strokeBorder(.white, lineWidth: 3)
                        .shadow(color: .white.opacity(0.8), radius: 8)
                } else if isFocused {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                        .shadow(color: Color.accentColor.opacity(0.8), radius: 6)
                }
            }
            .overlay(alignment: .bottom) {
                if isHovered || settings.alwaysShowTitles {
                    TitlePill(text: title, highlighted: customLabel != nil, fontSize: metrics.fontSize)
                        .padding(.leading, metrics.iconSize * 0.55)
                        .padding([.horizontal, .bottom], 8)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if settings.labelOtherDesktops, let label = SpaceChip.label(for: window.space) {
                        SpaceChip(text: label.text, systemImage: label.symbol)
                    }
                    if isPlayingAudio {
                        AudioChip()
                    }
                }
                .padding(6)
            }
            .shadow(color: .black.opacity(isHovered ? 0.55 : 0.4), radius: isHovered ? 14 : 9, y: 4)
            .overlay(alignment: .bottomLeading) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: metrics.iconSize, height: metrics.iconSize)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .offset(x: -metrics.iconSize * 0.25, y: metrics.iconSize * 0.25)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge { BadgeView(text: badge) }
            }
            .saturation(window.isMinimized ? 0 : 1)
            .opacity(window.isMinimized ? 0.55 : 1)
            .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            // No margin toward the screen edge (the panel's minimal edge gap is the distance),
            // except inside a background, so tiles don't touch its border.
            .padding(edge.insets(PanelMetrics.tileInset, edgeSide: settings.showBackground ? PanelMetrics.tileInset : 0))
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering { PeekController.shared.hoverBegan(window) } else { PeekController.shared.hoverEnded(window) }
            }
            .onTapGesture(perform: activate)
            .contextMenu { menu }
            .help(title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: window.title.isEmpty ? window.appName : "\(window.appName), \(title)"))
            .accessibilityValue(window.isMinimized ? Text("Minimized") : (isFocused ? Text("Active") : Text(verbatim: "")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, activate)
    }

    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .blur(radius: isPrivate ? 14 : 0)
                .overlay {
                    if isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: min(size.height * 0.25, 28)))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 3)
                    }
                }
        } else {
            ZStack {
                VisualEffectView(material: .hudWindow)
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: size.height * 0.45)
                }
            }
        }
    }

    private func activate() {
        PeekController.shared.hide()
        if settings.minimizeOnFrontClick && isFocused && !window.isMinimized {
            WindowActions.minimize(window)
        } else {
            WindowFocuser.focus(window)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("New Window") { WindowActions.newWindow(pid: window.pid) }
        if !window.bundleID.isEmpty {
            Button(settings.isPinned(window.bundleID) ? "Remove from Dock" : "Keep in Dock") {
                settings.togglePinned(window.bundleID)
            }
        }
        Divider()
        Button("Rename…") { RenameDialog.run(for: window, current: customLabel) }
        Menu("Move & Resize") {
            ForEach(PlacementPreset.allCases, id: \.self) { placement in
                Button(placement.title) {
                    WorkspaceManager.shared.recordUndoPoint()
                    WindowActions.fill(window, frame: placement.frame(in: usableFrame, current: WindowActions.cocoaFrame(of: window)),
                                       restoreIfMinimized: true)
                }
            }
        }
        Button(LivePins.shared.isPinned(window) ? "Unpin Live Preview" : "Pin Live Preview") {
            LivePins.shared.toggle(window)
        }
        if !window.bundleID.isEmpty {
            Button(isPrivate ? "Show Preview" : "Hide Preview") { settings.togglePrivate(window.bundleID) }
        }
        Button(window.isMinimized ? "Restore" : "Minimize") {
            if window.isMinimized { WindowFocuser.focus(window) } else { WindowActions.minimize(window) }
        }
        Divider()
        Button("Hide") { WindowActions.hideApp(pid: window.pid) }
        Button("Close Window") { WindowActions.close(window) }
        Button("Quit") { WindowActions.quitApp(pid: window.pid) }
    }
}

// MARK: - Pinned app

struct PinnedApp: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage
    let url: URL?
    let isRunning: Bool
    var id: String { bundleID }

    init?(bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard running != nil || url != nil else { return nil }
        self.bundleID = bundleID
        self.url = url
        isRunning = running != nil
        let fileName = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        name = running?.localizedName ?? (fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName)
        icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    }
}

/// A pinned app without windows: its icon (with a dot while running); click to open.
struct PinnedTile: View {
    let app: PinnedApp
    let badge: String?
    let metrics: PanelMetrics

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var side: CGFloat { min(max(metrics.tileWidth * 0.3, 40), 72).rounded() }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                .overlay(alignment: .topTrailing) {
                    if let badge { BadgeView(text: badge) }
                }
            Circle()
                .fill(app.isRunning ? .white.opacity(0.9) : .clear)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .frame(width: 4, height: 4)
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .padding(PanelMetrics.tileInset / 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { WindowActions.launch(bundleID: app.bundleID) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let url = app.url else { return false }
            FileDrop.load(providers) { WindowActions.open($0, withApplicationAt: url) }
            return true
        }
        .contextMenu {
            Button("Remove from Dock") { AppSettings.shared.togglePinned(app.bundleID) }
            if app.isRunning {
                Divider()
                Button("Quit") {
                    NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.terminate()
                }
            }
        }
        .help(app.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: app.name))
        .accessibilityValue(app.isRunning ? Text("Running") : Text(verbatim: ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { WindowActions.launch(bundleID: app.bundleID) }
    }
}

// MARK: - Small parts

extension PlacementPreset {
    var title: String {
        switch self {
        case .leftHalf: return String(localized: "Left Half")
        case .rightHalf: return String(localized: "Right Half")
        case .topHalf: return String(localized: "Top Half")
        case .bottomHalf: return String(localized: "Bottom Half")
        case .center: return String(localized: "Center")
        case .fill: return String(localized: "Fill Screen")
        }
    }
}

/// Speaker chip for an app that is playing sound.
struct AudioChip: View {
    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .accessibilityLabel(Text("Playing audio"))
    }
}

/// Red notification badge copied from the Dock.
struct BadgeView: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(.red))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .offset(x: 6, y: -6)
    }
}

/// Frosted title label over the bottom of a tile.
struct TitlePill: View {
    let text: String
    var highlighted = false
    let fontSize: CGFloat

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(highlighted ? .yellow : .white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

/// "Desktop 2" / "Full Screen" chip for windows that are not on the current desktop.
struct SpaceChip: View {
    let text: String
    let systemImage: String

    static func label(for space: SpacePlacement) -> (text: String, symbol: String)? {
        switch space {
        case .current: return nil
        case .desktop(let number): return (String(localized: "Desktop \(number)"), "rectangle.on.rectangle")
        case .fullScreen: return (String(localized: "Full Screen"), "arrow.up.left.and.arrow.down.right")
        }
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Asks for a custom label for a window.
@MainActor
enum RenameDialog {
    static func run(for window: DockWindow, current: String?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename")
        alert.informativeText = String(localized: "Enter a name for this \(window.appName) window:")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Reset"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current ?? window.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: WindowEngine.shared.setLabel(field.stringValue, for: window)
        case .alertThirdButtonReturn: WindowEngine.shared.setLabel(nil, for: window)
        default: break
        }
    }
}
