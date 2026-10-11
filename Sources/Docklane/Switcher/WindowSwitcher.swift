import AppKit
import DocklaneCore
import Observation
import os
import SwiftUI

private let switcherLog = Logger(subsystem: "io.github.mertdurukan.docklane", category: "switcher")

@MainActor
@Observable
final class SwitcherModel {
    /// Everything the switcher can show, before search.
    var allItems: [DockWindow] = []
    /// What is on screen (search applied).
    var items: [DockWindow] = []
    var selection = 0
    var columns = 1
    var isSearching = false
    var query = ""
}

/// ⌘Tab for windows: every window on every desktop, most recently used first. Hold the
/// modifier and press Tab to move, release to switch. "/" searches; Esc cancels;
/// Q/H/W/M quit, hide, close or minimize the selected item.
@MainActor
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    let model = SwitcherModel()
    private let keyTap = SwitcherKeyTap()
    private var panel: SwitcherPanel?
    private var isActive = false
    private var previousApp: NSRunningApplication?

    private init() {}

    var isOpen: Bool { isActive }

    func start() {
        keyTap.isSwitching = { [weak self] in self?.isActive ?? false }
        keyTap.isSearching = { [weak self] in self?.model.isSearching ?? false }
        keyTap.onKey = { [weak self] key in self?.handle(key) ?? false }
        keyTap.start(AppSettings.shared.switcherShortcut)
        observeSettings()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = AppSettings.shared.switcherShortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.keyTap.start(AppSettings.shared.switcherShortcut)
                self.observeSettings()
            }
        }
    }

    // MARK: - Keys

    private func handle(_ key: SwitcherKeyTap.Key) -> Bool {
        switch key {
        case .next: return isActive ? move(1) : show(reverse: false)
        case .previous: return isActive ? move(-1) : show(reverse: true)
        case .left: return move(-1)
        case .right: return move(1)
        case .up: return move(-model.columns)
        case .down: return move(model.columns)
        case .confirm:
            commit()
            return true
        case .modifierReleased:
            // While searching the switcher stays open so you can type without the modifier.
            if !model.isSearching { commit() }
            return true
        case .cancel:
            if model.isSearching && !model.query.isEmpty {
                model.query = ""
                applySearch()
            } else {
                cancel()
            }
            return true
        case .beginSearch:
            model.isSearching = true
            model.query = ""
            layoutPanel()
            return true
        case .character(let text):
            model.query += text
            applySearch()
            return true
        case .backspace:
            if !model.query.isEmpty {
                model.query.removeLast()
                applySearch()
            }
            return true
        case .quitApp:
            return act { WindowActions.quitApp(pid: $0.pid); return .removeApp }
        case .hideApp:
            return act { WindowActions.hideApp(pid: $0.pid); return .removeApp }
        case .closeWindow:
            return act { WindowActions.close($0); return .removeWindow }
        case .minimizeWindow:
            return act { WindowActions.minimize($0); return .removeWindow }
        }
    }

    private func move(_ delta: Int) -> Bool {
        guard isActive, !model.items.isEmpty else { return isActive }
        let count = model.items.count
        model.selection = ((model.selection + delta) % count + count) % count
        return true
    }

    private func applySearch() {
        let engine = WindowEngine.shared
        model.items = model.allItems.filter {
            WindowSearch.matches($0, label: engine.label(for: $0), query: model.query)
        }
        model.selection = 0
    }

    private enum AfterAction { case removeApp, removeWindow }

    private func act(_ action: (DockWindow) -> AfterAction) -> Bool {
        guard isActive, model.items.indices.contains(model.selection) else { return isActive }
        let selected = model.items[model.selection]
        let remove: (DockWindow) -> Bool
        switch action(selected) {
        case .removeApp: remove = { $0.pid == selected.pid }
        case .removeWindow: remove = { $0.id == selected.id }
        }
        model.allItems.removeAll(where: remove)
        model.items.removeAll(where: remove)
        if model.allItems.isEmpty {
            hide()
        } else {
            model.selection = min(model.selection, max(model.items.count - 1, 0))
            layoutPanel()
        }
        return true
    }

    // MARK: - Showing

    /// Returns false when there is nothing to switch to, so the system shortcut still works.
    private func show(reverse: Bool) -> Bool {
        let items = WindowEngine.shared.switcherOrder()
        guard !items.isEmpty else { return false }
        model.allItems = items
        model.items = items
        model.isSearching = false
        model.query = ""
        model.selection = items.count == 1 ? 0 : (reverse ? items.count - 1 : 1)
        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = self.panel ?? makePanel()
        self.panel = panel
        layoutPanel()
        // Being the active app lets the commit switch Spaces (see WindowFocuser).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        isActive = true
        switcherLog.debug("shown items=\(items.count, privacy: .public) docklaneActive=\(NSApp.isActive, privacy: .public)")
        WindowEngine.shared.refreshThumbnails(Array(items.prefix(12)))
        return true
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel()
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model) { [weak self] index in
            self?.model.selection = index
            self?.commit()
        }
        // Arrow keys move through items in screen order, so the row stays left-to-right.
        .environment(\.layoutDirection, .leftToRight))
        return panel
    }

    /// Sized for all items (not the search results), so the panel doesn't jump while typing.
    private func layoutPanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let layout = SwitcherLayout(count: model.allItems.count, maxWidth: area.width * 0.9)
        model.columns = layout.columns
        var size = layout.panelSize
        let footer = SwitcherLayout.footerHeight(for: SwitcherLayout.hint(searching: model.isSearching),
                                                 width: size.width - 2 * SwitcherLayout.padding)
        size.height += footer + (model.isSearching ? SwitcherLayout.searchHeight : 0)
        size.height = min(size.height, area.height * 0.9)
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    private func hide() {
        isActive = false
        model.isSearching = false
        panel?.orderOut(nil)
    }

    private func commit() {
        guard isActive else { return }
        let target = model.items.indices.contains(model.selection) ? model.items[model.selection] : nil
        hide()
        if let target, WindowFocuser.focus(target) {
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            previousApp?.activate()
        }
    }

    private func cancel() {
        hide()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            previousApp?.activate()
        }
    }
}

/// Grid geometry for the switcher.
struct SwitcherLayout {
    static let cardWidth: CGFloat = 220
    static let cardHeight: CGFloat = 178
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 18
    static let searchHeight: CGFloat = 44
    static let footerFontSize: CGFloat = 11
    static let footerPadding: CGFloat = 8
    static let footerMaxLines = 3

    let columns: Int
    let rows: Int

    init(count: Int, maxWidth: CGFloat) {
        let fit = Int((maxWidth - 2 * Self.padding + Self.spacing) / (Self.cardWidth + Self.spacing))
        // As wide as the cards (no empty columns), up to what fits on screen.
        columns = max(1, min(count, fit))
        rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
    }

    /// The keyboard hint under the cards, localized; wraps only between its items.
    static func hint(searching: Bool) -> String {
        HintText.wrappingBetweenItems(searching
            ? String(localized: "Return switch  ·  Esc clear / close  ·  ← → move")
            : String(localized: "Tab next  ·  / search  ·  Q quit  ·  H hide  ·  W close  ·  M minimize  ·  Esc cancel"))
    }

    /// Height of the hint wrapped to `width`, at most `footerMaxLines` lines.
    static func footerHeight(for hint: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: footerFontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let text = NSAttributedString(string: hint, attributes: [.font: font])
        let height = text.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let lines = min(max(Int((height / lineHeight).rounded(.up)), 1), footerMaxLines)
        return CGFloat(lines) * lineHeight + 2 * footerPadding
    }

    var panelSize: CGSize {
        CGSize(
            width: CGFloat(columns) * Self.cardWidth + CGFloat(columns - 1) * Self.spacing + 2 * Self.padding,
            height: CGFloat(rows) * Self.cardHeight + CGFloat(rows - 1) * Self.spacing + 2 * Self.padding
        )
    }
}

/// Centered HUD panel; can become key so Docklane is active while switching.
final class SwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct SwitcherView: View {
    let model: SwitcherModel
    let onChoose: (Int) -> Void

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(SwitcherLayout.cardWidth), spacing: SwitcherLayout.spacing),
                            count: model.columns)
        let engine = WindowEngine.shared
        let carriers = DockOrdering.badgeCarriers(model.items)

        VStack(spacing: 0) {
            if model.isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    if model.query.isEmpty {
                        Text("Type to search windows").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: model.query)
                    }
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 18)
                    Spacer()
                    Text(verbatim: "\(model.items.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.system(size: 15))
                .padding(.horizontal, SwitcherLayout.padding + 4)
                .frame(height: SwitcherLayout.searchHeight)
                Divider().opacity(0.4)
            }

            if model.items.isEmpty {
                Text("No matching windows")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: SwitcherLayout.spacing) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, window in
                            SwitcherCard(
                                window: window,
                                image: engine.thumbnails[window.id],
                                label: engine.label(for: window),
                                isSelected: index == model.selection,
                                isPlayingAudio: carriers.contains(window.id) && engine.isPlayingAudio(window)
                            )
                            .onHover { if $0 { model.selection = index } }
                            .onTapGesture { onChoose(index) }
                        }
                    }
                    .padding(SwitcherLayout.padding)
                }
            }

            Text(verbatim: SwitcherLayout.hint(searching: model.isSearching))
                .font(.system(size: SwitcherLayout.footerFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(SwitcherLayout.footerMaxLines)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SwitcherLayout.padding)
                .padding(.vertical, SwitcherLayout.footerPadding)
                .frame(maxWidth: .infinity)
        }
        .background(VisualEffectView(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

private struct SwitcherCard: View {
    let window: DockWindow
    let image: NSImage?
    let label: String?
    let isSelected: Bool
    let isPlayingAudio: Bool

    private var icon: NSImage? { NSRunningApplication(processIdentifier: window.pid)?.icon }
    private var isPrivate: Bool { AppSettings.shared.isPrivate(window.bundleID) }
    private let thumbnailSize = CGSize(width: 200, height: 126)

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .blur(radius: isPrivate ? 12 : 0)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    if isPrivate {
                        Image(systemName: "lock.fill").font(.system(size: 24)).foregroundStyle(.white.opacity(0.85))
                    }
                } else if let icon {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                }
            }
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if let chip = SpaceChip.label(for: window.space) {
                        SpaceChip(text: chip.text, systemImage: chip.symbol)
                    }
                    if isPlayingAudio { AudioChip() }
                }
                .padding(6)
            }
            .saturation(window.isMinimized ? 0 : 1)
            .opacity(window.isMinimized ? 0.55 : 1)

            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(verbatim: label ?? window.displayTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: thumbnailSize.width)
        }
        .padding(10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(window.appName), \(label ?? window.displayTitle)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
