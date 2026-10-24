import Foundation

/// The list of changes in a release's notes. Scripts/release_notes.sh opens them with the
/// version's section of CHANGELOG.md: "## What's new" and "## Có gì mới", each a list of items.
public enum ReleaseNotes {
    public static let englishHeading = "What's new"
    public static let vietnameseHeading = "Có gì mới"

    /// The items (Markdown, one per "- " line with its continuation lines) under the Vietnamese
    /// heading when asked for and present, else under the English one.
    public static func items(in notes: String, vietnamese: Bool) -> [String] {
        if vietnamese {
            let items = items(in: notes, heading: vietnameseHeading)
            if !items.isEmpty { return items }
        }
        return items(in: notes, heading: englishHeading)
    }

    static func items(in notes: String, heading: String) -> [String] {
        var items: [String] = []
        var inSection = false
        // Swift counts "\r\n" as one newline character, so either line ending works.
        for raw in notes.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "’", with: "'")
                inSection = title.compare(heading, options: .caseInsensitive) == .orderedSame
                if !inSection && !items.isEmpty { break }
                continue
            }
            guard inSection, !line.isEmpty else { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                items.append(String(line.dropFirst(2)))
            } else if let last = items.indices.last {
                items[last] += " " + line
            }
        }
        return items
    }
}
