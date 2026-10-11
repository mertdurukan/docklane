import AppKit
import DocklaneCore
import Observation

/// User preferences, persisted in UserDefaults. Observable so views and panels update live.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// The Dock's "Size": 0 = small, 1 = large.
    var size: Double { didSet { store(size, "size") } }
    var edge: PanelEdge { didSet { store(edge.rawValue, "edge") } }
    var autoHide: Bool { didSet { store(autoHide, "autoHide") } }
    /// Seconds the panel stays after the pointer leaves it.
    var autoHideDelay: Double { didSet { store(autoHideDelay, "autoHideDelay") } }
    var showBackground: Bool { didSet { store(showBackground, "showBackground") } }
    var alwaysShowTitles: Bool { didSet { store(alwaysShowTitles, "alwaysShowTitles") } }
    var labelOtherDesktops: Bool { didSet { store(labelOtherDesktops, "labelOtherDesktops") } }
    var minimizeOnFrontClick: Bool { didSet { store(minimizeOnFrontClick, "minimizeOnFrontClick") } }
    /// Move windows out of the panel's area (only while auto-hide is off).
    var keepWindowsClear: Bool { didSet { store(keepWindowsClear, "keepWindowsClear") } }
    var pinnedApps: [String] { didSet { store(pinnedApps, "pinnedApps") } }
    var pinnedOnAllDisplays: Bool { didSet { store(pinnedOnAllDisplays, "pinnedOnAllDisplays") } }
    var hotKey: HotKeyChoice { didSet { store(hotKey.rawValue, "hotKey") } }
    /// Shortcut for the window switcher (replaces the app switcher when it is ⌘Tab).
    var switcherShortcut: SwitcherShortcut { didSet { store(switcherShortcut.rawValue, "switcherShortcut") } }
    var desktopSwitcherEnabled: Bool { didSet { store(desktopSwitcherEnabled, "desktopSwitcherEnabled") } }
    var rememberDisplayLayouts: Bool { didSet { store(rememberDisplayLayouts, "rememberDisplayLayouts") } }

    /// Apps whose previews are blurred everywhere (password managers, banking, chat…).
    var privateApps: [String] { didSet { store(privateApps, "privateApps") } }
    /// Large live preview next to the panel after hovering a tile.
    var peekEnabled: Bool { didSet { store(peekEnabled, "peekEnabled") } }
    var peekDelay: Double { didSet { store(peekDelay, "peekDelay") } }
    var showAudioIndicator: Bool { didSet { store(showAudioIndicator, "showAudioIndicator") } }
    var panelCurrentDesktopOnly: Bool { didSet { store(panelCurrentDesktopOnly, "panelCurrentDesktopOnly") } }
    var switcherCurrentDesktopOnly: Bool { didSet { store(switcherCurrentDesktopOnly, "switcherCurrentDesktopOnly") } }
    /// Shortcut that opens the panel for arrow-key navigation.
    var navigationHotKey: HotKeyChoice { didSet { store(navigationHotKey.rawValue, "navigationHotKey") } }

    var metrics: PanelMetrics { PanelMetrics(size: size) }

    func isPrivate(_ bundleID: String) -> Bool { privateApps.contains(bundleID) }

    func togglePrivate(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        if let index = privateApps.firstIndex(of: bundleID) {
            privateApps.remove(at: index)
        } else {
            privateApps.append(bundleID)
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "size": 0.25,
            "edge": PanelEdge.left.rawValue,
            "autoHide": false,
            "autoHideDelay": 0.4,
            "showBackground": false,
            "alwaysShowTitles": false,
            "labelOtherDesktops": true,
            "minimizeOnFrontClick": false,
            "keepWindowsClear": true,
            "pinnedOnAllDisplays": false,
            "hotKey": HotKeyChoice.controlOptionD.rawValue,
            "switcherShortcut": SwitcherShortcut.commandTab.rawValue,
            "desktopSwitcherEnabled": true,
            "rememberDisplayLayouts": true,
            "peekEnabled": true,
            "peekDelay": 0.6,
            "showAudioIndicator": true,
            "panelCurrentDesktopOnly": false,
            "switcherCurrentDesktopOnly": false,
            "navigationHotKey": HotKeyChoice.controlOptionK.rawValue,
        ])
        size = defaults.double(forKey: "size")
        edge = PanelEdge(rawValue: defaults.string(forKey: "edge") ?? "") ?? .left
        autoHide = defaults.bool(forKey: "autoHide")
        autoHideDelay = defaults.double(forKey: "autoHideDelay")
        showBackground = defaults.bool(forKey: "showBackground")
        alwaysShowTitles = defaults.bool(forKey: "alwaysShowTitles")
        labelOtherDesktops = defaults.bool(forKey: "labelOtherDesktops")
        minimizeOnFrontClick = defaults.bool(forKey: "minimizeOnFrontClick")
        keepWindowsClear = defaults.bool(forKey: "keepWindowsClear")
        pinnedApps = defaults.stringArray(forKey: "pinnedApps") ?? []
        pinnedOnAllDisplays = defaults.bool(forKey: "pinnedOnAllDisplays")
        hotKey = HotKeyChoice(rawValue: defaults.string(forKey: "hotKey") ?? "") ?? .controlOptionD
        switcherShortcut = SwitcherShortcut(rawValue: defaults.string(forKey: "switcherShortcut") ?? "") ?? .commandTab
        desktopSwitcherEnabled = defaults.bool(forKey: "desktopSwitcherEnabled")
        rememberDisplayLayouts = defaults.bool(forKey: "rememberDisplayLayouts")
        privateApps = defaults.stringArray(forKey: "privateApps") ?? []
        peekEnabled = defaults.bool(forKey: "peekEnabled")
        peekDelay = defaults.double(forKey: "peekDelay")
        showAudioIndicator = defaults.bool(forKey: "showAudioIndicator")
        panelCurrentDesktopOnly = defaults.bool(forKey: "panelCurrentDesktopOnly")
        switcherCurrentDesktopOnly = defaults.bool(forKey: "switcherCurrentDesktopOnly")
        navigationHotKey = HotKeyChoice(rawValue: defaults.string(forKey: "navigationHotKey") ?? "") ?? .controlOptionK
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func isPinned(_ bundleID: String) -> Bool { pinnedApps.contains(bundleID) }

    func togglePinned(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        if let index = pinnedApps.firstIndex(of: bundleID) {
            pinnedApps.remove(at: index)
        } else {
            pinnedApps.append(bundleID)
        }
    }

    /// The macOS Dock's edge, to warn when both would pop up together.
    var dockSharesEdge: Bool {
        (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom") == edge.rawValue
    }
}

/// Global shortcut presets (show / hide panel, keyboard navigation).
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case none
    case controlOptionD
    case controlOptionK
    case controlOptionSpace
    case optionCommandP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "None")
        case .controlOptionD: return "⌃⌥D"
        case .controlOptionK: return "⌃⌥K"
        case .controlOptionSpace: return "⌃⌥Space"
        case .optionCommandP: return "⌥⌘P"
        }
    }
}

/// Which modifier + Tab opens the window switcher.
enum SwitcherShortcut: String, CaseIterable, Identifiable {
    case commandTab, optionTab, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandTab: return "⌘Tab"
        case .optionTab: return "⌥Tab"
        case .off: return String(localized: "Off")
        }
    }

    /// Modifier held with Tab.
    var trigger: CGEventFlags? {
        switch self {
        case .commandTab: .maskCommand
        case .optionTab: .maskAlternate
        case .off: nil
        }
    }

    /// The desktop switcher's modifier: ⌥, or ⌃⌥ when the window switcher already uses ⌥Tab.
    var desktopTrigger: CGEventFlags {
        self == .optionTab ? [.maskControl, .maskAlternate] : .maskAlternate
    }

    var desktopTitle: String { self == .optionTab ? "⌃⌥Tab" : "⌥Tab" }
}

/// Per-app interface language, stored as this app's AppleLanguages and applied on relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en", turkish = "tr", chinese = "zh-Hans", hindi = "hi", spanish = "es"
    case arabic = "ar", french = "fr", bengali = "bn", portuguese = "pt", russian = "ru"
    case indonesian = "id"
    var id: String { rawValue }

    /// Each language in its own name, so people can find theirs whatever the current language.
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .turkish: return "Türkçe"
        case .chinese: return "简体中文"
        case .hindi: return "हिन्दी"
        case .spanish: return "Español"
        case .arabic: return "العربية"
        case .french: return "Français"
        case .bengali: return "বাংলা"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .indonesian: return "Bahasa Indonesia"
        }
    }

    static var current: AppLanguage {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String],
              let first = languages.first
        else { return .system }
        return matching(first) ?? .system
    }

    /// The language for a preferred-language code such as "pt-BR" or "zh-Hans-CN".
    static func matching(_ code: String) -> AppLanguage? {
        let languages = allCases.filter { $0 != .system }
        return LanguageCode.match(code, in: languages.map(\.rawValue)).flatMap(AppLanguage.init(rawValue:))
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Quits and reopens the app (after granting Screen Recording or changing the language).
/// Opens the new instance first: a helper process started by the app would be killed together
/// with it, so it could not reopen anything.
@MainActor
enum Relauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
