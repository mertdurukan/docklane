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
/// modifier and press Tab to move, release to switch. F (⌘F) searches; Esc cancels;
/// Q quits; C sends the whole app to the Dock (every window); W closes; M minimizes only the selected window.
@MainActor
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    let model = SwitcherModel()
    private let keyTap = SwitcherKeyTap()
    private var panel: SwitcherPanel?
    private var isActive = false
    private var previousApp: NSRunningApplication?
    /// While open, checks the modifier itself: a release event can be missed (tap timeout,
    /// secure input), which would otherwise leave the switcher stuck open.
    private var releaseWatch: Timer?

    private init() {}

    var isOpen: Bool { isActive }

    func start() {
        keyTap.isSwitching = { [weak self] in self?.isActive ?? false }
        keyTap.isSearching = { [weak self] in self?.model.isSearching ?? false }
        keyTap.onKey = { [weak self] key in self?.handle(key) ?? false }
        keyTap.start(trigger: AppSettings.shared.switcherShortcut.trigger)
        observeSettings()
        // Clicking another app (e.g. while typing a search) closes the switcher, so the
        // keyboard never stays captured by a switcher nobody is looking at.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.cancel()
            }
        }
    }

    /// Without Accessibility the switcher can't act, so the system's ⌘Tab takes over.
    func stopKeyTap() {
        if isActive { cancel() }
        keyTap.stop()
    }

    func startKeyTap() {
        keyTap.start(trigger: AppSettings.shared.switcherShortcut.trigger)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = AppSettings.shared.switcherShortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.keyTap.start(trigger: AppSettings.shared.switcherShortcut.trigger)
                self.observeSettings()
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
        case .goToSpace:
            return true  // desktops have their own switcher (⌥Tab)
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
            return act({ WindowActions.quitApp(pid: $0.pid) }, removing: .removeApp)
        case .minimizeApp:
            return act({ selected in
                for window in WindowEngine.shared.windows where window.pid == selected.pid && !window.isMinimized {
                    WindowActions.minimize(window)
                }
            }, removing: .removeApp)
        case .closeWindow:
            return act({ WindowActions.close($0) }, removing: .removeWindow)
        case .minimizeWindow:
            return act({ WindowActions.minimize($0) }, removing: .removeWindow)
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

    /// Runs `action` after the event tap returns (it talks to other apps); the list updates now.
    private func act(_ action: @escaping (DockWindow) -> Void, removing scope: AfterAction) -> Bool {
        guard isActive, model.items.indices.contains(model.selection) else { return isActive }
        let selected = model.items[model.selection]
        DispatchQueue.main.async { action(selected) }
        let remove: (DockWindow) -> Bool
        switch scope {
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
        WindowEngine.shared.refreshIfPending()
        let ordered = WindowEngine.shared.switcherOrder()
        guard !ordered.isEmpty else { return false }
        // Read focus live, before Docklane activates: the recent-window list can lag behind.
        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front.map(\.processIdentifier).flatMap { $0 == getpid() ? nil : $0 }
        let current = frontPID == nil ? nil : AccessibilityInspector.focusedWindowNumber()
        let (items, selection) = SwitcherStart.arrange(ordered, current: current, frontPID: frontPID, reverse: reverse)
        model.allItems = items
        model.items = items
        model.isSearching = false
        model.query = ""
        model.selection = selection
        previousApp = front

        let panel = self.panel ?? makePanel()
        self.panel = panel
        layoutPanel()
        // Being the active app lets the commit switch Spaces (see WindowFocuser).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        isActive = true
        startReleaseWatch()
        switcherLog.debug("shown items=\(items.count, privacy: .public) docklaneActive=\(NSApp.isActive, privacy: .public)")
        // After the panel is up and the event tap has returned: the badge read walks the Dock's
        // accessibility tree, and captures compete with the panel's first frame.
        DispatchQueue.main.async {
            WindowEngine.shared.refreshStaleThumbnails(among: items)
            WindowEngine.shared.refreshIndicators()
        }
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

    private func startReleaseWatch() {
        releaseWatch?.invalidate()
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if SwitcherKeys.modifierReleased(triggerHeld: self.keyTap.isTriggerHeld,
                                                 isOpen: self.isActive, isSearching: self.model.isSearching) {
                    switcherLog.debug("modifier release caught by watch")
                    self.commit()
                }
            }
        }
    }

    private func hide() {
        releaseWatch?.invalidate()
        releaseWatch = nil
        isActive = false
        model.isSearching = false
        panel?.orderOut(nil)
    }

    private func commit() {
        guard isActive else { return }
        let target = model.items.indices.contains(model.selection) ? model.items[model.selection] : nil
        hide()
        // Focusing talks to other apps; do it after the event tap has returned.
        let previousApp = previousApp
        DispatchQueue.main.async {
            if let target, WindowFocuser.focus(target) { return }
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

/// Grid geometry for the switcher.
struct SwitcherLayout {
    /// The window image fills this card (cropped at the edges, never letterboxed).
    static let thumbnailSize = CGSize(width: 216, height: 135)
    static let cardWidth: CGFloat = thumbnailSize.width
    /// The card plus the app icon hanging below its corner.
    static let cardHeight: CGFloat = thumbnailSize.height + 10
    /// Room between cards for the selection ring and the overhanging icon.
    static let spacing: CGFloat = 24
    static let padding: CGFloat = 26
    static let cornerRadius: CGFloat = 28
    static let searchHeight: CGFloat = 56
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
            : String(localized: "Tab next  ·  F search  ·  Q quit  ·  C send app to Dock  ·  W close  ·  M minimize window  ·  Esc cancel"))
    }

    /// Height of the hint wrapped to `width`, at most `footerMaxLines` lines.
    static func footerHeight(for hint: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: footerFontSize, weight: .semibold)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let text = NSAttributedString(string: hint, attributes: [.font: font])
        let height = text.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let lines = min(max(Int((height / lineHeight).rounded(.up)), 1), footerMaxLines)
        return CGFloat(lines) * lineHeight + 2 * footerPadding + 6
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
        // The window server's shadow follows the rounded glass shape.
        hasShadow = true
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
                .padding(.horizontal, 12)
                .frame(height: SwitcherLayout.searchHeight - 12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, SwitcherLayout.padding)
                .padding(.top, 12)
            }

            if model.items.isEmpty {
                Text("No matching windows")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
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
                                .id(window.id)
                                .onHover { if $0 { model.selection = index } }
                                .onTapGesture { onChoose(index) }
                            }
                        }
                        .padding(SwitcherLayout.padding)
                    }
                    .onChange(of: model.selection) { _, selection in
                        // Keep the selection visible when there are more rows than fit.
                        if model.items.indices.contains(selection) { proxy.scrollTo(model.items[selection].id) }
                    }
                }
            }

            SwitcherHint(text: SwitcherLayout.hint(searching: model.isSearching))
        }
        .switcherBackground()
    }
}

/// Keyboard hint: the keys bright, what they do dimmed; wraps only between items.
struct SwitcherHint: View {
    let text: String

    var body: some View {
        Text(Self.styled(text))
            .font(.system(size: SwitcherLayout.footerFontSize))
            .multilineTextAlignment(.center)
            .lineLimit(SwitcherLayout.footerMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SwitcherLayout.padding)
            .padding(.top, 2)
            .padding(.bottom, SwitcherLayout.footerPadding + 4)
            .frame(maxWidth: .infinity)
    }

    /// "Tab next · F search" → **Tab** next   **F** search (items are separated by "·").
    static func styled(_ hint: String) -> AttributedString {
        var result = AttributedString()
        let items = hint.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, item) in items.enumerated() where !item.isEmpty {
            let parts = item.split(separator: "\u{00A0}", maxSplits: 1).map(String.init)
            var key = AttributedString(parts[0])
            key.font = .system(size: SwitcherLayout.footerFontSize, weight: .semibold)
            key.foregroundColor = .white.opacity(0.9)
            result += key
            if parts.count > 1 {
                var label = AttributedString("\u{00A0}" + parts[1])
                label.foregroundColor = .white.opacity(0.5)
                result += label
            }
            if index < items.count - 1 { result += AttributedString("   ") }
        }
        return result
    }
}

extension View {
    /// The switchers' container: Liquid Glass on macOS 26, a dark frosted panel before.
    @ViewBuilder
    func switcherBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: SwitcherLayout.cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            self
                .glassEffect(.regular, in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            self
                .background(VisualEffectView(material: .hudWindow))
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
        }
    }
}

/// One window, drawn like a panel tile: the live thumbnail filling a rounded card, the app
/// icon on its corner and the title in a pill on the image. The selection is a glowing ring.
private struct SwitcherCard: View {
    let window: DockWindow
    let image: NSImage?
    let label: String?
    let isSelected: Bool
    let isPlayingAudio: Bool

    private var icon: NSImage? { AppIcons.icon(for: window.pid) }
    private var isPrivate: Bool { AppSettings.shared.isPrivate(window.bundleID) }
    private let size = SwitcherLayout.thumbnailSize
    private let corner: CGFloat = 12
    private let iconSize: CGFloat = 34

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            if let image {
                // Fill the card, keeping the top of the window (title bar, tabs) in view.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .blurred(12, if: isPrivate)
                if isPrivate {
                    Image(systemName: "lock.fill").font(.system(size: 24)).foregroundStyle(.white.opacity(0.85))
                }
            } else {
                VisualEffectView(material: .hudWindow)
                if let icon { Image(nsImage: icon).resizable().frame(width: 56, height: 56) }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                if let chip = SpaceChip.label(for: window.space) {
                    SpaceChip(text: chip.text, systemImage: chip.symbol)
                }
                if isPlayingAudio { AudioChip() }
            }
            .padding(6)
        }
        .overlay(alignment: .bottom) {
            TitlePill(text: label ?? window.displayTitle, highlighted: label != nil, fontSize: 12)
                .padding(.leading, iconSize * 0.55)
                .padding([.horizontal, .bottom], 8)
        }
        .shadow(color: .black.opacity(isSelected ? 0.55 : 0.4), radius: isSelected ? 14 : 9, y: 4)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: corner + 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-5)
                    .shadow(color: Color.accentColor.opacity(0.7), radius: 8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .offset(x: -iconSize * 0.25, y: iconSize * 0.25)
            }
        }
        .dimmed(window.isMinimized)
        .frame(width: SwitcherLayout.cardWidth, height: SwitcherLayout.cardHeight, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(window.appName), \(label ?? window.displayTitle)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
