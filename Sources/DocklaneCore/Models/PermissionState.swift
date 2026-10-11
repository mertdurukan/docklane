/// The two permissions Docklane runs on, and what to do when they change while it runs.
/// Pure, unit tested.
public struct PermissionState: Equatable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public var allGranted: Bool { accessibility && screenRecording }

    public struct Reaction: Equatable, Sendable {
        /// Remove the ⌘Tab / ⌥Tab event taps: without Accessibility they can't act on windows,
        /// and the system switcher should work instead.
        public var stopKeyTaps = false
        /// Accessibility is back: create the taps again and re-subscribe to every app.
        public var restartAccessibilityWork = false
        /// Screen Recording is back; macOS applies it to a running app only after a restart.
        public var suggestRestart = false
        /// Screen Recording is gone: stop asking for window images.
        public var stopCaptures = false
        /// Screen Recording is back: take the missing images.
        public var resumeCaptures = false

        public init() {}
    }

    public static func reaction(from old: PermissionState, to new: PermissionState) -> Reaction {
        var reaction = Reaction()
        if old.accessibility && !new.accessibility { reaction.stopKeyTaps = true }
        if !old.accessibility && new.accessibility { reaction.restartAccessibilityWork = true }
        if old.screenRecording && !new.screenRecording { reaction.stopCaptures = true }
        if !old.screenRecording && new.screenRecording {
            reaction.resumeCaptures = true
            reaction.suggestRestart = true
        }
        return reaction
    }
}
