import Foundation

/// The base used to show offsets and to parse numbers typed into dialogs.
public enum NumberBase: Int, CaseIterable, Codable, Sendable {
    case hexadecimal = 16
    case decimal = 10
    case octal = 8

    public var radix: Int { rawValue }

    /// The suffix HxD shows in column headers, e.g. "Offset (h)".
    public var suffix: String {
        switch self {
        case .hexadecimal: "h"
        case .decimal: "d"
        case .octal: "o"
        }
    }

    public func format(_ value: UInt64, minDigits: Int = 1, uppercase: Bool = true) -> String {
        var s = String(value, radix: radix, uppercase: uppercase)
        if s.count < minDigits { s = String(repeating: "0", count: minDigits - s.count) + s }
        return s
    }

    /// Parses a number in this base; accepts surrounding spaces and, for hex, a "0x" prefix
    /// or "h" suffix.
    public func parse(_ text: String) -> UInt64? {
        var t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        if self == .hexadecimal {
            if t.lowercased().hasPrefix("0x") { t.removeFirst(2) }
            if t.lowercased().hasSuffix("h") { t.removeLast() }
        }
        guard !t.isEmpty else { return nil }
        return UInt64(t, radix: radix)
    }

    /// Number of digits needed to show any offset below `length`.
    public func digits(forLength length: UInt64, minimum: Int = 8) -> Int {
        max(minimum, format(length > 0 ? length - 1 : 0).count)
    }
}
