import AppKit
import DocklaneCore
import ImageIO
import Observation
import SwiftUI

@MainActor
@Observable
final class DesktopModel {
    var spaces: [SpaceInfo] = []
    var selection = 0
    var columns = 1
}

/// ⌥Tab for desktops: every desktop and full-screen space as a miniature, in Mission Control
/// order. Hold ⌥ and press Tab to move, release to go there; 1–9 jump straight to one; Esc
/// cancels. The first press selects the desktop used last, so a quick ⌥Tab toggles between
/// two desktops the way ⌘Tab does between two apps. (⌃⌥Tab when the window switcher has ⌥Tab.)
@MainActor
final class DesktopSwitcher {
    static let shared = DesktopSwitcher()

    let model = DesktopModel()
    private let keyTap = SwitcherKeyTap()
    private var panel: SwitcherPanel?
    private var isActive = false
    private var previousApp: NSRunningApplication?
    /// Catches a missed modifier release, as in the window switcher.
    private var releaseWatch: Timer?

    private init() {}

    var isOpen: Bool { isActive }

    func start() {
        keyTap.isSwitching = { [weak self] in self?.isActive ?? false }
        keyTap.isSearching = { false }
        keyTap.onKey = { [weak self] key in self?.handle(key) ?? false }
        startTap()
        observeSettings()
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.cancel()
            }
        }
    }

    func stopKeyTap() {
        if isActive { cancel() }
        keyTap.stop()
    }

    func startKeyTap() { startTap() }

    private func startTap() {
        let settings = AppSettings.shared
        keyTap.start(trigger: settings.desktopSwitcherEnabled ? settings.switcherShortcut.desktopTrigger : nil)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = AppSettings.shared.desktopSwitcherEnabled
            _ = AppSettings.shared.switcherShortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.startTap()
                self?.observeSettings()
            }
        }
    }

    // MARK: - Keys

    private func handle(_ key: SwitcherCommand) -> Bool {
        switch key {
        case .next: return isActive ? move(1) : show(reverse: false)
        case .previous: return isActive ? move(-1) : show(reverse: true)
        case .left: return move(-1)
        case .right: return move(1)
        case .up: return move(-model.columns)
        case .down: return move(model.columns)
        case .confirm, .modifierReleased:
            commit()
            return true
        case .cancel:
            cancel()
            return true
        case .goToSpace(let number):
            guard isActive else { return false }
            if model.spaces.indices.contains(number - 1) {
                model.selection = number - 1
                commit()
            }
            return true
        case .beginSearch, .character, .backspace, .quitApp, .minimizeApp, .closeWindow, .minimizeWindow:
            return isActive
        }
    }

    private func move(_ delta: Int) -> Bool {
        guard isActive, !model.spaces.isEmpty else { return isActive }
        let count = model.spaces.count
        model.selection = ((model.selection + delta) % count + count) % count
        return true
    }

    // MARK: - Showing

    /// Returns false with a single space, so the key combination reaches the frontmost app.
    private func show(reverse: Bool) -> Bool {
        let engine = WindowEngine.shared
        engine.refreshIfPending()
        let spaces = engine.spaces
        guard spaces.count > 1 else { return false }
        model.spaces = spaces
        model.selection = DesktopStart.selection(spaces: spaces, recent: engine.recentSpaces, reverse: reverse)
        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = self.panel ?? makePanel()
        self.panel = panel
        layoutPanel()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        isActive = true
        startReleaseWatch()
        DispatchQueue.main.async { engine.refreshStaleThumbnails() }
        return true
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel()
        panel.contentView = NSHostingView(rootView: DesktopSwitcherView(model: model) { [weak self] index in
            self?.model.selection = index
            self?.commit()
        }
        .environment(\.layoutDirection, .leftToRight))
        return panel
    }

    private func layoutPanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let area = screen.visibleFrame
        let layout = DesktopLayout(count: model.spaces.count, maxWidth: area.width * 0.9)
        model.columns = layout.columns
        var size = layout.panelSize
        size.height += SwitcherLayout.footerHeight(for: DesktopLayout.hint,
                                                   width: size.width - 2 * SwitcherLayout.padding)
        size.height = min(size.height, area.height * 0.9)
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    private func startReleaseWatch() {
        releaseWatch?.invalidate()
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if SwitcherKeys.modifierReleased(triggerHeld: self.keyTap.isTriggerHeld,
                                                 isOpen: self.isActive, isSearching: false) {
                    self.commit()
                }
            }
        }
    }

    private func hide() {
        releaseWatch?.invalidate()
        releaseWatch = nil
        isActive = false
        panel?.orderOut(nil)
    }

    private func commit() {
        guard isActive else { return }
        let target = model.spaces.indices.contains(model.selection) ? model.spaces[model.selection] : nil
        hide()
        let previousApp = previousApp
        DispatchQueue.main.async {
            if let target, SpaceSwitcher.go(to: target), !target.isShown { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                previousApp?.activate()
            }
        }
    }

    private func cancel() {
        hide()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            previousApp?.activate()
        }
    }
}

/// Grid geometry for the desktop switcher.
struct DesktopLayout {
    /// The miniature screen; 16:10 like most Mac displays.
    static let miniature = CGSize(width: 224, height: 140)
    static let labelHeight: CGFloat = 30
    static let cardPadding: CGFloat = 10
    static var cardSize: CGSize {
        CGSize(width: miniature.width + 2 * cardPadding, height: miniature.height + labelHeight + 2 * cardPadding)
    }

    static let hint = HintText.wrappingBetweenItems(
        String(localized: "Tab next  ·  1–9 jump  ·  Return switch  ·  Esc cancel"))

    let columns: Int
    let rows: Int

    init(count: Int, maxWidth: CGFloat) {
        let card = Self.cardSize.width
        let fit = Int((maxWidth - 2 * SwitcherLayout.padding + SwitcherLayout.spacing) / (card + SwitcherLayout.spacing))
        columns = max(1, min(count, fit))
        rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
    }

    var panelSize: CGSize {
        let card = Self.cardSize
        return CGSize(
            width: CGFloat(columns) * card.width + CGFloat(columns - 1) * SwitcherLayout.spacing + 2 * SwitcherLayout.padding,
            height: CGFloat(rows) * card.height + CGFloat(rows - 1) * SwitcherLayout.spacing + 2 * SwitcherLayout.padding
        )
    }
}

struct DesktopSwitcherView: View {
    let model: DesktopModel
    let onChoose: (Int) -> Void

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(DesktopLayout.cardSize.width), spacing: SwitcherLayout.spacing),
                            count: model.columns)
        let engine = WindowEngine.shared
        let byRecency = engine.windowsByRecency()

        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: SwitcherLayout.spacing) {
                ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                    DesktopCard(
                        number: index + 1,
                        space: space,
                        // Back to front: the most recently used window is drawn last, on top.
                        windows: byRecency.filter { $0.spaceIDs.contains(space.id) && !$0.isMinimized }.reversed(),
                        isSelected: index == model.selection
                    )
                    .onHover { if $0 { model.selection = index } }
                    .onTapGesture { onChoose(index) }
                }
            }
            .padding(SwitcherLayout.padding)

            SwitcherHint(text: DesktopLayout.hint)
        }
        .switcherBackground()
    }
}

/// One space drawn as a miniature screen: the wallpaper with its windows where they really
/// are (a desktop), or the app filling it (full screen). Number key and name underneath.
private struct DesktopCard: View {
    let number: Int
    let space: SpaceInfo
    let windows: [DockWindow]
    let isSelected: Bool

    private var title: (text: String, pid: pid_t?) { SpaceSwitcher.title(for: space, windows: windows) }

    var body: some View {
        let size = DesktopLayout.miniature
        VStack(spacing: 8) {
            miniature(size)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                .shadow(color: .black.opacity(isSelected ? 0.55 : 0.4), radius: isSelected ? 14 : 9, y: 4)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(-5)
                            .shadow(color: Color.accentColor.opacity(0.7), radius: 8)
                    }
                }

            HStack(spacing: 6) {
                Text(verbatim: "\(number)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.16)))
                if let pid = title.pid, let icon = AppIcons.icon(for: pid) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(verbatim: title.text)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if space.isShown {
                    Circle().fill(.white.opacity(0.85)).frame(width: 5, height: 5)
                }
            }
            .frame(width: size.width, height: DesktopLayout.labelHeight - 8)
        }
        .padding(DesktopLayout.cardPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(number), \(title.text)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func miniature(_ size: CGSize) -> some View {
        let engine = WindowEngine.shared
        let display = DisplayLookup.bounds(for: space.display)
        ZStack(alignment: .topLeading) {
            if space.isFullScreen {
                Color.black
                if let window = windows.last, let image = engine.thumbnails[window.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                }
            } else {
                if let wallpaper = Wallpaper.image(for: space.display) {
                    Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                } else {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                }
                let scale = size.width / max(display.width, 1)
                ForEach(windows) { window in
                    let frame = window.bounds.offsetBy(dx: -display.minX, dy: -display.minY)
                    MiniWindow(image: engine.thumbnails[window.id], pid: window.pid)
                        .frame(width: max(frame.width * scale, 6), height: max(frame.height * scale, 4))
                        .offset(x: frame.minX * scale, y: frame.minY * scale)
                }
            }
        }
    }
}

private struct MiniWindow: View {
    let image: NSImage?
    let pid: pid_t

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                ZStack {
                    Color.white.opacity(0.25)
                    if let icon = AppIcons.icon(for: pid) {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(4)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// Display bounds (global, top-left origin like window bounds) for a Mission Control display id.
@MainActor
enum DisplayLookup {
    static func bounds(for identifier: String) -> CGRect {
        CGDisplayBounds(displayID(for: identifier) ?? CGMainDisplayID())
    }

    static func displayID(for identifier: String) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) as String? else { continue }
            if text.caseInsensitiveCompare(identifier) == .orderedSame { return id }
        }
        return nil
    }
}

/// The desktop picture of a display, decoded small once (wallpapers can be 5K HEIC files).
@MainActor
enum Wallpaper {
    private static var cache: [URL: NSImage] = [:]

    static func image(for displayIdentifier: String) -> NSImage? {
        let id = DisplayLookup.displayID(for: displayIdentifier)
        let screen = NSScreen.screens.first { $0.displayID == id } ?? NSScreen.main
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached = cache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 480,
              ] as CFDictionary)
        else { return nil }
        let result = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        if cache.count >= 4 { cache.removeAll() }
        cache[url] = result
        return result
    }
}
