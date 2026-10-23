import Foundation
import Testing
@testable import HexerCore

@Suite struct TextEncodingTests {
    @Test func windows1252() {
        let t = TextEncoding.windowsLatin1.table
        #expect(t.characters[0x41] == "A")
        #expect(t.characters[0x80] == "€")
        #expect(t.characters[0x81] == nil)
        #expect(t.display[0x0A] == ".")
        #expect(t.byte(for: "€") == 0x80)
        #expect(t.encode("Hx€") == [0x48, 0x78, 0x80])
        #expect(t.encode("日") == nil)
    }

    @Test func oemAndEbcdic() {
        #expect(TextEncoding.dosLatinUS.table.characters[0xB0] == "░")
        #expect(TextEncoding.dosLatinUS.table.characters[0xDB] == "█")
        #expect(TextEncoding.ebcdic500.table.characters[0xC1] == "A")
        #expect(TextEncoding.ebcdic500.table.characters[0x81] == "a")
        // Code page 500 (as in HxD), not 037: brackets at 4A/5A, "!" at 4F.
        #expect(TextEncoding.ebcdic500.table.characters[0x4A] == "[")
        #expect(TextEncoding.ebcdic500.table.characters[0x5A] == "]")
        #expect(TextEncoding.ebcdic500.table.characters[0x4F] == "!")
        #expect(TextEncoding.macRoman.table.characters[0x80] == "Ä")
    }
}

@Suite struct NumberBaseTests {
    @Test func formatAndParse() {
        #expect(NumberBase.hexadecimal.format(0x4E, minDigits: 8) == "0000004E")
        #expect(NumberBase.hexadecimal.format(255, uppercase: false) == "ff")
        #expect(NumberBase.octal.format(8) == "10")
        #expect(NumberBase.hexadecimal.parse(" 0x1F ") == 31)
        #expect(NumberBase.hexadecimal.parse("1Fh") == 31)
        #expect(NumberBase.decimal.parse("1F") == nil)
        #expect(NumberBase.hexadecimal.digits(forLength: 0x1_0000_0000) == 8)
        #expect(NumberBase.hexadecimal.digits(forLength: 0x1_0000_0001) == 9)
    }
}

@Suite struct HexLayoutTests {
    let layout = HexLayout(bytesPerRow: 16, groupSize: 1, offsetDigits: 8, charWidth: 10, leftInset: 0, columnGapChars: 2)

    @Test func geometry() {
        #expect(layout.hexStartX == 100)
        #expect(layout.hexCharCount == 47)
        #expect(layout.hexX(byte: 1) == 130)
        #expect(layout.textStartX == 100 + 470 + 20)
    }

    @Test func hitTesting() {
        #expect(layout.hitTest(x: 5) == .offset)
        #expect(layout.hitTest(x: 101) == .hex(byte: 0, nibble: 0))
        #expect(layout.hitTest(x: 111) == .hex(byte: 0, nibble: 1))
        #expect(layout.hitTest(x: 121) == .hex(byte: 0, nibble: 1)) // space after byte 0
        #expect(layout.hitTest(x: 131) == .hex(byte: 1, nibble: 0))
        #expect(layout.hitTest(x: 565) == .hex(byte: 15, nibble: 1))
        #expect(layout.hitTest(x: 591) == .text(byte: 0))
        #expect(layout.hitTest(x: 5000) == .text(byte: 15))
    }

    @Test func groups() {
        var l = layout
        l.groupSize = 4
        #expect(l.hexCharCount == 16 * 2 + 3)
        #expect(l.hexCharsBefore(4) == 9)
        #expect(l.hitTest(x: 100 + 8 * 10 + 1) == .hex(byte: 3, nibble: 1))
        #expect(l.hitTest(x: 100 + 9 * 10 + 1) == .hex(byte: 4, nibble: 0))
    }

    @Test func fitting() {
        let w = layout.totalWidth
        #expect(layout.fittingBytesPerRow(width: w) == 16)
        #expect(layout.fittingBytesPerRow(width: w + 39) == 16)
        #expect(layout.fittingBytesPerRow(width: w + 40) == 17)
    }
}

@Suite struct VirtualScrollTests {
    @Test func exactMode() {
        let m = VirtualScrollMapper(totalRows: 1000, rowHeight: 20, viewportHeight: 400)
        #expect(!m.isScaled)
        #expect(m.topRow(forScrollY: 200) == 10)
        #expect(m.scrollY(forTopRow: 10) == 200)
    }

    @Test func scaledModeRoundTripsAtTerabyteScale() {
        let rows = UInt64(1) << 36 // 1 TiB at 16 bytes per row
        let m = VirtualScrollMapper(totalRows: rows, rowHeight: 20, viewportHeight: 800)
        #expect(m.isScaled)
        #expect(m.documentHeight == m.maxDocumentHeight)
        for row in [0.0, 1.0, 12345.0, m.maxTopRow / 2, m.maxTopRow] {
            let y = m.scrollY(forTopRow: row)
            #expect(abs(m.topRow(forScrollY: y) - row) < 0.01)
        }
        #expect(m.topRow(forScrollY: m.documentHeight) == m.maxTopRow)
    }
}

@Suite struct FileSourceTests {
    @Test func readsFileWithPread() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hexer-test-\(UUID().uuidString).bin")
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = EditableBuffer(source: try FileByteSource(url: url))
        let snap = buffer.snapshot()
        #expect(snap.length == 200_000)
        #expect(snap.bytes(65_530..<65_550) == [UInt8](data[65_530..<65_550]))
        let r = snap.read(131_070..<131_080)
        #expect(r.bytes == [UInt8](data[131_070..<131_080]))
        #expect(r.states.allSatisfy { $0 == .original })
    }
}

@Suite struct CharacterFilterTests {
    @Test func parsesAndMergesRanges() throws {
        let f = try #require(CharacterFilter(parsing: "61-7A, 41-5a 30-39; 7B"))
        #expect(f.ranges == [0x30...0x39, 0x41...0x5A, 0x61...0x7B])
        #expect(f.text == "30-39, 41-5A, 61-7B")
        #expect(f.allows(0x7B) && !f.allows(0x7C) && !f.allows(0x20))
        #expect(CharacterFilter(parsing: "7E-20") == nil)
        #expect(CharacterFilter(parsing: "zz") == nil)
        #expect(CharacterFilter([0...0x7F, 0x80...0xFF]).isAll)
    }
}

