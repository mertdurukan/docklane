import Foundation

/// "1.2.3" / "v1.2.3" as comparable numbers. Pure, unit tested.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespaces))
        if trimmed.first == "v" || trimmed.first == "V" { trimmed = trimmed.dropFirst() }
        // Pre-release or build suffixes ("1.2.0-beta") compare by their numeric core.
        let core = trimmed.prefix { $0.isNumber || $0 == "." }
        let pieces = core.split(separator: ".", omittingEmptySubsequences: false)
        let parts = pieces.compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == pieces.count else { return nil }
        self.parts = parts
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let l = index < lhs.parts.count ? lhs.parts[index] : 0
            let r = index < rhs.parts.count ? rhs.parts[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// Asks GitHub for the latest published release, only when the user clicks Check for Updates.
public enum UpdateCheck {
    public enum Result: Equatable, Sendable {
        case upToDate(SemanticVersion)
        case available(SemanticVersion, page: URL)
        case failed
    }

    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/mertdurukan/docklane/releases/latest")!

    /// Pure part: GitHub's JSON for the latest release against the running version.
    public static func result(current: String, latestReleaseJSON data: Data) -> Result {
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let latest = SemanticVersion(release.tag_name),
              let running = SemanticVersion(current) else { return .failed }
        return running < latest ? .available(latest, page: release.html_url) : .upToDate(running)
    }

    /// One request, no cookies or caches kept, 15 s timeout.
    public static func run(current: String) async -> Result {
        var request = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
        return result(current: current, latestReleaseJSON: data)
    }
}
