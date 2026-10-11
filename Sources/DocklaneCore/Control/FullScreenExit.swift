/// When a window leaving full screen can be minimized. Pure, unit tested.
public enum FullScreenExit {
    /// The window is back on a desktop: the window server lists it again and it is on a space,
    /// none of them the full-screen one it left. Mid-animation it is on no space (or unlisted).
    public static func hasLanded(spaces: [UInt64], fullScreenSpaces: [UInt64], isListed: Bool) -> Bool {
        isListed && !spaces.isEmpty && Set(spaces).isDisjoint(with: fullScreenSpaces)
    }
}
