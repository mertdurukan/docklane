import CoreAudio
import Foundation

/// Which apps are playing sound right now, through Core Audio's process objects (public API,
/// macOS 14.2+). Browsers play from helper processes (e.g. "com.google.Chrome.helper"), so a
/// helper counts for the app whose bundle identifier prefixes it.
public enum AudioActivity {
    /// Bundle identifiers of processes currently sending audio to an output device.
    public static func playingBundleIDs() -> Set<String> {
        guard #available(macOS 14.2, *) else { return [] }
        var result = Set<String>()
        for process in processObjects() where isRunningOutput(process) {
            if let bundleID = bundleID(of: process), !bundleID.isEmpty { result.insert(bundleID) }
        }
        return result
    }

    /// True if `appBundleID` or one of its helpers is in `playing`. Pure, unit tested.
    public static func isPlaying(_ appBundleID: String, in playing: Set<String>) -> Bool {
        guard !appBundleID.isEmpty else { return false }
        return playing.contains { $0 == appBundleID || $0.hasPrefix(appBundleID + ".") }
    }

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects
    }

    @available(macOS 14.2, *)
    private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    @available(macOS 14.2, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Type-to-search matching for the window switcher. Pure, unit tested.
public enum WindowSearch {
    /// Every word of `query` must appear in the title, app name or custom label, ignoring case
    /// and diacritics ("calisma" finds "ÇALIŞMA").
    public static func matches(_ window: DockWindow, label: String?, query: String) -> Bool {
        let words = normalize(query).split(separator: " ")
        guard !words.isEmpty else { return true }
        let haystack = normalize([window.title, window.appName, label ?? ""].joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
    }
}
