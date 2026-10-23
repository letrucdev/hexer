/// Which byte values the text column shows as characters (View ▸ Filter Characters); the
/// others show as a dot, like control characters.
public struct CharacterFilter: Equatable, Codable, Sendable {
    /// Allowed byte values, sorted and non-overlapping.
    public private(set) var ranges: [ClosedRange<UInt8>]

    public init(_ ranges: [ClosedRange<UInt8>]) {
        self.ranges = Self.normalized(ranges)
    }

    /// Every character the encoding can display.
    public static let all = CharacterFilter([0...255])
    /// Printable ASCII: 20–7E.
    public static let ascii = CharacterFilter([0x20...0x7E])
    /// ASCII letters and digits.
    public static let alphanumeric = CharacterFilter([0x30...0x39, 0x41...0x5A, 0x61...0x7A])

    public var isAll: Bool { ranges == [0...255] }

    public func allows(_ byte: UInt8) -> Bool {
        ranges.contains { $0.contains(byte) }
    }

    /// Parses hex ranges like "20-7E, A0-FF" or "41 42 61-7A".
    public init?(parsing text: String) {
        var ranges: [ClosedRange<UInt8>] = []
        let items = text.split { $0 == "," || $0 == " " || $0 == ";" }
        for item in items {
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  let lo = UInt8(bounds[0].trimmingPrefix("0x"), radix: 16),
                  let hi = UInt8(bounds[bounds.count - 1].trimmingPrefix("0x"), radix: 16), lo <= hi else { return nil }
            ranges.append(lo...hi)
        }
        guard !ranges.isEmpty else { return nil }
        self.init(ranges)
    }

    /// The ranges in the form `init(parsing:)` reads, e.g. "20-7E, A0-FF".
    public var text: String {
        ranges.map { r in
            r.lowerBound == r.upperBound ? Self.hex(r.lowerBound) : "\(Self.hex(r.lowerBound))-\(Self.hex(r.upperBound))"
        }.joined(separator: ", ")
    }

    private static func hex(_ b: UInt8) -> String {
        let s = String(b, radix: 16, uppercase: true)
        return s.count == 1 ? "0" + s : s
    }

    private static func normalized(_ ranges: [ClosedRange<UInt8>]) -> [ClosedRange<UInt8>] {
        var out: [ClosedRange<UInt8>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, Int(r.lowerBound) <= Int(last.upperBound) + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
