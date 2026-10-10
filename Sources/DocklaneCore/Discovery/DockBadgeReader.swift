import AppKit
import ApplicationServices

/// Reads the red notification badges ("3", "•") from the macOS Dock's accessibility tree,
/// keyed by bundle identifier. Works while the Dock is auto-hidden.
@MainActor
public enum DockBadgeReader {
    public static func badges() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return [:]
        }
        // Dock items carry the app's display name; map names back to running apps.
        let bundleByName = Dictionary(
            AppDirectory.shared.regularApps.values.filter { !$0.name.isEmpty && !$0.bundleID.isEmpty }
                .map { ($0.name, $0.bundleID) },
            uniquingKeysWith: { first, _ in first }
        )

        var badges: [String: String] = [:]
        let root = AccessibilityInspector.application(dock.processIdentifier)
        for list in AccessibilityInspector.children(root) {
            for item in AccessibilityInspector.children(list) {
                guard AccessibilityInspector.string(item, kAXSubroleAttribute) == "AXApplicationDockItem",
                      let name = AccessibilityInspector.string(item, kAXTitleAttribute),
                      let badge = AccessibilityInspector.string(item, "AXStatusLabel"),
                      !badge.isEmpty,
                      let bundleID = bundleByName[name]
                else { continue }
                badges[bundleID] = badge
            }
        }
        return badges
    }
}
