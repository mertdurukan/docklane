import AppKit
import DocklaneCore
import ServiceManagement

/// Collects the diagnostic text for a bug report (see `DiagnosticReport`).
@MainActor
enum Diagnostics {
    static func report() -> String {
        var report = DiagnosticReport()
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        report.add("Docklane", "\(version) (\(build))")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        report.add("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(osBuild))")
        report.add("Mac", "\(hardwareModel), \(architecture)")
        report.add("Language", Bundle.main.preferredLocalizations.first ?? "?")

        let permissions = PermissionMonitor.shared.state
        report.add("Accessibility", permissions.accessibility ? "granted" : "off")
        report.add("Screen Recording", permissions.screenRecording ? "granted" : "off")
        let missing = PrivateSymbols.missing
        report.add("Missing private symbols", missing.isEmpty ? "none" : missing.joined(separator: ", "))

        let screens = NSScreen.screens.map { screen in
            "\(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(Int(screen.backingScaleFactor))x"
        }
        report.add("Displays", "\(screens.count) (\(screens.joined(separator: ", ")))")
        let engine = WindowEngine.shared
        let windows = engine.windows
        report.add("Windows", "\(windows.count) (\(windows.filter(\.isMinimized).count) minimized, "
                   + "\(windows.filter { $0.space != .current }.count) on other desktops)")
        report.add("Spaces", "\(engine.spaces.count) (\(engine.spaces.filter(\.isFullScreen).count) full screen)")
        report.add("Captures", "\(engine.capturesSucceeded) ok, \(engine.capturesFailed) failed, "
                   + "last failure \(DiagnosticReport.age(of: engine.lastCaptureFailure))")

        let settings = AppSettings.shared
        report.add("Settings", "edge \(settings.edge.rawValue), auto-hide \(settings.autoHide ? "on" : "off"), "
                   + "switcher \(settings.switcherShortcut.rawValue), desktop switcher \(settings.desktopSwitcherEnabled ? "on" : "off"), "
                   + "preview \(settings.peekEnabled ? "on" : "off"), keyboard placement \(settings.keyboardPlacement ? "on" : "off")")
        report.add("Login item", loginItemStatus)
        report.add("App", DiagnosticReport.redacted(bundle.bundlePath)
                   + (bundle.bundlePath.contains("/AppTranslocation/") ? " (translocated: move it to Applications)" : ""))
        return report.text
    }

    static func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
    }

    private static var loginItemStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .notRegistered: "off"
        case .requiresApproval: "needs approval in System Settings"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }

    private static var osBuild: String { sysctlString("kern.osversion") ?? "?" }
    private static var hardwareModel: String { sysctlString("hw.model") ?? "?" }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
