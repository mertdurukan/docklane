import Foundation
import Security

/// Reads versioned JSON from UserDefaults without ever losing it: data that can't be read
/// (damaged, or written by a newer Docklane) is copied to "<key>.backup.<date>" before the
/// caller starts over, so the next save can't silently overwrite the only copy.
public enum StoredJSON {
    public enum Outcome<Value> {
        case missing
        case loaded(Value)
        /// Unreadable; the raw data was kept under `backupKey`.
        case unreadable(backupKey: String)

        public var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    public static func load<Value: Decodable>(_ type: Value.Type, from defaults: UserDefaults, key: String,
                                              now: Date = Date(),
                                              isAcceptable: (Value) -> Bool = { _ in true }) -> Outcome<Value> {
        guard let data = defaults.data(forKey: key) else { return .missing }
        if let value = try? JSONDecoder().decode(Value.self, from: data), isAcceptable(value) {
            return .loaded(value)
        }
        return .unreadable(backupKey: keepBackup(of: data, in: defaults, key: key, now: now))
    }

    /// Copies `data` aside (once per second at most; an existing backup is never replaced).
    @discardableResult
    public static func keepBackup(of data: Data, in defaults: UserDefaults, key: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let backupKey = "\(key).backup.\(formatter.string(from: now))"
        if defaults.object(forKey: backupKey) == nil { defaults.set(data, forKey: backupKey) }
        return backupKey
    }
}

/// Decodes an element if it can, so one damaged entry doesn't take the whole list with it.
public struct Lenient<Element: Decodable>: Decodable {
    public let value: Element?

    public init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

/// Identifies the current login session. Window numbers are only unique within one: after a
/// restart or a new login the same number can belong to a different window.
public enum LoginSession {
    /// Boot time plus the security session id (a new one for every login).
    public static var current: String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        var session = SecuritySessionId()
        var attributes = SessionAttributeBits()
        let status = SessionGetInfo(callerSecuritySession, &session, &attributes)
        return "\(boot.tv_sec)-\(status == errSecSuccess ? Int(session) : -1)"
    }
}
