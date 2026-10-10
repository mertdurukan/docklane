/// Matching preferred-language codes ("pt-BR", "zh-Hans-CN") against the app's localizations.
public enum LanguageCode {
    /// The first of `available` that `preferred` is, or is a regional variant of.
    /// "zh-Hans-CN" matches "zh-Hans" but "zh-Hant" does not, and "pt-BR" matches "pt".
    public static func match(_ preferred: String, in available: [String]) -> String? {
        available.first { preferred == $0 || preferred.hasPrefix($0 + "-") }
    }
}
