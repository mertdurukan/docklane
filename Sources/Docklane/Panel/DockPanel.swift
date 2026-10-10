import AppKit
import SwiftUI

/// Borderless, transparent panel on a screen edge, present on every desktop and over
/// full-screen apps.
final class DockPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            // Not .nonactivatingPanel: a click must be able to activate Docklane for a moment,
            // because macOS only lets the active app hand focus to another app's window.
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        // Report as a floating panel, not a document window, so window switchers
        // (Cmd+Tab replacements, AltTab, …) leave Docklane out.
        setAccessibilitySubrole(.floatingWindow)
        setAccessibilityLabel("Docklane")
    }

    /// Clicking a window that can't become key does not activate its app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel never stays key, so nearly every click on it is a "first mouse" click, which
/// AppKit swallows unless the view accepts it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
