import Foundation

/// The text behind About → Copy Diagnostic Info: facts that help with a bug report and nothing
/// personal (no window titles, no app list, the home folder shown as "~"), in plain ASCII
/// punctuation so it pastes anywhere. Pure, unit tested.
public struct DiagnosticReport: Sendable {
    public var lines: [(String, String)] = []

    public init() {}

    public mutating func add(_ label: String, _ value: String) {
        lines.append((label, value))
    }

    public var text: String {
        lines.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    /// `path` with the user's home folder replaced by "~".
    public static func redacted(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// "12 s ago", "never".
    public static func age(of date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        return "\(Int(now.timeIntervalSince(date).rounded())) s ago"
    }
}
