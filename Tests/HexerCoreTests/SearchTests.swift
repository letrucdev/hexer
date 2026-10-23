import Foundation
import Testing
@testable import HexerCore

/// A naive reference matcher over the bytes and states read from a snapshot.
struct NaiveMatcher {
    let bytes: [UInt8]
    let defined: [Bool]

    init(_ snapshot: ByteSnapshot) {
        let r = snapshot.read(0..<snapshot.length)
        bytes = r.bytes
        defined = r.states.map { $0 == .original || $0 == .modified }
    }

    /// Longest match at `p` that stays inside `range` and defined bytes; `matchLength` is the reference
    /// definition (the differential tests below check it independently for text).
    func match(_ s: CompiledSearch, at p: Int, in range: Range<Int>) -> Int? {
        var end = p
        while end < range.upperBound && end - p < s.maxLength && defined[end] { end += 1 }
        return end == p ? nil : s.matchLength(bytes[p..<end])
    }

    func findNext(_ s: CompiledSearch, from: Int, direction: SearchDirection, range: Range<Int>, wrap: Bool) -> Range<UInt64>? {
        let range = min(range.lowerBound, bytes.count)..<min(range.upperBound, bytes.count)
        guard !range.isEmpty else { return nil }
        let from = min(max(from, range.lowerBound), range.upperBound)
        let backward = direction == .backward
        var domains = backward ? [range.lowerBound..<from] : [from..<range.upperBound]
        if wrap || direction == .all { domains.append(backward ? from..<range.upperBound : range.lowerBound..<from) }
        for d in domains {
            for p in backward ? Array(d.reversed()) : Array(d) {
                if let l = match(s, at: p, in: range) { return UInt64(p)..<UInt64(p + l) }
            }
        }
        return nil
    }

    func findAll(_ s: CompiledSearch, range: Range<Int>, limit: Int) -> (matches: [Range<UInt64>], truncated: Bool) {
        var out: [Range<UInt64>] = []
        var p = range.lowerBound
        while p < min(range.upperBound, bytes.count) {
            if let l = match(s, at: p, in: range) {
                if out.count == limit { return (out, true) }
                out.append(UInt64(p)..<UInt64(p + l))
                p += l
            } else {
                p += 1
            }
        }
        return (out, false)
    }
}

/// A source whose reads fail when they touch `bad`.
final class FailingSource: ByteSource {
    let bytes: [UInt8]
    let bad: UInt64
    let isFixedSize = false
    var length: UInt64 { UInt64(bytes.count) }

    init(_ bytes: [UInt8], bad: UInt64) {
        self.bytes = bytes
        self.bad = bad
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length else { return 0 }
        let n = min(buffer.count, bytes.count - Int(offset))
        if offset <= bad && bad < offset + UInt64(n) { throw ByteSourceError.unreadable(offset: bad, code: 5) }
        bytes.withUnsafeBytes { buffer.baseAddress!.copyMemory(from: $0.baseAddress! + Int(offset), byteCount: n) }
        return n
    }
}

private func patterns(_ q: SearchQuery) throws -> [[UInt8]] { try SearchEngine.compile(q).patterns }

private func snapshot(_ bytes: [UInt8]) -> ByteSnapshot { EditableBuffer(source: MemoryByteSource(bytes)).snapshot() }

private func w1252(_ s: String) -> [UInt8] { TextEncoding.windowsLatin1.table.encode(s)! }

private func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] } }

@Suite struct SearchCompileTests {
    @Test func hexParsing() throws {
        #expect(try patterns(.hex("4A 6f 0")) == [[0x4A, 0x6F, 0x00]])
        #expect(try patterns(.hex("ABC")) == [[0xAB, 0x0C]])
        #expect(try patterns(.hex(" 1 2\t3\n")) == [[1, 2, 3]])
        #expect(throws: SearchError.noHexValues) { try SearchEngine.compile(.hex("  ")) }
        #expect(throws: SearchError.invalidHexValues("12 zz")) { try SearchEngine.compile(.hex("12 zz")) }
        #expect(SearchError.invalidHexValues("zz").localizedDescription == "The pattern 'zz' contains invalid hex-values.")
    }

    @Test func textEncoding() throws {
        #expect(try patterns(.text("Hx€", caseSensitive: true)) == [[0x48, 0x78, 0x80]])
        #expect(try patterns(.text("a\r\nb", caseSensitive: true)) == [[0x61, 0x0D, 0x0A, 0x62]])
        #expect(try patterns(.text("Hé", encoding: .utf16LittleEndian)) == [[0x48, 0, 0xE9, 0]])
        #expect(try patterns(.text("😀", encoding: .utf16LittleEndian)) == [[0x3D, 0xD8, 0x00, 0xDE]])
        #expect(try patterns(.text("A", encoding: .editor(.ebcdic500))) == [[0xC1]])
        #expect(throws: SearchError.unencodableText(encodingName: "Windows (ANSI)")) {
            try SearchEngine.compile(.text("日本"))
        }
        #expect(throws: SearchError.emptyPattern) { try SearchEngine.compile(.text("")) }
        let message = SearchError.unencodableText(encodingName: "Windows (ANSI)").localizedDescription
        #expect(message == "The search- or replace-pattern contains characters that the selected text encoding (Windows (ANSI)) cannot represent.")
    }

    @Test func integerEncodings() throws {
        #expect(try patterns(.integer("4660", width: .bits16)) == [[0x34, 0x12]])
        #expect(try patterns(.integer("0x1234", width: .bits16, byteOrder: .bigEndian)) == [[0x12, 0x34]])
        #expect(try patterns(.integer("$FF", width: .bits8)) == [[0xFF]])
        #expect(try patterns(.integer("1Fh", width: .bits8)) == [[0x1F]])
        #expect(try patterns(.integer(" +7 ", width: .bits8)) == [[7]])
        #expect(try patterns(.integer("-1", width: .bits8)) == [[0xFF]])
        #expect(try patterns(.integer("255", width: .bits8)) == [[0xFF]])
        #expect(try patterns(.integer("-2", width: .bits24)) == [[0xFE, 0xFF, 0xFF]])
        #expect(try patterns(.integer("-2", width: .bits24, byteOrder: .bigEndian)) == [[0xFF, 0xFF, 0xFE]])
        #expect(try patterns(.integer("8388607", width: .bits24, signedness: .signed)) == [[0xFF, 0xFF, 0x7F]])
        #expect(try patterns(.integer("305419896", width: .bits32)) == [[0x78, 0x56, 0x34, 0x12]])
        #expect(try patterns(.integer("-9223372036854775808", width: .bits64)) == [[0, 0, 0, 0, 0, 0, 0, 0x80]])
        #expect(try patterns(.integer("18446744073709551615", width: .bits64)) == [[UInt8](repeating: 0xFF, count: 8)])
        #expect(try patterns(.integer("5")).map(\.count) == [1, 2, 3, 4, 8])
        #expect(try patterns(.integer("300")).map(\.count) == [2, 3, 4, 8])
        #expect(try patterns(.integer("-129")).map(\.count) == [2, 3, 4, 8])
        #expect(try patterns(.integer("200", signedness: .signed)).map(\.count) == [2, 3, 4, 8])
        #expect(try patterns(.integer("-0", width: .bits16)) == [[0, 0]])

        let errors: [(SearchQuery, SearchError)] = [
            (.integer("256", width: .bits8), .integerOutOfRange("256", bits: 8)),
            (.integer("-129", width: .bits8), .integerOutOfRange("-129", bits: 8)),
            (.integer("128", width: .bits8, signedness: .signed), .integerOutOfRange("128", bits: 8)),
            (.integer("-1", width: .bits16, signedness: .unsigned), .integerOutOfRange("-1", bits: 16)),
            (.integer("-1", signedness: .unsigned), .integerOutOfRange("-1", bits: 64)),
            (.integer("16777216", width: .bits24), .integerOutOfRange("16777216", bits: 24)),
            (.integer("18446744073709551616"), .integerOutOfRange("18446744073709551616", bits: 64)),
            (.integer("-9223372036854775809"), .integerOutOfRange("-9223372036854775809", bits: 64)),
            (.integer("12a"), .invalidInteger("12a")),
            (.integer("1.5"), .invalidInteger("1.5")),
            (.integer(""), .emptyPattern),
        ]
        for (query, error) in errors {
            #expect(throws: error) { try SearchEngine.compile(query) }
        }
        #expect(SearchError.integerOutOfRange("256", bits: 8).localizedDescription == "\"256\" is out of range representable with 8 bits.")
    }

    /// Random values of every width, order and signedness against the standard library's own encoding.
    @Test func integerEncodingMatchesStandardLibrary() throws {
        var rng = SeededRandom(state: 42)
        for width in SearchQuery.IntegerWidth.allCases where width != .any {
            let bits = width.rawValue
            for order in SearchQuery.ByteOrder.allCases {
                for signedness in SearchQuery.Signedness.allCases {
                    for _ in 0..<50 {
                        let raw = UInt64.random(in: 0...UInt64.max, using: &rng) >> UInt64(64 - bits)
                        let negative = signedness != .unsigned && Bool.random(using: &rng)
                        let signedValue: Int64 = negative ? -Int64(raw >> 1) - 1 : Int64(bitPattern: raw >> (signedness == .signed ? 1 : 0))
                        let text = negative || signedness == .signed ? String(signedValue) : String(raw)
                        let value = negative || signedness == .signed ? UInt64(bitPattern: signedValue) : raw
                        var expected = withUnsafeBytes(of: value.littleEndian) { Array($0.prefix(bits / 8)) }
                        if order == .bigEndian { expected.reverse() }
                        let q = SearchQuery.integer(text, width: width, byteOrder: order, signedness: signedness)
                        #expect(try patterns(q) == [expected], "\(text) \(bits) \(order) \(signedness)")
                    }
                }
            }
        }
    }

    @Test func floatEncodings() throws {
        #expect(try patterns(.float("1.5", type: .single)) == [[0, 0, 0xC0, 0x3F]])
        #expect(try patterns(.float("1,5", type: .single)) == [[0, 0, 0xC0, 0x3F]])
        #expect(try patterns(.float("1.5", type: .single, byteOrder: .bigEndian)) == [[0x3F, 0xC0, 0, 0]])
        #expect(try patterns(.float("0.1", type: .single)) == [[0xCD, 0xCC, 0xCC, 0x3D]])
        #expect(try patterns(.float("1.5", type: .double)) == [[0, 0, 0, 0, 0, 0, 0xF8, 0x3F]])
        #expect(try patterns(.float("-2", type: .double, byteOrder: .bigEndian)) == [[0xC0, 0, 0, 0, 0, 0, 0, 0]])
        #expect(try patterns(.float("-inf", type: .double)) == [[0, 0, 0, 0, 0, 0, 0xF0, 0xFF]])
        // Turbo Pascal Real48 vectors.
        #expect(try patterns(.float("1", type: .real48)) == [[0x81, 0, 0, 0, 0, 0]])
        #expect(try patterns(.float("10", type: .real48)) == [[0x84, 0, 0, 0, 0, 0x20]])
        #expect(try patterns(.float("-2.5", type: .real48)) == [[0x82, 0, 0, 0, 0, 0xA0]])
        #expect(try patterns(.float("0", type: .real48)) == [[0, 0, 0, 0, 0, 0]])
        #expect(try patterns(.float("3.141592653589793", type: .real48)) == [[0x82, 0x21, 0xA2, 0xDA, 0x0F, 0x49]])
        // x87 Extended vectors (parsed at Double precision, widened exactly).
        #expect(try patterns(.float("1", type: .extended)) == [[0, 0, 0, 0, 0, 0, 0, 0x80, 0xFF, 0x3F]])
        #expect(try patterns(.float("-2.5", type: .extended)) == [[0, 0, 0, 0, 0, 0, 0, 0xA0, 0x00, 0xC0]])
        #expect(try patterns(.float("3.141592653589793", type: .extended)) == [[0, 0xC0, 0x68, 0x21, 0xA2, 0xDA, 0x0F, 0xC9, 0x00, 0x40]])
        #expect(try patterns(.float("inf", type: .extended)) == [[0, 0, 0, 0, 0, 0, 0, 0x80, 0xFF, 0x7F]])
        #expect(try patterns(.float("1", type: .extended, byteOrder: .bigEndian)) == [[0x3F, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0]])

        let errors: [(SearchQuery, SearchError)] = [
            (.float("abc", type: .double), .invalidFloat("abc")),
            (.float("1e39", type: .single), .floatOutOfRange("1e39", type: "Single (float32), 4 bytes")),
            (.float("1e-50", type: .single), .floatOutOfRange("1e-50", type: "Single (float32), 4 bytes")),
            (.float("1e400", type: .double), .floatOutOfRange("1e400", type: "Double (float64), 8 bytes")),
            (.float("1e300", type: .real48), .floatOutOfRange("1e300", type: "Real, 6 bytes")),
            (.float("inf", type: .real48), .floatOutOfRange("inf", type: "Real, 6 bytes")),
            (.float("nan", type: .real48), .floatOutOfRange("nan", type: "Real, 6 bytes")),
        ]
        for (query, error) in errors {
            #expect(throws: error) { try SearchEngine.compile(query) }
        }
    }

    @Test func floatDecodersRoundTrip() {
        var rng = SeededRandom(state: 7)
        for _ in 0..<500 {
            // Values with at most 40 significant bits are exact in Real48 and every wider type.
            let mantissa = Double(Int64.random(in: -(1 << 39)...(1 << 39), using: &rng))
            let value = mantissa * Double(sign: .plus, exponent: Int.random(in: -80...60, using: &rng), significand: 1)
            for type in SearchQuery.FloatType.allCases where type != .single {
                let bytes = type.encode(value)!
                #expect(bytes.count == type.byteCount)
                #expect(type.decode(bytes) == value, "\(type) \(value)")
            }
        }
        #expect(SearchQuery.FloatType.extended.decode(SearchQuery.FloatType.extended.encode(5e-324)!) == 5e-324)
        #expect(SearchQuery.FloatType.real48.encode(Double.leastNormalMagnitude) == nil)
    }

    @Test func caseFoldTables() {
        let fold = CaseFold.table(for: .windowsLatin1)
        #expect(fold[0x41] == 0x61)
        #expect(fold[0xC9] == 0xE9) // É → é
        #expect(fold[0x9F] == 0xFF) // Ÿ → ÿ
        #expect(fold[0xDF] == 0xDF) // ß stays
        #expect(CaseFold.table(for: .ebcdic500)[0xC1] == 0x81)
        #expect(CaseFold.utf16Table[0x0414] == 0x0434) // Д → д
        #expect(CaseFold.utf16Table[0x0178] == 0x00FF) // Ÿ → ÿ
        #expect(CaseFold.utf16Table[0xD800] == 0xD800)
    }

    @Test func queryIsCodable() throws {
        let q = SearchQuery(.integer, pattern: "-5", text: .init(encoding: .editor(.macRoman), caseSensitive: true),
                            integer: .init(width: .bits24, byteOrder: .bigEndian, signedness: .signed),
                            float: .init(type: .real48))
        let decoded = try JSONDecoder().decode(SearchQuery.self, from: JSONEncoder().encode(q))
        #expect(decoded == q)
    }
}

@Suite struct SearchEngineTests {
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func randomDifferential(seed: UInt64) throws {
        var rng = SeededRandom(state: seed)
        let alphabet: [UInt8] = [0x00, 0x41, 0x42, 0x61]
        func randomBytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in alphabet.randomElement(using: &rng)! } }
        let buffer = EditableBuffer(source: MemoryByteSource(randomBytes(Int.random(in: 0...2500, using: &rng))))
        for _ in 0..<Int.random(in: 0...8, using: &rng) {
            let a = UInt64.random(in: 0...buffer.length, using: &rng)
            let b = min(buffer.length, a + UInt64.random(in: 0...12, using: &rng))
            let sel = Selection(caret: a)
            if Bool.random(using: &rng) {
                try buffer.apply("Gap", replacing: a..<b, with: [Piece.undefined(length: UInt64.random(in: 1...9, using: &rng))],
                                 selectionBefore: sel, selectionAfter: sel)
            } else {
                try buffer.insert(randomBytes(Int.random(in: 1...30, using: &rng)), at: a, selectionBefore: sel)
            }
        }
        let snap = buffer.snapshot()
        let naive = NaiveMatcher(snap)
        let length = Int(snap.length)
        for _ in 0..<60 {
            let query: SearchQuery = switch Int.random(in: 0..<5, using: &rng) {
            case 0, 1: .hex(randomBytes(Int.random(in: 1...5, using: &rng)).map { String(format: "%02X", $0) }.joined(separator: " "))
            case 2: .integer(["0", "65", "16705", "-1"].randomElement(using: &rng)!, byteOrder: Bool.random(using: &rng) ? .littleEndian : .bigEndian)
            case 3: .text(["a", "Ab", "aBa", "B"].randomElement(using: &rng)!, caseSensitive: false)
            default: .text(["a", "AB"].randomElement(using: &rng)!, encoding: .utf16LittleEndian, caseSensitive: Bool.random(using: &rng))
            }
            let search = try SearchEngine.compile(query)
            let chunk = [1, 2, 3, 5, 8, 64, 1000, SearchEngine.defaultChunkSize].randomElement(using: &rng)!
            let lo = Int.random(in: 0...length, using: &rng)
            let range = Bool.random(using: &rng) ? 0..<length : lo..<Int.random(in: lo...length, using: &rng)
            let from = Int.random(in: 0...length, using: &rng)
            let direction = SearchDirection.allCases.randomElement(using: &rng)!
            let wrap = Bool.random(using: &rng)
            let got = try SearchEngine.findNext(in: snap, query: search, from: UInt64(from), direction: direction,
                                                range: UInt64(range.lowerBound)..<UInt64(range.upperBound), wrap: wrap, chunkSize: chunk)
            let want = naive.findNext(search, from: from, direction: direction, range: range, wrap: wrap)
            #expect(got == want, "\(query.pattern) from \(from) \(direction) wrap \(wrap) range \(range) chunk \(chunk)")

            let limit = Bool.random(using: &rng) ? Int.max : Int.random(in: 0...5, using: &rng)
            let all = try SearchEngine.findAll(in: snap, query: search, range: UInt64(range.lowerBound)..<UInt64(range.upperBound),
                                               limit: limit, chunkSize: chunk)
            let wantAll = naive.findAll(search, range: range, limit: limit)
            #expect(all.matches == wantAll.matches && all.truncated == wantAll.truncated, "\(query.pattern) all \(range) chunk \(chunk)")
        }
    }

    @Test func gapsNeverMatch() throws {
        let buffer = EditableBuffer(source: MemoryByteSource(Array("ABCDEF".utf8)))
        try buffer.apply("Gap", replacing: 3..<3, with: [Piece.undefined(length: 2)],
                         selectionBefore: Selection(caret: 3), selectionAfter: Selection(caret: 3))
        let snap = buffer.snapshot() // A B C ?? ?? D E F
        for pattern in ["43 44", "43 00", "00 00", "00 44", "00"] {
            let s = try SearchEngine.compile(.hex(pattern))
            for chunk in [1, 2, 3, 100] {
                #expect(try SearchEngine.findAll(in: snap, query: s, chunkSize: chunk).matches.isEmpty)
                #expect(try SearchEngine.findNext(in: snap, query: s, from: 8, direction: .backward, chunkSize: chunk) == nil)
            }
        }
        let de = try SearchEngine.compile(.hex("44 45"))
        #expect(try SearchEngine.findNext(in: snap, query: de, from: 0, direction: .forward, chunkSize: 1) == 5..<7)
        #expect(SearchEngine.definedSegments(of: snap, in: 0..<8) == [0..<3, 5..<8])
        #expect(SearchEngine.definedSegments(of: snap, in: 4..<6) == [5..<6])
    }

    @Test func unreadableBytesNeverMatch() throws {
        var data = [UInt8](repeating: 0x2E, count: 200_000)
        let needle: [UInt8] = Array("XYZ".utf8)
        var planted: [Int] = []
        for p in stride(from: 500, to: data.count - 3, by: 997) {
            data.replaceSubrange(p..<p + 3, with: needle)
            planted.append(p)
        }
        let bad: UInt64 = 100_000
        data.replaceSubrange(99_999..<100_002, with: needle) // straddles the unreadable byte
        planted.append(99_999)
        planted.sort()
        let snap = EditableBuffer(source: FailingSource(data, bad: bad)).snapshot()
        let search = try SearchEngine.compile(.text("XYZ", caseSensitive: true))
        for chunk in [5_000, 65_536, SearchEngine.defaultChunkSize] {
            let found = try SearchEngine.findAll(in: snap, query: search, chunkSize: chunk).matches
            #expect(found.allSatisfy { !$0.contains(bad) && Array(data[Int($0.lowerBound)..<Int($0.upperBound)]) == needle })
            let expected = planted.filter { abs($0 - Int(bad)) > ChunkCache.blockSize }.map { UInt64($0)..<UInt64($0 + 3) }
            #expect(Set(expected).isSubset(of: Set(found)), "chunk \(chunk)")
            let back = try SearchEngine.findNext(in: snap, query: search, from: 140_000, direction: .backward, chunkSize: chunk)
            #expect(back.map { !$0.contains(bad) && $0.upperBound <= 140_000 + 2 } == true)
        }
    }

    @Test func caseInsensitiveWindows1252() throws {
        let text = "Ça va? ÉCOLE école Écolé ŸES ÿes straße STRASSE"
        let snap = snapshot(w1252(text))
        func hits(_ pattern: String, caseSensitive: Bool = false) throws -> [String] {
            let s = try SearchEngine.compile(.text(pattern, caseSensitive: caseSensitive))
            return try SearchEngine.findAll(in: snap, query: s, chunkSize: 3).matches.map {
                TextEncoding.windowsLatin1.table.decode(snap.bytes($0))
            }
        }
        #expect(try hits("école") == ["ÉCOLE", "école"])
        #expect(try hits("école", caseSensitive: true) == ["école"])
        #expect(try hits("ÿes") == ["ŸES", "ÿes"])
        #expect(try hits("ça") == ["Ça"])
        #expect(try hits("STRASSE") == ["STRASSE"])
        #expect(try hits("Straße") == ["straße"])
    }

    /// Case-insensitive 8-bit text against an oracle that lowercases decoded strings.
    @Test(arguments: [11, 12, 13])
    func caseInsensitiveTextDifferential(seed: UInt64) throws {
        var rng = SeededRandom(state: seed)
        let alphabet: [Character] = ["a", "A", "é", "É", "ÿ", "Ÿ", "x", "ß"]
        let chars = (0..<3000).map { _ in alphabet.randomElement(using: &rng)! }
        let snap = snapshot(w1252(String(chars)))
        for _ in 0..<20 {
            let pattern = String((0..<Int.random(in: 1...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            let s = try SearchEngine.compile(.text(pattern))
            var expected: [Range<UInt64>] = []
            var p = 0
            while p + pattern.count <= chars.count {
                if String(chars[p..<p + pattern.count]).lowercased() == pattern.lowercased() {
                    expected.append(UInt64(p)..<UInt64(p + pattern.count))
                    p += pattern.count
                } else {
                    p += 1
                }
            }
            let chunk = [1, 4, 77, 4096].randomElement(using: &rng)!
            #expect(try SearchEngine.findAll(in: snap, query: s, chunkSize: chunk).matches == expected, "\(pattern)")
            let from = UInt64.random(in: 0...UInt64(chars.count), using: &rng)
            let back = try SearchEngine.findNext(in: snap, query: s, from: from, direction: .backward, chunkSize: chunk)
            let wantBack = (0..<Int(from)).reversed().first {
                $0 + pattern.count <= chars.count && String(chars[$0..<$0 + pattern.count]).lowercased() == pattern.lowercased()
            }
            #expect(back?.lowerBound == wantBack.map(UInt64.init), "\(pattern) back from \(from)")
        }
    }

    @Test func utf16Text() throws {
        for prefix in [0, 1] {
            let data = [UInt8](repeating: 0x20, count: prefix) + utf16("xПривет мир ÿ Ÿ x")
            let snap = snapshot(data)
            func hits(_ pattern: String, caseSensitive: Bool) throws -> [UInt64] {
                let s = try SearchEngine.compile(.text(pattern, encoding: .utf16LittleEndian, caseSensitive: caseSensitive))
                return try (1...7).flatMap { chunk in
                    try SearchEngine.findAll(in: snap, query: s, chunkSize: chunk).matches.map(\.lowerBound)
                }
            }
            let p = UInt64(prefix)
            #expect(try hits("пРИВЕТ", caseSensitive: false) == Array(repeating: p + 2, count: 7))
            #expect(try hits("пРИВЕТ", caseSensitive: true).isEmpty)
            #expect(try hits("Привет", caseSensitive: true) == Array(repeating: p + 2, count: 7))
            #expect(try hits("ÿ", caseSensitive: false) == Array(repeating: [p + 24, p + 28], count: 7).flatMap { $0 })
            #expect(try hits("X", caseSensitive: false) == Array(repeating: [p, p + 32], count: 7).flatMap { $0 })
        }
    }

    /// UTF-16 case-insensitive search at every alignment against a string-lowercasing oracle.
    @Test(arguments: [21, 22])
    func utf16Differential(seed: UInt64) throws {
        var rng = SeededRandom(state: seed)
        let alphabet: [Character] = ["a", "A", "Д", "д", "ÿ", "Ÿ", "x"]
        var data: [UInt8] = []
        while data.count < 4000 {
            if Bool.random(using: &rng) { data.append(0x78) } // misalign the following text
            data += utf16(String((0..<Int.random(in: 1...20, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }))
        }
        let snap = snapshot(data)
        for _ in 0..<15 {
            let pattern = String((0..<Int.random(in: 1...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            let length = pattern.utf16.count * 2
            func matches(at p: Int) -> Bool {
                guard p + length <= data.count else { return false }
                let units = stride(from: p, to: p + length, by: 2).map { UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8 }
                return String(decoding: units, as: UTF16.self).lowercased() == pattern.lowercased()
            }
            var expected: [Range<UInt64>] = []
            var p = 0
            while p < data.count {
                if matches(at: p) {
                    expected.append(UInt64(p)..<UInt64(p + length))
                    p += length
                } else {
                    p += 1
                }
            }
            let s = try SearchEngine.compile(.text(pattern, encoding: .utf16LittleEndian))
            let chunk = [1, 3, 64, 4096].randomElement(using: &rng)!
            #expect(try SearchEngine.findAll(in: snap, query: s, chunkSize: chunk).matches == expected, "\(pattern)")
            let from = Int.random(in: 0...data.count, using: &rng)
            let back = try SearchEngine.findNext(in: snap, query: s, from: UInt64(from), direction: .backward, chunkSize: chunk)
            #expect(back?.lowerBound == (0..<from).reversed().first(where: matches).map(UInt64.init), "\(pattern) back")
        }
    }

    @Test func integerAnyWidthPrefersLongest() throws {
        let data: [UInt8] = [0x05, 0, 0, 0, 0x07, 0x05, 0, 0x01, 0x05, 0, 0, 0, 0, 0, 0, 0]
        let snap = snapshot(data)
        let le = try SearchEngine.compile(.integer("5"))
        #expect(try SearchEngine.findAll(in: snap, query: le, chunkSize: 2).matches == [0..<4, 5..<7, 8..<16])
        #expect(try SearchEngine.findNext(in: snap, query: le, from: 1, direction: .forward) == 5..<7)
        #expect(try SearchEngine.findNext(in: snap, query: le, from: 16, direction: .backward, chunkSize: 3) == 8..<16)
        // 0x0705 big-endian: leftmost wins over longest (int32 00 00 07 05 at 2 before int16 07 05 at 4).
        let be = try SearchEngine.compile(.integer("1797", byteOrder: .bigEndian))
        #expect(try SearchEngine.findAll(in: snap, query: be, chunkSize: 1).matches == [2..<6])
        let be16 = try SearchEngine.compile(.integer("1797", width: .bits16, byteOrder: .bigEndian))
        #expect(try SearchEngine.findAll(in: snap, query: be16, chunkSize: 1).matches == [4..<6])
        let int32 = try SearchEngine.compile(.integer("117440512", width: .bits32, byteOrder: .bigEndian)) // 0x07000000
        #expect(try SearchEngine.findAll(in: snap, query: int32).matches.isEmpty)
    }

    @Test func floatSearch() throws {
        for type in SearchQuery.FloatType.allCases {
            for order in SearchQuery.ByteOrder.allCases {
                let search = try SearchEngine.compile(.float("-12.375", type: type, byteOrder: order))
                var bytes = type.encode(-12.375)!
                if order == .bigEndian { bytes.reverse() }
                let data = [1, 2, 3] + bytes + [9] + bytes
                let found = try SearchEngine.findAll(in: snapshot(data), query: search, chunkSize: 4).matches
                #expect(found == [3..<3 + UInt64(bytes.count), 4 + UInt64(bytes.count)..<4 + 2 * UInt64(bytes.count)])
            }
        }
    }

    @Test func directionsAndWrapping() throws {
        let snap = snapshot(Array("ab..ab..ab".utf8))
        let s = try SearchEngine.compile(.text("ab", caseSensitive: true))
        func next(_ from: UInt64, _ d: SearchDirection, wrap: Bool = false, range: Range<UInt64>? = nil) throws -> Range<UInt64>? {
            try SearchEngine.findNext(in: snap, query: s, from: from, direction: d, range: range, wrap: wrap, chunkSize: 2)
        }
        #expect(try next(0, .forward) == 0..<2)
        #expect(try next(1, .forward) == 4..<6)
        #expect(try next(9, .forward) == nil)
        #expect(try next(9, .all) == 0..<2)
        #expect(try next(9, .forward, wrap: true) == 0..<2)
        #expect(try next(8, .backward) == 4..<6)
        #expect(try next(0, .backward) == nil)
        #expect(try next(0, .backward, wrap: true) == 8..<10)
        #expect(try next(5, .forward, range: 1..<9) == nil)
        #expect(try next(5, .all, range: 1..<9) == 4..<6) // wrapped hit spans `from`
        #expect(try next(5, .backward, wrap: true, range: 5..<10) == 8..<10)
        // Overlapping find-next vs non-overlapping find-all.
        let aaa = snapshot(Array("aaaa".utf8))
        let aa = try SearchEngine.compile(.text("aa", caseSensitive: true))
        #expect(try SearchEngine.findNext(in: aaa, query: aa, from: 1, direction: .forward) == 1..<3)
        #expect(try SearchEngine.findAll(in: aaa, query: aa).matches == [0..<2, 2..<4])
    }

    @Test func cancellationAndProgress() throws {
        let snap = snapshot([UInt8](repeating: 0x41, count: 10_000))
        let s = try SearchEngine.compile(.hex("42"))
        var polls = 0
        #expect(throws: CancellationError.self) {
            _ = try SearchEngine.findAll(in: snap, query: s, chunkSize: 100, isCancelled: { polls += 1; return polls > 3 })
        }
        #expect(polls == 4)
        #expect(throws: CancellationError.self) {
            _ = try SearchEngine.findNext(in: snap, query: s, from: 10_000, direction: .backward, chunkSize: 100, isCancelled: { true })
        }
        var reports: [Double] = []
        _ = try SearchEngine.findNext(in: snap, query: s, from: 5_000, direction: .all, chunkSize: 1000, progress: { reports.append($0) })
        #expect(reports.count == 10)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(reports.last == 1)
    }

    @Test func largeSearchIsFast() throws {
        let size = 32 << 20
        var data = [UInt8](repeating: 0, count: size)
        arc4random_buf(&data, size)
        let needle = w1252("Needle!")
        let offsets = [17, (4 << 20) - 3, size - needle.count]
        for o in offsets { data.replaceSubrange(o..<o + needle.count, with: needle) }
        let snap = snapshot(data)
        let expected = offsets.map { UInt64($0)..<UInt64($0 + needle.count) }

        var start = Date()
        let exact = try SearchEngine.findAll(in: snap, query: SearchEngine.compile(.text("Needle!", caseSensitive: true)))
        let exactTime = Date().timeIntervalSince(start)
        #expect(exact.matches == expected)

        start = Date()
        let folded = try SearchEngine.findAll(in: snap, query: SearchEngine.compile(.text("nEEDLE!")))
        let foldedTime = Date().timeIntervalSince(start)
        #expect(folded.matches.count >= 3 && Set(expected).isSubset(of: Set(folded.matches)))

        start = Date()
        let back = try SearchEngine.findNext(in: snap, query: SearchEngine.compile(.hex("4E 65 65 64 6C 65 21")),
                                             from: UInt64(size - needle.count), direction: .backward)
        let backTime = Date().timeIntervalSince(start)
        #expect(back == expected[1])
        print("32 MiB: exact \(exactTime) s, case-insensitive \(foldedTime) s, backward \(backTime) s")
        #expect(exactTime < 5 && foldedTime < 15 && backTime < 15)
    }
}

@Suite struct ReplaceEngineTests {
    /// Replace all on a many-piece buffer against a plain array replace.
    @Test(arguments: [1, 2, 3, 4, 5])
    func replaceAllMatchesArrayModel(seed: UInt64) throws {
        var rng = SeededRandom(state: seed)
        let alphabet: [UInt8] = [0x41, 0x42, 0x43]
        func randomBytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in alphabet.randomElement(using: &rng)! } }
        let buffer = EditableBuffer(source: MemoryByteSource(randomBytes(1500)))
        for _ in 0..<40 {
            let a = UInt64.random(in: 0...buffer.length, using: &rng)
            try buffer.overwrite(randomBytes(Int.random(in: 1...6, using: &rng)), at: a, selectionBefore: Selection(caret: a))
        }
        #expect(buffer.tree.pieceCount > 20)
        for _ in 0..<10 {
            let model = buffer.snapshot().bytes(0..<buffer.length)
            let pattern = randomBytes(Int.random(in: 1...3, using: &rng))
            let replacement = randomBytes(Int.random(in: 0...5, using: &rng))
            let search = try SearchEngine.compile(.hex(pattern.map { String(format: "%02X", $0) }.joined()))
            let compiled = try SearchEngine.compileReplacement(replacement.map { String(format: "%02X", $0) }.joined(), for: search)
            #expect(compiled.bytes(forMatchLength: pattern.count) == replacement)
            #expect(compiled.changesLength == (pattern.count != replacement.count))
            let matches = try ReplaceEngine.findMatches(in: buffer.snapshot(), search: search, chunkSize: 7)
            let pieces = buffer.addPieces(replacement)
            let tree = ReplaceEngine.replacingAll(in: buffer.snapshot(), matches: matches, with: pieces)
            #expect(tree.validate())
            try buffer.apply("Replace all", tree: tree, selectionBefore: Selection(caret: 0), selectionAfter: Selection(caret: 0))

            var expected: [UInt8] = []
            var i = 0
            while i < model.count {
                if model[i...].starts(with: pattern) {
                    expected += replacement
                    i += pattern.count
                } else {
                    expected.append(model[i])
                    i += 1
                }
            }
            #expect(buffer.snapshot().bytes(0..<buffer.length) == expected)
        }
    }

    @Test func adjacentMatches() throws {
        for replacement in ["B", "CCC", ""] {
            let buffer = EditableBuffer(source: MemoryByteSource(Array("AAAAAA".utf8)))
            let search = try SearchEngine.compile(.text("AA", caseSensitive: true))
            let matches = try ReplaceEngine.findMatches(in: buffer.snapshot(), search: search)
            #expect(matches == [0..<2, 2..<4, 4..<6])
            let bytes = try SearchEngine.compileReplacement(replacement, for: search).bytes(forMatchLength: 2)
            let tree = ReplaceEngine.replacingAll(in: buffer.snapshot(), matches: matches, with: buffer.addPieces(bytes))
            try buffer.apply("Replace all", tree: tree, selectionBefore: Selection(caret: 0), selectionAfter: Selection(caret: 0))
            #expect(buffer.snapshot().bytes(0..<buffer.length) == Array(String(repeating: replacement, count: 3).utf8))
            buffer.undo()
            #expect(buffer.snapshot().bytes(0..<buffer.length) == Array("AAAAAA".utf8))
        }
    }

    @Test func integerAnyReplacementKeepsEachWidth() throws {
        let buffer = EditableBuffer(source: MemoryByteSource([0x05, 0, 0x01, 0x05, 0, 0, 0, 0x02]))
        let search = try SearchEngine.compile(.integer("5"))
        let replacement = try SearchEngine.compileReplacement("7", for: search)
        #expect(!replacement.changesLength)
        let pieces = replacement.bytesByMatchLength.mapValues { buffer.addPieces($0) }
        let matches = try ReplaceEngine.findMatches(in: buffer.snapshot(), search: search)
        let tree = ReplaceEngine.replacingAll(in: buffer.tree, matches: matches) { pieces[$0.count]! }
        try buffer.apply("Replace all", tree: tree, selectionBefore: Selection(caret: 0), selectionAfter: Selection(caret: 0))
        #expect(buffer.snapshot().bytes(0..<8) == [0x07, 0, 0x01, 0x07, 0, 0, 0, 0x02])
        #expect(throws: SearchError.integerOutOfRange("300", bits: 8)) { try SearchEngine.compileReplacement("300", for: search) }
    }

    @Test func fixedSizeCheck() throws {
        let search = try SearchEngine.compile(.text("ab"))
        #expect(throws: SearchError.sizeMismatch(search: 2, replacement: 3)) {
            try SearchEngine.compileReplacement("abc", for: search).validateFixedSize()
        }
        #expect(throws: Never.self) { try SearchEngine.compileReplacement("xy", for: search).validateFixedSize() }
        #expect(throws: SearchError.unencodableText(encodingName: "Windows (ANSI)")) {
            try SearchEngine.compileReplacement("日", for: search)
        }
        let disk = EditableBuffer(source: MemoryByteSource(Array("abab".utf8), fixedSize: true))
        let tree = ReplaceEngine.replacingAll(in: disk.snapshot(), matches: [0..<2], with: disk.addPieces([1]))
        #expect(throws: EditError.sizeChangeNotAllowed) {
            try disk.apply("Replace all", tree: tree, selectionBefore: Selection(caret: 0), selectionAfter: Selection(caret: 0))
        }
    }

    @Test func nonOverlappingFilter() {
        #expect(ReplaceEngine.nonOverlapping([3..<5, 0..<3, 2..<4, 1..<2, 6..<6, 5..<7]) == [0..<3, 3..<5, 5..<7])
    }
}
