import AppKit
import DocklaneCore
import SwiftUI
import UniformTypeIdentifiers

/// Content of one panel: pinned launchers, window tiles grouped by app, minimized windows.
struct DockView: View {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let isMainScreen: Bool
    let isOnlyScreen: Bool

    private var engine: WindowEngine { .shared }
    private var settings: AppSettings { .shared }
    @State private var dragging: WindowNumber?

    var body: some View {
        let metrics = settings.metrics
        let edge = settings.edge
        let windowsHere = engine.panelWindows(screenFrame: screenFrame, isMainScreen: isMainScreen, isOnlyScreen: isOnlyScreen)
        let arrangement = DockOrdering.arrange(windowsHere, pinned: settings.pinnedApps,
                                               manualOrder: engine.memory.manualOrder)
        let launchers = pinnedLaunchers
        let usable = usableFrame
        let isEmpty = arrangement.open.isEmpty && arrangement.minimized.isEmpty && launchers.isEmpty

        Group {
            if isEmpty {
                Color.clear
                    .onAppear { reportLength(0) }
            } else {
                ViewThatFits(in: edge.isVertical ? .vertical : .horizontal) {
                    measured(tiles(arrangement, launchers, metrics: metrics, edge: edge, usable: usable), edge: edge)
                    ScrollView(edge.isVertical ? .vertical : .horizontal, showsIndicators: false) {
                        measured(tiles(arrangement, launchers, metrics: metrics, edge: edge, usable: usable), edge: edge)
                    }
                }
                .background {
                    if settings.showBackground {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.clear)
                            .background(VisualEffectView(material: .hudWindow))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                    }
                }
            }
        }
        .padding(edge.insets(PanelMetrics.edgeInset,
                             edgeSide: metrics.edgeSideInset(for: edge)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    /// Reports the tiles' natural length along the edge, so the panel window can shrink to it
    /// and leave the rest of the edge clickable (inside the scroll view it is the full length).
    private func measured(_ content: some View, edge: PanelEdge) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            edge.isVertical ? proxy.size.height : proxy.size.width
        } action: { length in
            reportLength(length)
        }
    }

    private func reportLength(_ length: CGFloat) {
        PanelController.shared.contentLengthChanged(length, on: displayID)
    }

    @ViewBuilder
    private func tiles(_ arrangement: DockOrdering.Arrangement, _ launchers: [PinnedApp],
                       metrics: PanelMetrics, edge: PanelEdge, usable: CGRect) -> some View {
        let stack = edge.isVertical
            ? AnyLayout(VStackLayout(spacing: metrics.spacing))
            : AnyLayout(HStackLayout(spacing: metrics.spacing))
        let carriers = DockOrdering.badgeCarriers(arrangement.open + arrangement.minimized)
        let order = arrangement.open.map(\.id)

        stack {
            ForEach(launchers) { app in
                PinnedTile(app: app, badge: engine.badges[app.bundleID], metrics: metrics)
            }
            if !launchers.isEmpty && !(arrangement.open.isEmpty && arrangement.minimized.isEmpty) {
                GroupSeparator(edge: edge, metrics: metrics, strong: true)
            }

            ForEach(Array(arrangement.open.enumerated()), id: \.element.id) { index, window in
                if index > 0 && arrangement.open[index - 1].bundleID != window.bundleID {
                    GroupSeparator(edge: edge, metrics: metrics, strong: false)
                }
                tile(window, badge: carriers.contains(window.id), metrics: metrics, edge: edge, order: order, usable: usable)
            }

            if !arrangement.minimized.isEmpty {
                if !arrangement.open.isEmpty { GroupSeparator(edge: edge, metrics: metrics, strong: true) }
                ForEach(arrangement.minimized) { window in
                    tile(window, badge: carriers.contains(window.id), metrics: metrics, edge: edge, order: order, usable: usable)
                }
            }
        }
    }

    private func tile(_ window: DockWindow, badge: Bool, metrics: PanelMetrics, edge: PanelEdge,
                      order: [WindowNumber], usable: CGRect) -> some View {
        WindowTile(
            window: window,
            image: engine.thumbnails[window.id],
            customLabel: engine.label(for: window),
            isFocused: engine.focusedWindow == window.id,
            isKeyboardSelected: PanelController.shared.navigationSelection == window.id,
            badge: badge ? engine.badges[window.bundleID] : nil,
            isPlayingAudio: badge && engine.isPlayingAudio(window),
            metrics: metrics,
            edge: edge,
            usableFrame: usable
        )
        .opacity(dragging == window.id ? 0.4 : 1)
        .onDrag {
            dragging = window.id
            return NSItemProvider(object: String(window.id) as NSString)
        }
        .onDrop(of: [.fileURL, .plainText], delegate: TileDropDelegate(
            target: window, order: order, dragging: $dragging
        ))
    }

    // MARK: - Data

    /// Pinned apps without any window get a launcher tile (main display only, unless set).
    private var pinnedLaunchers: [PinnedApp] {
        guard isMainScreen || settings.pinnedOnAllDisplays else { return [] }
        let withWindows = Set(engine.windows.map(\.bundleID))
        return settings.pinnedApps.filter { !withWindows.contains($0) }.compactMap(PinnedApp.init)
    }

    private var usableFrame: CGRect {
        let screen = NSScreen.screens.first { $0.frame == screenFrame } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? screenFrame
        return PanelLayout.frames(edge: settings.edge, thickness: settings.metrics.thickness(for: settings.edge, background: settings.showBackground),
                                  visibleFrame: visible, autoHide: settings.autoHide).usable
    }
}

/// Gap between app groups; a faint line before the pinned / minimized sections (and between
/// groups when the background is on, like the Dock).
private struct GroupSeparator: View {
    let edge: PanelEdge
    let metrics: PanelMetrics
    let strong: Bool

    var body: some View {
        if strong || AppSettings.shared.showBackground {
            Capsule()
                .fill(.white.opacity(strong ? 0.3 : 0.12))
                .shadow(color: .black.opacity(0.4), radius: 1)
                .frame(width: edge.isVertical ? metrics.tileWidth * 0.7 : 1,
                       height: edge.isVertical ? 1 : metrics.tileHeight * 0.7)
                .padding(edge.isVertical ? .vertical : .horizontal, 2)
        } else {
            Color.clear.frame(width: edge.isVertical ? 1 : 4, height: edge.isVertical ? 4 : 1)
        }
    }
}

/// Reorders tiles by drag, or opens dropped Finder files with the window's app.
private struct TileDropDelegate: DropDelegate {
    let target: DockWindow
    let order: [WindowNumber]
    @Binding var dragging: WindowNumber?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target.id else { return }
        WindowEngine.shared.move(dragging, before: target.id, currentOrder: order)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragging == nil ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil }
        guard dragging == nil, info.hasItemsConforming(to: [.fileURL]),
              let appURL = NSRunningApplication(processIdentifier: target.pid)?.bundleURL else { return dragging != nil }
        FileDrop.load(info.itemProviders(for: [.fileURL])) { urls in
            WindowActions.open(urls, withApplicationAt: appURL)
        }
        return true
    }
}

/// Collects file URLs from drag providers.
enum FileDrop {
    @MainActor
    static func load(_ providers: [NSItemProvider], then handle: @escaping @MainActor ([URL]) -> Void) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadURL(provider) { urls.append(url) }
            }
            handle(urls)
        }
    }

    // Main-actor isolated like the caller, so the (non-Sendable) provider never crosses actors.
    @MainActor
    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

extension PanelEdge {
    /// `value` on every side except the one facing the screen edge, which gets `edgeSide`.
    func insets(_ value: CGFloat, edgeSide: CGFloat) -> EdgeInsets {
        EdgeInsets(top: self == .top ? edgeSide : value,
                   leading: self == .left ? edgeSide : value,
                   bottom: self == .bottom ? edgeSide : value,
                   trailing: self == .right ? edgeSide : value)
    }
}
