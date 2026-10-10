import AppKit
import DocklaneCore
import Observation
import SwiftUI

@MainActor
@Observable
final class PeekModel {
    var window: DockWindow?
    var image: NSImage?
}

/// Large live preview that appears next to the panel after hovering a tile for a moment, like
/// the Windows taskbar peek. Refreshes every second while open; click-through.
@MainActor
final class PeekController {
    static let shared = PeekController()

    private let model = PeekModel()
    private let capturer = WindowCapturer(maxPixelSize: CGSize(width: 1600, height: 1000))
    private var panel: NSPanel?
    private var pending: Task<Void, Never>?
    private var refresher: Task<Void, Never>?
    private var hovered: WindowNumber?

    private init() {}

    func hoverBegan(_ window: DockWindow) {
        guard AppSettings.shared.peekEnabled else { return }
        hovered = window.id
        pending?.cancel()
        // Already peeking: move to the new tile at once; otherwise wait for the delay.
        let delay = panel?.isVisible == true ? 0 : AppSettings.shared.peekDelay
        pending = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, self?.hovered == window.id else { return }
            await self?.show(window)
        }
    }

    func hoverEnded(_ window: DockWindow) {
        guard hovered == window.id else { return }
        hovered = nil
        pending?.cancel()
        // Small grace period so moving between tiles doesn't flicker.
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, self?.hovered == nil else { return }
            self?.hide()
        }
    }

    func hide() {
        pending?.cancel()
        refresher?.cancel()
        hovered = nil
        panel?.orderOut(nil)
        model.window = nil
        model.image = nil
    }

    private func show(_ window: DockWindow) async {
        model.window = window
        model.image = WindowEngine.shared.thumbnails[window.id]
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel, imageSize: model.image?.size)
        panel.orderFrontRegardless()

        refresher?.cancel()
        refresher = Task { [weak self, capturer] in
            while !Task.isCancelled {
                if let image = await capturer.capture(window) {
                    guard !Task.isCancelled, let self, self.model.window?.id == window.id else { return }
                    self.model.image = NSImage(cgImage: image.cgImage, size: image.size)
                    self.position(panel, imageSize: image.size)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.contentView = NSHostingView(rootView: PeekView(model: model).environment(\.layoutDirection, .leftToRight))
        return panel
    }

    /// Next to the panel on the pointer's display, centred on the pointer along the edge.
    private func position(_ panel: NSPanel, imageSize: CGSize?) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let edge = AppSettings.shared.edge
        let dock = PanelController.shared.panelFrame(on: screen) ?? area

        let maxSize = CGSize(width: area.width * 0.45, height: area.height * 0.6)
        let image = WindowCapturer.fittedSize(for: imageSize ?? CGSize(width: 16, height: 10), within: maxSize)
        let header: CGFloat = 40
        let size = CGSize(width: max(image.width, 320) + 24, height: image.height + header + 24)
        let gap: CGFloat = 10

        var origin: CGPoint
        switch edge {
        case .left: origin = CGPoint(x: dock.maxX + gap, y: mouse.y - size.height / 2)
        case .right: origin = CGPoint(x: dock.minX - gap - size.width, y: mouse.y - size.height / 2)
        case .bottom: origin = CGPoint(x: mouse.x - size.width / 2, y: dock.maxY + gap)
        case .top: origin = CGPoint(x: mouse.x - size.width / 2, y: dock.minY - gap - size.height)
        }
        origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
        origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private struct PeekView: View {
    let model: PeekModel

    var body: some View {
        if let window = model.window {
            let isPrivate = AppSettings.shared.isPrivate(window.bundleID)
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    Text(verbatim: WindowEngine.shared.label(for: window) ?? window.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let chip = SpaceChip.label(for: window.space) {
                        Label(chip.text, systemImage: chip.symbol).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 20)

                ZStack {
                    if let image = model.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .blur(radius: isPrivate ? 24 : 0)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if isPrivate {
                        Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .background(VisualEffectView(material: .hudWindow))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
        }
    }
}
