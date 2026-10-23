import Foundation

/// How case-insensitive text is normalized before comparing.
enum CaseFold: Hashable, Sendable {
    case none
    /// A 256-entry table mapping each byte of an 8-bit encoding to the byte of its lowercase form.
    case bytes([UInt8])
    /// Per UTF-16LE code unit, through `utf16Table`.
    case utf16LE

    /// Simple lowercase mapping of every BMP code unit (surrogates and multi-unit mappings map to themselves).
    static let utf16Table: [UInt16] = {
        var t = (0...0xFFFF).map { UInt16($0) }
        for u in 0...0xFFFF {
            guard let s = Unicode.Scalar(UInt32(u)), s.properties.changesWhenLowercased else { continue }
            let lower = s.properties.lowercaseMapping.unicodeScalars
            if lower.count == 1, let l = lower.first, l.value <= 0xFFFF { t[u] = UInt16(l.value) }
        }
        return t
    }()

    private static let byteTables: [TextEncoding: [UInt8]] = Dictionary(uniqueKeysWithValues: TextEncoding.allCases.map { e in
        let table = e.table
        let fold = (0..<256).map { b -> UInt8 in
            guard let c = table.characters[b] else { return UInt8(b) }
            let lower = String(c).lowercased()
            guard lower.count == 1, let lb = table.byte(for: Character(lower)) else { return UInt8(b) }
            return lb
        }
        return (e, fold)
    })

    static func table(for encoding: TextEncoding) -> [UInt8] { byteTables[encoding]! }

    func apply(_ bytes: [UInt8]) -> [UInt8] {
        switch self {
        case .none:
            return bytes
        case .bytes(let t):
            return bytes.map { t[Int($0)] }
        case .utf16LE:
            var out = bytes
            var i = 0
            while i + 1 < out.count {
                let f = Self.utf16Table[Int(out[i]) | Int(out[i + 1]) << 8]
                out[i] = UInt8(truncatingIfNeeded: f)
                out[i + 1] = UInt8(truncatingIfNeeded: f >> 8)
                i += 2
            }
            return out
        }
    }
}

/// A query turned into byte patterns, ready for `SearchEngine` and `compileReplacement`.
public struct CompiledSearch: Sendable {
    public let query: SearchQuery
    /// The encodings searched for, as they would appear in the file: several for integer "(any)" width
    /// (one per width the value fits, shortest first), one otherwise. Case-insensitive text matches every
    /// case variant of these bytes.
    public let patterns: [[UInt8]]
    public let isCaseSensitive: Bool
    public let minLength: Int
    public let maxLength: Int
    let fold: CaseFold
    /// `patterns` after `fold`; the scanner looks for these in folded data.
    let foldedPatterns: [[UInt8]]

    init(query: SearchQuery, patterns: [[UInt8]], fold: CaseFold) {
        self.query = query
        self.patterns = patterns
        self.fold = fold
        isCaseSensitive = query.dataType != .text || query.text.caseSensitive
        foldedPatterns = patterns.map { fold.apply($0) }
        minLength = patterns.map(\.count).min()!
        maxLength = patterns.map(\.count).max()!
    }

    /// The distinct lengths a match can have.
    public var matchLengths: [Int] { Array(Set(patterns.map(\.count))).sorted() }

    /// The length of the longest pattern matching at the start of `bytes`, or nil if none does.
    /// This is the reference definition of a match; the scanner finds exactly these, only faster.
    public func matchLength(_ bytes: some Collection<UInt8>) -> Int? {
        let candidate = fold.apply(Array(bytes.prefix(maxLength)))
        var best: Int?
        for p in foldedPatterns where p.count <= candidate.count && p.count > (best ?? 0) {
            if candidate.starts(with: p) { best = p.count }
        }
        return best
    }
}

/// Replacement bytes for each length a match of the search can have.
public struct CompiledReplacement: Sendable {
    public let pattern: String
    /// Keyed by match length: integer "(any)" replaces each match with the value at the match's width.
    public let bytesByMatchLength: [Int: [UInt8]]

    public func bytes(forMatchLength length: Int) -> [UInt8] { bytesByMatchLength[length] ?? [] }

    /// Whether replacing changes the file size (HxD then asks before proceeding).
    public var changesLength: Bool { bytesByMatchLength.contains { $0.key != $0.value.count } }

    /// Fixed-size streams (disks) need equal-length replacements; throws `SearchError.sizeMismatch`.
    public func validateFixedSize() throws {
        for (length, bytes) in bytesByMatchLength.sorted(by: { $0.key < $1.key }) where length != bytes.count {
            throw SearchError.sizeMismatch(search: length, replacement: bytes.count)
        }
    }
}

extension SearchEngine {
    /// Turns `query` into byte patterns; throws `SearchError` for input HxD would reject.
    public static func compile(_ query: SearchQuery) throws -> CompiledSearch {
        switch query.dataType {
        case .text:
            guard !query.pattern.isEmpty else { throw SearchError.emptyPattern }
            let options = query.text
            let bytes = try encodeText(query.pattern, options.encoding, caseFallback: !options.caseSensitive)
            guard !options.caseSensitive else { return CompiledSearch(query: query, patterns: [bytes], fold: .none) }
            switch options.encoding {
            case .utf16LittleEndian:
                return CompiledSearch(query: query, patterns: [bytes], fold: .utf16LE)
            case .editor(let encoding):
                let table = CaseFold.table(for: encoding)
                // Bytes without a case partner compare raw, so such patterns keep the memmem fast path.
                var classSize = [Int](repeating: 0, count: 256)
                for b in 0..<256 { classSize[Int(table[b])] += 1 }
                let needsFold = bytes.contains { classSize[Int(table[Int($0)])] > 1 }
                return CompiledSearch(query: query, patterns: [bytes], fold: needsFold ? .bytes(table) : .none)
            }
        case .hex:
            let bytes = try parseHex(query.pattern)
            guard !bytes.isEmpty else { throw SearchError.noHexValues }
            return CompiledSearch(query: query, patterns: [bytes], fold: .none)
        case .integer:
            let value = try parseInteger(query.pattern)
            let options = query.integer
            var patterns: [[UInt8]] = []
            for width in options.width.candidates {
                if let bytes = encodeInteger(value, bits: width.rawValue, options) {
                    patterns.append(bytes)
                } else if options.width != .any {
                    throw SearchError.integerOutOfRange(query.pattern, bits: width.rawValue)
                }
            }
            guard !patterns.isEmpty else { throw SearchError.integerOutOfRange(query.pattern, bits: 64) }
            return CompiledSearch(query: query, patterns: patterns, fold: .none)
        case .float:
            return CompiledSearch(query: query, patterns: [try encodeFloat(query.pattern, query.float)], fold: .none)
        }
    }

    /// Encodes the "Replace with:" text with the search's datatype and options. Text and hex may be empty
    /// (replace with nothing); integers are encoded at the width of each match length the search can produce.
    public static func compileReplacement(_ pattern: String, for search: CompiledSearch) throws -> CompiledReplacement {
        let query = search.query
        var map: [Int: [UInt8]] = [:]
        switch query.dataType {
        case .text:
            let bytes = try encodeText(pattern, query.text.encoding, caseFallback: false)
            for length in search.matchLengths { map[length] = bytes }
        case .hex:
            let bytes = try parseHex(pattern)
            for length in search.matchLengths { map[length] = bytes }
        case .integer:
            let value = try parseInteger(pattern)
            for length in search.matchLengths {
                guard let bytes = encodeInteger(value, bits: length * 8, query.integer) else {
                    throw SearchError.integerOutOfRange(pattern, bits: length * 8)
                }
                map[length] = bytes
            }
        case .float:
            let bytes = try encodeFloat(pattern, query.float)
            for length in search.matchLengths { map[length] = bytes }
        }
        return CompiledReplacement(pattern: pattern, bytesByMatchLength: map)
    }

    // MARK: Text

    static func encodeText(_ text: String, _ encoding: SearchQuery.TextEncodingChoice, caseFallback: Bool) throws -> [UInt8] {
        switch encoding {
        case .utf16LittleEndian:
            var out: [UInt8] = []
            out.reserveCapacity(text.utf16.count * 2)
            for u in text.utf16 {
                out.append(UInt8(truncatingIfNeeded: u))
                out.append(UInt8(truncatingIfNeeded: u >> 8))
            }
            return out
        case .editor(let enc):
            let table = enc.table
            var out: [UInt8] = []
            for c in text {
                if let b = table.byte(for: c) {
                    out.append(b)
                } else if c.unicodeScalars.count > 1,
                          case let bytes = c.unicodeScalars.compactMap({ table.byte(for: Character($0)) }),
                          bytes.count == c.unicodeScalars.count {
                    out += bytes // e.g. "\r\n", one Character but two bytes
                } else if caseFallback, let b = caseVariant(of: c, in: table) {
                    out.append(b)
                } else {
                    throw SearchError.unencodableText(encodingName: enc.displayName)
                }
            }
            return out
        }
    }

    private static func caseVariant(of c: Character, in table: EncodingTable) -> UInt8? {
        for variant in [String(c).lowercased(), String(c).uppercased()] where variant.count == 1 {
            if let b = table.byte(for: Character(variant)) { return b }
        }
        return nil
    }

    // MARK: Hex

    /// Whitespace-separated groups of hex digits, paired from the left; a lone last digit is its own byte
    /// ("1 2 3" and "01 02 03" are equal, "ABC" is AB 0C).
    public static func parseHex(_ text: String) throws -> [UInt8] {
        var out: [UInt8] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            var high: UInt8?
            for ch in token {
                guard ch.isASCII, let v = ch.hexDigitValue else { throw SearchError.invalidHexValues(text) }
                if let h = high {
                    out.append(h << 4 | UInt8(v))
                    high = nil
                } else {
                    high = UInt8(v)
                }
            }
            if let h = high { out.append(h) }
        }
        return out
    }

    // MARK: Integers

    struct IntegerValue {
        var negative: Bool
        var magnitude: UInt64
    }

    /// Decimal with optional sign, or hex with a `0x`/`$` prefix or `h` suffix; -2^63 ... 2^64-1.
    static func parseInteger(_ text: String) throws -> IntegerValue {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        guard !t.isEmpty else { throw SearchError.emptyPattern }
        var negative = false
        if t.first == "-" || t.first == "+" {
            negative = t.first == "-"
            t.removeFirst()
        }
        var radix = 10
        if t.lowercased().hasPrefix("0x") {
            radix = 16
            t.removeFirst(2)
        } else if t.first == "$" {
            radix = 16
            t.removeFirst()
        } else if t.count > 1, t.last == "h" || t.last == "H" {
            radix = 16
            t.removeLast()
        }
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && (radix == 16 ? $0.isHexDigit : $0.isWholeNumber) }) else {
            throw SearchError.invalidInteger(text)
        }
        guard let magnitude = UInt64(t, radix: radix), !negative || magnitude <= 1 << 63 else {
            throw SearchError.integerOutOfRange(text, bits: 64)
        }
        return IntegerValue(negative: negative && magnitude != 0, magnitude: magnitude)
    }

    /// Two's complement bytes of `value` at `bits`, or nil if it does not fit with the signedness.
    static func encodeInteger(_ value: IntegerValue, bits: Int, _ options: SearchQuery.IntegerOptions) -> [UInt8]? {
        let unsignedMax = DataInspector.mask(bits)
        let negativeMax = UInt64(1) << (bits - 1)
        let fits = switch options.signedness {
        case .either: value.negative ? value.magnitude <= negativeMax : value.magnitude <= unsignedMax
        case .signed: value.magnitude <= (value.negative ? negativeMax : negativeMax - 1)
        case .unsigned: !value.negative && value.magnitude <= unsignedMax
        }
        guard fits else { return nil }
        let v = value.negative ? 0 &- value.magnitude : value.magnitude
        return DataInspector.writeUInt(v & unsignedMax, bits / 8, littleEndian: options.byteOrder == .littleEndian)
    }

    // MARK: Floats

    /// Parses decimal (or `inf`/`nan`; a comma also works as decimal separator) and encodes it. Single is
    /// parsed directly as Float; Real48 and Extended are parsed at Double precision, then converted
    /// (exactly for Extended, so a literal like 0.1 matches its Double value widened to 80 bits).
    static func encodeFloat(_ text: String, _ options: SearchQuery.FloatOptions) throws -> [UInt8] {
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw SearchError.emptyPattern }
        if !t.contains(".") { t = t.replacingOccurrences(of: ",", with: ".") }
        let lower = t.lowercased()
        let special: Double? = switch lower {
        case "inf", "+inf", "infinity", "+infinity": .infinity
        case "-inf", "-infinity": -.infinity
        case "nan", "+nan", "-nan": .nan
        default: nil
        }
        guard let value = special ?? Double(t) else { throw SearchError.invalidFloat(text) }
        let type = options.type
        let outOfRange = SearchError.floatOutOfRange(text, type: type.displayName)
        // A finite literal that over- or underflows must not silently become infinity or zero.
        if special == nil && (value.isInfinite || (value == 0 && !isZeroLiteral(lower))) { throw outOfRange }
        var bytes: [UInt8]
        if type == .single {
            guard let f = special.map(Float.init) ?? Float(t) else { throw SearchError.invalidFloat(text) }
            if special == nil && (f.isInfinite || (f == 0 && value != 0)) { throw outOfRange }
            bytes = DataInspector.writeUInt(UInt64(f.bitPattern), 4, littleEndian: true)
        } else {
            guard let b = type.encode(value) else { throw outOfRange }
            bytes = b
        }
        if options.byteOrder == .bigEndian { bytes.reverse() }
        return bytes
    }

    private static func isZeroLiteral(_ lower: String) -> Bool {
        let mantissa = lower.hasPrefix("0x") || lower.hasPrefix("-0x") || lower.hasPrefix("+0x")
            ? lower.split(separator: "x", maxSplits: 1).last!.split(separator: "p").first ?? ""
            : lower.split(separator: "e").first ?? ""
        return !mantissa.contains { "123456789abcdef".contains($0) }
    }
}
