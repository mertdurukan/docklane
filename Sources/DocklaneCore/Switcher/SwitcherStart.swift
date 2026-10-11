import Foundation

/// What the window switcher shows and selects when it opens.
public enum SwitcherStart {
    /// Puts the window that has focus right now first, and selects the most recent window of
    /// another app, so one ⌘Tab press goes straight to the next app (the macOS habit).
    /// - Parameters:
    ///   - items: windows, most recently used first.
    ///   - current: the focused window, read live when the switcher opens.
    ///   - frontPID: the frontmost app (not Docklane).
    ///   - reverse: opened with Shift (selects the last item).
    public static func arrange(
        _ items: [DockWindow],
        current: WindowNumber?,
        frontPID: pid_t?,
        reverse: Bool
    ) -> (items: [DockWindow], selection: Int) {
        var items = items
        if let current, let index = items.firstIndex(where: { $0.id == current }), index > 0 {
            items.insert(items.remove(at: index), at: 0)
        }
        guard items.count > 1 else { return (items, 0) }
        if reverse { return (items, items.count - 1) }

        // The first item is "where you are" only if it belongs to the frontmost app;
        // otherwise (desktop focused, app without windows) the first item is already the target.
        let firstIsHere = items[0].id == current || (frontPID != nil && items[0].pid == frontPID)
        guard firstIsHere else { return (items, 0) }
        let here = items[0].pid
        let otherApp = items.indices.dropFirst().first { items[$0].pid != here && !items[$0].isMinimized }
        return (items, otherApp ?? 1)
    }
}
