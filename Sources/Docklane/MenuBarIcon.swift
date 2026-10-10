import AppKit

/// The menu bar glyph: the app icon's three window cards stepping forward, as a template
/// image so macOS tints it for light, dark and highlighted menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Back to front; each card cuts a thin gap into the ones behind it.
            let cards: [(CGRect, CGFloat)] = [
                (CGRect(x: 1, y: 3, width: 6, height: 8), 0.4),
                (CGRect(x: 4, y: 3, width: 6, height: 9.5), 0.7),
                (CGRect(x: 7, y: 3, width: 10.5, height: 11), 1),
            ]
            for (rect, alpha) in cards {
                ctx.setBlendMode(.clear)
                ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerWidth: 2.6, cornerHeight: 2.6, transform: nil))
                ctx.fillPath()
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.fillPath()
            }
            // Title-bar dots punched out of the front card.
            ctx.setBlendMode(.clear)
            for index in 0..<3 {
                ctx.fillEllipse(in: CGRect(x: 8.4 + CGFloat(index) * 2.1, y: 11.4, width: 1.5, height: 1.5))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Docklane"
        return image
    }()
}
