import Foundation

/// Keyboard hint lines such as "Tab next  ·  F search  ·  Esc cancel".
public enum HintText {
    /// When the line wraps, it breaks only between items: each "key action" pair is held
    /// together with no-break spaces and the "·" stays at the end of its line.
    public static func wrappingBetweenItems(_ text: String) -> String {
        text.components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "\u{00A0}") }
            .filter { !$0.isEmpty }
            .joined(separator: "\u{00A0}·  ")
    }
}
