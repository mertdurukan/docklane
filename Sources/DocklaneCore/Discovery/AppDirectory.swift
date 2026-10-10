import AppKit

/// Cached facts about running regular apps. Asking `NSRunningApplication` for its activation
/// policy or name is a synchronous LaunchServices round trip per app, which dominated the
/// periodic scan; these facts only change when apps launch or quit.
@MainActor
public final class AppDirectory {
    public struct App: Sendable {
        public let pid: pid_t
        public let bundleID: String
        public let name: String
    }

    public static let shared = AppDirectory()

    private var cache: [pid_t: App]?
    private var cachedAt = Date.distantPast
    /// Safety net for apps that change their activation policy without launching or quitting.
    private let maxAge: TimeInterval = 30

    private init() {}

    /// Regular (Dock-visible) apps by process id.
    public var regularApps: [pid_t: App] {
        if let cache, Date().timeIntervalSince(cachedAt) < maxAge { return cache }
        let fresh = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
                .map { ($0.processIdentifier, App(pid: $0.processIdentifier,
                                                  bundleID: $0.bundleIdentifier ?? "",
                                                  name: $0.localizedName ?? "")) },
            uniquingKeysWith: { first, _ in first }
        )
        cache = fresh
        cachedAt = Date()
        return fresh
    }

    /// Call when apps launch or quit.
    public func invalidate() {
        cache = nil
    }
}
