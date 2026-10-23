// Lists the user-facing strings of the app and checks that every one has a Vietnamese
// translation. Exits with status 1 when translations are missing.
//
//   swift Scripts/l10n_audit.swift            report missing keys
//   swift Scripts/l10n_audit.swift --keys     print every key found (one per line)
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("Sources/Hexer")
let viFile = root.appendingPathComponent("Resources/Localization/vi.lproj/Localizable.strings")

/// Calls whose first string literal is shown to the user (SwiftUI resolves these through
/// LocalizedStringKey; `L` and the menu helpers through Bundle.main).
let patterns = [
    #"\bL\("((?:[^"\\]|\\.)*)""#,
    #"\b(?:Text|Button|Toggle|Label|Section|Picker|TextField|TableColumn|Menu|LocalizedStringKey|ContentUnavailableView|Link|LabeledContent)\(\s*"((?:[^"\\]|\\.)*)""#,
    #"\.(?:help|navigationTitle|accessibilityLabel)\(\s*"((?:[^"\\]|\\.)*)""#,
    #"\b(?:item|menu|sub|pane|field|fact|group)\(\s*"((?:[^"\\]|\\.)*)""#,
    // The first argument of these is an SF Symbol name; the second is the help text.
    #"\b(?:stepButton|iconButton|button|GlassBarIconButton)\(\s*"[^"]*",\s*"((?:[^"\\]|\\.)*)""#,
    #"\b(?:title|confirmTitle|description|placeholder):\s*"((?:[^"\\]|\\.)*)""#,
    // Both branches of `Text(condition ? "A" : "B")`.
    #"\b(?:Text|Label|Button)\((?!\s*verbatim:)[^"\n]*\?\s*"((?:[^"\\]|\\.)*)"\s*:"#,
    #"\b(?:Text|Label|Button)\((?!\s*verbatim:)[^"\n]*\?\s*"(?:[^"\\]|\\.)*"\s*:\s*"((?:[^"\\]|\\.)*)""#,
    // Titles in switch statements; lowercase words there are identifiers or file extensions.
    #"\bcase \.\w+: "((?:[^"\\]|\\.)*[A-Z ](?:[^"\\]|\\.)*)""#,
]

/// Keys built at run time from HexerCore names (inspector rows and sections, export formats).
let dynamicKeys = [
    "Integers", "Characters", "Floating point", "Date & time", "Other", "Disassembly",
    "Binary (8 bit)", "AnsiChar", "WideChar (UTF-16)", "UTF-8 code point", "Single (float32)", "Double (float64)",
    "OLETIME", "FILETIME", "DOS date", "DOS time", "DOS time & date", "time_t (32 bit)", "time_t (64 bit)",
    "Editor view", "Rich Text Format",
    "Disassembly (x86-16)", "Disassembly (x86-32)", "Disassembly (x86-64)", "Disassembly (ARM64)",
]

/// SwiftUI turns `\(x)` in a LocalizedStringKey into a format specifier; strings use %@,
/// integers %lld. The audit accepts either for each interpolation.
func keyVariants(_ literal: String) -> [String] {
    let parts = literal.components(separatedBy: #"\("#)
    guard parts.count > 1 else { return [literal.replacingOccurrences(of: #"\""#, with: "\"")] }
    var keys = [""]
    for (i, part) in parts.enumerated() {
        if i == 0 { keys = keys.map { $0 + part }; continue }
        // Drop the interpolated expression up to its closing parenthesis.
        var depth = 1
        var rest = Substring(part)
        while let c = rest.first, depth > 0 {
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            rest = rest.dropFirst()
        }
        keys = keys.flatMap { [$0 + "%@" + rest, $0 + "%lld" + rest] }
    }
    return keys
}

var found: [String: [String]] = [:]   // first variant -> all variants
let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
for case let url as URL in enumerator where url.pathExtension == "swift" && !url.path.contains("DebugLaunchArguments") {
    // Comments may quote example strings; only code counts.
    let text = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    for pattern in patterns {
        let regex = try NSRegularExpression(pattern: pattern)
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let literal = String(text[r])
            // Skip symbols, identifiers and format-only strings.
            guard literal.contains(where: \.isLetter), !literal.hasPrefix("com."), !literal.contains("."), literal.count > 1
                    || ["A", "B"].contains(literal) else {
                if literal.contains(" ") || literal.hasSuffix("…") { found[literal] = keyVariants(literal) }
                continue
            }
            if literal.range(of: #"^[a-z]+[A-Z]\w*$"#, options: .regularExpression) != nil { continue } // camelCase ids
            found[literal] = keyVariants(literal)
        }
    }
}

for key in dynamicKeys { found[key] = [key] }

if CommandLine.arguments.contains("--keys") {
    for key in found.keys.sorted() { print(found[key]![0]) }
    exit(0)
}

let translations = (NSDictionary(contentsOf: viFile) as? [String: String]) ?? [:]
let missing = found.filter { _, variants in !variants.contains { translations[$0] != nil } }.keys.sorted()
if missing.isEmpty {
    print("l10n audit: all \(found.count) strings have Vietnamese translations")
} else {
    print("l10n audit: \(missing.count) of \(found.count) strings lack Vietnamese translations:")
    for key in missing { print("  \(found[key]![0])") }
    exit(1)
}
