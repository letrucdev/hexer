/// A release version such as `0.2.0` or `0.3.0-beta.1`, ordered by Semantic Versioning precedence.
/// Missing parts count as zero ("0.1" is 0.1.0); build metadata after `+` is ignored.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Major, minor and patch.
    public let core: [Int]
    /// The dot-separated identifiers after `-` ("beta", "1"); empty for a final release.
    public let prerelease: [String]
    /// The version as written, without a leading "v".
    public let description: String

    /// Parses "1.2.3", "v1.2", "0.3.0-beta.1"; nil for anything else.
    public init?(_ string: String) {
        var text = Substring(string)
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let withoutBuild = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count) else { return nil }
        var core: [Int] = []
        for n in numbers {
            guard !n.isEmpty, n.allSatisfy(\.isASCII), n.allSatisfy(\.isNumber), let value = Int(n) else { return nil }
            core.append(value)
        }
        while core.count < 3 { core.append(0) }
        var prerelease: [String] = []
        if parts.count == 2 {
            prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let allowed = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber || c == "-") }
            guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy(allowed) }) else { return nil }
        }
        self.core = core
        self.prerelease = prerelease
        description = String(text)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.core == b.core && a.prerelease == b.prerelease }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(core)
        hasher.combine(prerelease)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        // A pre-release comes before its final release.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        default: break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (m?, n?): return m < n
            case (.some, nil): return true    // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}
