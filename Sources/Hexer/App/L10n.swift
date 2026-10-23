import Foundation

/// Looks up the localized text for an English source string (the key) in Localizable.strings.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Localized format string, e.g. `L("Search (%lld hits)", count)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}
