import Foundation

/// Interface languages. English is the default; Italian can be selected in the app.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case italian = "it"

    var id: String { rawValue }

    /// Shown in the language picker, always in the language's own name.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .italian: "Italiano"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

/// Holds the language currently used by `tr`. The keys of the translation tables are the
/// English texts, so English needs no table and a missing translation falls back to English.
final class Localizer: @unchecked Sendable {
    static let shared = Localizer()

    private let lock = NSLock()
    private var current = AppLanguage.english

    var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    func translate(_ key: String) -> String {
        switch language {
        case .english: return key
        case .italian: return ItalianStrings.table[key] ?? key
        }
    }
}

/// Translates a fixed interface text (the English text is the key).
func tr(_ key: String) -> String {
    Localizer.shared.translate(key)
}

/// Translates a text with `String(format:)` placeholders (%@, %d, %.1f); numbers follow the
/// decimal separator of the selected language.
func trf(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.shared.translate(key), locale: Localizer.shared.language.locale, arguments: args)
}

/// Picks the singular or plural key for `count`. `args` are the other placeholders; for the
/// plural key the count itself is passed first (`%d`).
func trn(_ count: Int, one: String, other: String, _ args: CVarArg...) -> String {
    let key = count == 1 ? one : other
    let all: [CVarArg] = count == 1 ? args : [Int32(count)] + args
    return String(format: Localizer.shared.translate(key), locale: Localizer.shared.language.locale, arguments: all)
}
