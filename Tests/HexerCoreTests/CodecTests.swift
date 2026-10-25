import Foundation
import Testing
@testable import HexerCore

/// A snapshot of `runs` (data and undefined gaps from offset 0).
private func snapshot(_ runs: [ImportedImage.Run]) -> ByteSnapshot {
    ImportedImage(runs: runs).makeBuffer().snapshot()
}

private func snapshot(_ bytes: [UInt8]) -> ByteSnapshot {
    EditableBuffer(source: MemoryByteSource(bytes)).snapshot()
}

/// HxD writes CRLF; expectations are written with "\n".
private func crlf(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }

private func spaces(_ n: Int) -> String { String(repeating: " ", count: n) }

private func pattern(_ n: Int, seed: Int = 7) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) } }

/// The first 20 bytes of a DOS executable header.
private let mz: [UInt8] = [0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00,
                           0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xB8, 0x00, 0x00, 0x00]

private func importError(_ text: String, _ format: HexRecordFormat) -> HexImportError? {
    do {
        _ = try RecordImporter.importRecords(text, format: format, fileName: "a.hex")
        return nil
    } catch let error as HexImportError {
        return error
    } catch {
        return nil
    }
}

// MARK: - Import

@Suite struct IntelHexImportTests {
    @Test func knownGoodFile() throws {
        let text = """
        :10010000214601360121470136007EFE09D2190140
        :100110002146017E17C20001FF5F16002148011928
        :00000001FF
        """
        let image = try RecordImporter.importRecords(text, format: .intelHex)
        let data = Array("214601360121470136007EFE09D21901".hexBytes + "2146017E17C20001FF5F160021480119".hexBytes)
        #expect(image.runs == [.gap(0x100), .data(data)])
        #expect(image.length == 0x120)
    }

    @Test func extendedAddressesWhitespaceAndStartAddress() throws {
        // CRLF and CR line ends, blank lines, surrounding whitespace.
        let text = "  :020000040001F9 \r\n\r\n:02FFFE00AABB9C\r:0400000500001234B1\n:020000021000EC\n:01001000559A\n:00000001FF"
        let image = try RecordImporter.importRecords(text, format: .intelHex)
        // 0x0001_FFFE…0x0001_FFFF from the linear base; 0x10010 from segment 0x1000.
        #expect(image.runs == [.gap(0x10010), .data([0x55]), .gap(0x1FFFE - 0x10011), .data([0xAA, 0xBB])])
        #expect(image.startAddresses == [0x1234])
    }

    @Test func segmentAddressesWrapAt1MiB() throws {
        let text = ":02000002FFFFFE\n:0100200077" + "68" + "\n:00000001FF"
        let image = try RecordImporter.importRecords(text, format: .intelHex)
        // 0xFFFF0 + 0x20 wraps to 0x10.
        #expect(image.runs == [.gap(0x10), .data([0x77])])
    }

    @Test func checksumError() {
        let e = importError("  :0300300002337A1F", .intelHex)
        #expect(e?.kind == .checksum(expected: 0x1E, found: 0x1F))
        #expect(e?.line == 1)
        #expect(e?.column == 18)
        #expect(e?.errorDescription == "Parse error while importing \"a.hex\" in line 1, column 18:\nChecksum 1E expected, but found 1F.")
    }

    @Test func recordTypeError() {
        let e = importError(":00000006FA", .intelHex)
        #expect(e?.column == 8)
        #expect(e?.message == "Two hexadecimal digits in the range of 00-05 were expected, but found \"06\".")
    }

    @Test func structuralErrors() {
        #expect(importError(":00000001FF\n\n:00000001FF", .intelHex)?.line == 3)
        #expect(importError(":00000001FF\n:00000001FF", .intelHex)?.message == "No further lines permitted after EOF record.")
        #expect(importError("0300300002337A1E", .intelHex)?.message == "\":\" expected, but found \"0\".")
        let trailing = importError(":00000001FFZ", .intelHex)
        #expect(trailing?.message == "Expected end of line, but found \"Z\".")
        #expect(trailing?.column == 12)
        let short = importError(":0300300002", .intelHex)
        #expect(short?.kind == .hexDigits(min: 0, max: 0xFF, found: ""))
        #expect(short?.column == 12)
        #expect(importError(":0100000102FC", .intelHex)?.kind == .wrongDataLength(recordType: "01", expected: 0, found: 1))
        #expect(importError(":0X000001FF", .intelHex)?.kind == .hexDigits(min: 0, max: 0xFF, found: "0X"))
    }
}

@Suite struct SRecordImportTests {
    @Test func knownGoodFile() throws {
        let text = """
        S00F000068656C6C6F202020202000003C
        S11F00007C0802A6900100049421FFF07C6C1B787C8C23783C6000003863000026
        S11F001C4BFFFFE5398000007D83637880010014382100107C0803A64E800020E9
        S111003848656C6C6F20776F726C642E0A0042
        S5030003F9
        S9030000FC
        """
        let image = try RecordImporter.importRecords(text, format: .motorolaSRecord)
        #expect(image.runs.count == 1)
        #expect(image.length == 0x46)
        #expect(Array(image.dataBytes.suffix(14)) == Array("Hello world.\n\0".utf8))
        #expect(image.metadata == [.init(type: "S0", address: 0, bytes: Array("hello     \0\0".utf8))])
        #expect(image.startAddresses == [0])
    }

    @Test func errors() {
        #expect(importError("S4030000FC", .motorolaSRecord)?.message
                == "An S-record type was expected (S1, S2, S3, S5, S7, S8, S9) but found \"S4\".")
        #expect(importError("Q1", .motorolaSRecord)?.kind == .sRecordType(found: "Q1"))
        let count = importError("S1050000AABB95\nS5030002FA", .motorolaSRecord)
        #expect(count?.line == 2)
        #expect(count?.column == 1)
        #expect(count?.message == "2 data records (records of type S1, S2 or S3) were expected, but since the last S5-record or the beginning 1 data records were found.")
        let checksum = importError("S1050000AABB96", .motorolaSRecord)
        #expect(checksum?.kind == .checksum(expected: 0x95, found: 0x96))
        #expect(checksum?.column == 13)
        #expect(importError("S1020000FD", .motorolaSRecord)?.kind == .byteCountTooSmall(count: 2, minimum: 3))
    }

    @Test func countResetsAfterS5() throws {
        let text = "S1050000AABB95\nS5030001FB\nS1050002CCDD4F\nS5030001FB"
        let image = try RecordImporter.importRecords(text, format: .motorolaSRecord)
        #expect(image.runs == [.data([0xAA, 0xBB, 0xCC, 0xDD])])
    }
}

@Suite struct ETLImportTests {
    @Test func dataTextAndIgnoredRecords() throws {
        let text = "X000070000004844521A\nX70006000100ABCD80\nX90001FE\nX70007010000010203F1"
        let image = try RecordImporter.importRecords(text, format: .etlExtended)
        #expect(image.runs == [.gap(0x100), .data([0xAB, 0xCD]), .gap(0x10000 - 0x102), .data([1, 2, 3])])
        #expect(image.metadata == [.init(type: "X0", address: 0, bytes: Array("HDR".utf8))])
        #expect(importError("Y1", .etlExtended)?.message
                == "An ETL extended record type was expected (X0 to X9) but found \"Y1\".")
        #expect(importError("X70006000100ABCD81", .etlExtended)?.kind == .checksum(expected: 0x80, found: 0x81))
    }

    @Test func detection() {
        #expect(RecordImporter.detectFormat(Data("\n :00000001FF".utf8)) == .intelHex)
        #expect(RecordImporter.detectFormat(Data("S9030000FC".utf8)) == .motorolaSRecord)
        #expect(RecordImporter.detectFormat(Data("X90001FE".utf8)) == .etlExtended)
        #expect(RecordImporter.detectFormat(Data("hello".utf8)) == nil)
    }
}

@Suite struct ImportedImageTests {
    @Test func laterRecordsWinAndOrderDoesNotMatter() throws {
        // 0x10: 11 22 33 44, then 0x12: AA, then 0x08: 01 02 (before), then 0x0E..0x15 overlapping both ends.
        let text = """
        :040010001122334442
        :010012000AE3
        :020008000102F3
        :01001600FFEA
        :03000E00EEEEEE25
        :00000001FF
        """
        let image = try RecordImporter.importRecords(text, format: .intelHex)
        #expect(image.runs == [.gap(8), .data([1, 2]), .gap(4), .data([0xEE, 0xEE, 0xEE, 0x22, 0x0A, 0x44]), .gap(2), .data([0xFF])])
    }

    @Test func descendingRecords() throws {
        var builder = SparseImageBuilder()
        for i in stride(from: 99, through: 0, by: -1) {
            let chunk = [UInt8](repeating: UInt8(i), count: 4)
            chunk.withUnsafeBytes { builder.write($0, at: UInt64(i * 4)) }
        }
        let runs = builder.runs()
        #expect(runs == [.data((0..<400).map { UInt8($0 / 4) })])
    }

    @Test func bufferHasUndefinedGaps() {
        let image = ImportedImage(runs: [.gap(0x10), .data([1, 2, 3]), .gap(5), .data([9])])
        let buffer = image.makeBuffer()
        #expect(buffer.length == 0x19)
        #expect(buffer.tree.undefinedLength == 0x15)
        let r = buffer.snapshot().read(0x0F..<0x19)
        #expect(r.bytes == [0, 1, 2, 3, 0, 0, 0, 0, 0, 9])
        #expect(r.states.map { $0 == .undefined } == [true, false, false, false, true, true, true, true, true, false])
        #expect(ImportedImage(runs: []).makeBuffer().length == 0)
    }
}

private extension String {
    var hexBytes: [UInt8] {
        var out: [UInt8] = []
        var i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: 2)
            out.append(UInt8(self[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}

// MARK: - Record export

@Suite struct RecordExportTests {
    let data = (0..<0x24).map { UInt8($0) }
    let records = ":20000000000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1FF0\n:040020002021222356\n"

    func intel(_ s: ByteSnapshot, _ range: Range<UInt64>, _ v: IntelHexVariant, _ perLine: Int = 32) throws -> String {
        try ExportText.collect { try RecordExporter.exportIntelHex(s, range: range, variant: v,
                                                                   options: .init(bytesPerLine: perLine), to: $0) }
    }

    func srec(_ s: ByteSnapshot, _ range: Range<UInt64>, _ v: SRecordVariant, _ perLine: Int = 32) throws -> String {
        try ExportText.collect { try RecordExporter.exportSRecord(s, range: range, variant: v,
                                                                  options: .init(bytesPerLine: perLine), to: $0) }
    }

    @Test func intelHexGolden() throws {
        let s = snapshot(data)
        #expect(try intel(s, 0..<0x24, .bits16) == crlf(records + ":00000001FF\n"))
        #expect(try intel(s, 0..<0x24, .bits20) == crlf(":020000020000FC\n" + records + ":00000001FF\n"))
        #expect(try intel(s, 0..<0x24, .bits32) == crlf(":020000040000FA\n" + records + ":00000001FF\n"))
    }

    @Test func sRecordGolden() throws {
        let s = snapshot(data)
        #expect(try srec(s, 0..<0x24, .s19) == crlf("""
        S00600004844521B
        S1230000000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1FEC
        S10700202021222352
        S9030000FC

        """))
        let s28 = try srec(s, 0..<2, .s28).components(separatedBy: "\r\n")
        #expect(s28 == ["S00600004844521B", "S2060000000001F8", "S804000000FB", ""])
        let s37 = try srec(s, 0..<2, .s37).components(separatedBy: "\r\n")
        #expect(s37 == ["S00600004844521B", "S307000000000001F7", "S70500000000FA", ""])
    }

    @Test func recordsAlignToLineSize() throws {
        let lines = try intel(snapshot(data), 0x1E..<0x24, .bits16).components(separatedBy: "\r\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix(":02001E00"))
        #expect(lines[1].hasPrefix(":04002000"))
    }

    @Test func twentyBitSegmentsFollowHxD() throws {
        let s = snapshot([.gap(0x18000), .data([0xAA])])
        let lines = try intel(s, 0..<0x18001, .bits20).components(separatedBy: "\r\n")
        #expect(lines == [":020000020FFFEE", ":01801000AAC5", ":00000001FF", ""])
    }

    @Test func addressLimit() throws {
        let s = snapshot([.gap(0xFFFF), .data([1, 2])])
        #expect(throws: ExportError.addressRangeExceeded(format: "16 Bit Intel Hex", limit: 0x10000)) {
            try intel(s, 0..<s.length, .bits16)
        }
        #expect(throws: ExportError.self) { try srec(s, 0..<s.length, .s19) }
        // Only defined data counts.
        let tail = snapshot([.data([1, 2]), .gap(0x20000)])
        #expect(try intel(tail, 0..<tail.length, .bits16) == crlf(":020000000102FB\n:00000001FF\n"))
        #expect(ExportError.addressRangeExceeded(format: "16 Bit Intel Hex", limit: 0x10000).errorDescription
                == "The maximum supported file size (64 KiB) of the \"16 Bit Intel Hex\" file format was exceeded.\nChoose another format")
    }

    static let intelImages: [IntelHexVariant: [ImportedImage.Run]] = [
        .bits16: [.gap(5), .data(pattern(70)), .gap(300), .data(pattern(40, seed: 3))],
        .bits20: [.gap(5), .data(pattern(70)), .gap(0xFFF0 - 75 - 7), .data(pattern(600, seed: 1)), .gap(0x4_0000),
                  .data(pattern(33, seed: 9))],
        .bits32: [.gap(0x10), .data(pattern(50)), .gap(0xFFD0), .data(pattern(0x1_0020, seed: 5)), .gap(0x3000_0000),
                  .data(pattern(3))],
    ]

    @Test(arguments: IntelHexVariant.allCases, [1, 17, 32, 255])
    func intelHexRoundTrip(variant: IntelHexVariant, perLine: Int) throws {
        let runs = Self.intelImages[variant]!
        let s = snapshot(runs)
        let text = try intel(s, 0..<s.length, variant, perLine)
        #expect(try RecordImporter.importRecords(text, format: .intelHex).runs == runs)
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.count <= max(15, 11 + 2 * perLine) })
    }

    @Test(arguments: SRecordVariant.allCases, [1, 32, 250])
    func sRecordRoundTrip(variant: SRecordVariant, perLine: Int) throws {
        var runs: [ImportedImage.Run] = [.gap(3), .data(pattern(100)), .gap(1000), .data(pattern(77, seed: 2))]
        if variant != .s19 { runs += [.gap(0x2_0000), .data(pattern(300, seed: 4))] }
        let s = snapshot(runs)
        let text = try srec(s, 0..<s.length, variant, perLine)
        let image = try RecordImporter.importRecords(text, format: .motorolaSRecord)
        #expect(image.runs == runs)
        #expect(image.metadata.first?.bytes == Array("HDR".utf8))
    }

    @Test func cancellation() {
        let s = snapshot(pattern(1000))
        #expect(throws: CancellationError.self) {
            try RecordExporter.exportIntelHex(s, range: 0..<1000, variant: .bits16, isCancelled: { true }) { _ in }
        }
        var reported: [Double] = []
        _ = try? ExportText.collect {
            try RecordExporter.exportSRecord(s, range: 0..<1000, variant: .s19, progress: { reported.append($0) }, to: $0)
        }
        #expect(reported.last == 1)
    }
}

// MARK: - Source code export

@Suite struct SourceCodeExportTests {
    let options = SourceCodeOptions(sourceName: "test.bin", timestamp: "23.10.2026 12:00:00")
    let range: Range<UInt64> = 0..<20

    func export(_ language: SourceLanguage, _ options: SourceCodeOptions? = nil, _ s: ByteSnapshot? = nil) throws -> String {
        try ExportText.collect {
            try SourceCodeExporter.export(s ?? snapshot(mz), range: range, language: language,
                                          options: options ?? self.options, to: $0)
        }
    }

    let header = "test.bin (23.10.2026 12:00:00)"
    let offsets = "StartOffset(h): 00000000, EndOffset(h): 00000013, Length(h): 00000014"

    @Test func c() throws {
        #expect(try export(.c) == crlf("""
        /* \(header)
           \(offsets) */

        unsigned char rawData[20] = {
        \t0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        \t0xFF, 0xFF, 0x00, 0x00, 0xB8, 0x00, 0x00, 0x00
        };

        """))
    }

    @Test func pascal() throws {
        #expect(try export(.pascal) == crlf("""
        { \(header)
          \(offsets) }

        RawData: array[0..19] of Byte = (
          $4D, $5A, $90, $00, $03, $00, $00, $00, $04, $00, $00, $00, $FF, $FF, $00,
          $00, $B8, $00, $00, $00
        );

        """))
    }

    @Test func cSharp() throws {
        #expect(try export(.cSharp) == crlf("""
        /* \(header)
           \(offsets) */

        byte[] rawData = {
        \t0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        \t0xFF, 0xFF, 0x00, 0x00, 0xB8, 0x00, 0x00, 0x00
        };

        """))
    }

    @Test func java() throws {
        #expect(try export(.java) == crlf("""
        /* \(header)
           \(offsets) */

        byte rawData[] = {
        \t(byte)0x4D, (byte)0x5A, (byte)0x90, (byte)0x00, (byte)0x03, (byte)0x00,
        \t(byte)0x00, (byte)0x00, (byte)0x04, (byte)0x00, (byte)0x00, (byte)0x00,
        \t(byte)0xFF, (byte)0xFF, (byte)0x00, (byte)0x00, (byte)0xB8, (byte)0x00,
        \t(byte)0x00, (byte)0x00
        };

        """))
    }

    @Test func visualBasic() throws {
        #expect(try export(.visualBasic) == crlf("""
        ' \(header)
        ' \(offsets)

        Dim rawData As Byte() = { _
        \t&H4D, &H5A, &H90, &H00, &H03, &H00, &H00, &H00, &H04, &H00, &H00, &H00, _
        \t&HFF, &HFF, &H00, &H00, &HB8, &H00, &H00, &H00 _
        }

        """))
    }

    @Test func pureBasic() throws {
        #expect(try export(.pureBasic) == crlf("""
        ; \(header)
        ; \(offsets)

        #RawDataItemCount = 20

        DataSection
          DS_RawData:
          Data.b $4D, $5A, $90, $00, $03, $00, $00, $00, $04, $00, $00, $00, $FF, $FF
          Data.b $00, $00, $B8, $00, $00, $00
        EndDataSection

        Structure RawDataArray
          Items.b[#RawDataItemCount]
        EndStructure

        Define *rawData.RawDataArray = ?DS_RawData

        """))
    }

    @Test func valuesPerLineMatchesHxDDefaults() {
        let counts = SourceLanguage.allCases.map { SourceCodeExporter.valuesPerLine($0, wrap: .charactersPerLine(80)) }
        #expect(counts == [15, 12, 12, 6, 12, 14])
        #expect(SourceCodeExporter.valuesPerLine(.c, wrap: .bytesPerLine(16)) == 16)
        #expect(SourceCodeExporter.valuesPerLine(.java, wrap: .charactersPerLine(10)) == 1)
    }

    @Test func bytesPerLineWithoutNameAndUndefinedAsZero() throws {
        let s = snapshot([.data([1, 2, 3]), .gap(2), .data([4])])
        let opts = SourceCodeOptions(lineWrap: .bytesPerLine(4), lineBreak: "\n")
        let text = try ExportText.collect {
            try SourceCodeExporter.export(s, range: 1..<6, language: .c, options: opts, to: $0)
        }
        #expect(text == """
        /* StartOffset(h): 00000001, EndOffset(h): 00000005, Length(h): 00000005 */

        unsigned char rawData[5] = {
        \t0x02, 0x03, 0x00, 0x00,
        \t0x04
        };

        """)
        #expect(ExportText.containsUndefined(s, in: 1..<6))
        #expect(!ExportText.containsUndefined(s, in: 0..<3))
        #expect(try ExportText.collect { try SourceCodeExporter.export(s, range: 2..<2, language: .c, to: $0) } == "")
    }
}

// MARK: - Formatted export

@Suite struct FormattedExportTests {
    func export(_ s: ByteSnapshot, _ range: Range<UInt64>, _ format: FormattedFormat, layout: ExportLayout = .init(),
                title: String = "test.bin") throws -> String {
        try ExportText.collect {
            try FormattedExporter.export(s, range: range, format: format, layout: layout, title: title, to: $0)
        }
    }

    let headerRow = "Offset(h) 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F"

    @Test func editorView() throws {
        let text = try export(snapshot(mz), 0..<20, .editorView)
        #expect(text == crlf("""
        \(headerRow)

        00000000  4D 5A 90 00 03 00 00 00 04 00 00 00 FF FF 00 00  MZ..........ÿÿ..
        00000010  B8 00 00 00\(spaces(36))  ¸...

        """))
    }

    @Test func partialRowsGroupsAndBases() throws {
        let s = snapshot((0..<0x20).map { UInt8($0) })
        let partial = try export(s, 0x13..<0x15, .editorView).components(separatedBy: "\r\n")
        #expect(partial[2] == "00000010  \(spaces(9))13 14\(spaces(33))     ..")

        let grouped = try export(snapshot(mz), 0..<16, .editorView, layout: ExportLayout(groupSize: 4)).components(separatedBy: "\r\n")
        #expect(grouped[0] == "Offset(h) 00       04       08       0C")
        #expect(grouped[2] == "00000000  4D5A9000 03000000 04000000 FFFF0000  MZ..........ÿÿ..")

        let decimal = try export(snapshot(mz), 0..<4, .editorView,
                                 layout: ExportLayout(bytesPerRow: 8, offsetBase: .decimal, uppercase: false)).components(separatedBy: "\r\n")
        #expect(decimal[0] == "Offset(d) 00 01 02 03 04 05 06 07")
        #expect(decimal[2] == "00000000  4d 5a 90 00\(spaces(12))  MZ..")

        let hexOnly = try export(snapshot(mz), 0..<4, .editorView, layout: ExportLayout(columns: .hex)).components(separatedBy: "\r\n")
        #expect(hexOnly[2] == "00000000  4D 5A 90 00")
        let textOnly = try export(snapshot(mz), 0..<4, .editorView, layout: ExportLayout(columns: .text)).components(separatedBy: "\r\n")
        #expect(textOnly[0] == "Offset(h)")
        #expect(textOnly[2] == "00000000  MZ..")
    }

    @Test func foldedRowsBecomeOneLine() throws {
        // Rows 1–2 of 4 fold (as the editor folds undefined sections); a fold outside the range is ignored.
        let s = snapshot((0..<0x40).map { UInt8($0) })
        let text = try ExportText.collect {
            try FormattedExporter.export(s, range: 0..<0x38, format: .editorView, folds: [0x10..<0x30, 0x40..<0x60],
                                         foldLine: { "\($0.upperBound - $0.lowerBound) bytes hidden" }, to: $0)
        }
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[2].hasPrefix("00000000  00 01 02"))
        #expect(lines[3] == "00000010  32 bytes hidden")
        #expect(lines[4].hasPrefix("00000030  30 31 32 33 34 35 36 37" + spaces(24)))
        #expect(lines.count == 6)
        // A range starting inside a fold shows only the hidden part it covers.
        let partial = try ExportText.collect {
            try FormattedExporter.export(s, range: 0x18..<0x34, format: .editorView, folds: [0x10..<0x30],
                                         foldLine: { "\($0.upperBound - $0.lowerBound) bytes hidden" }, to: $0)
        }.components(separatedBy: "\r\n")
        #expect(partial[2] == "00000018  24 bytes hidden")
        #expect(partial[3].hasPrefix("00000030  30 31 32 33"))
    }

    @Test func undefinedBytes() throws {
        let s = snapshot([.data([0x41]), .gap(2), .data([0x42])])
        let lines = try export(s, 0..<4, .editorView).components(separatedBy: "\r\n")
        #expect(lines[2] == "00000000  41 ?? ?? 42\(spaces(36))  A??B")
    }

    @Test func html() throws {
        let bytes = Array("<&>\"AB".utf8)
        let html = try export(snapshot(bytes), 0..<6, .html, title: "a & b")
        #expect(html.hasPrefix("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\""))
        #expect(html.contains("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">"))
        #expect(html.contains("<title>a &amp; b</title>"))
        #expect(html.contains("  body { background-color:#FFFFFF }\r\n  .offsetheader { color:#0000BF; line-height:200% }"))
        #expect(html.contains("<h1>a &amp; b</h1>\r\n<pre>\r\n<span class=\"offsetheader\">\(headerRow)</span>\r\n"))
        #expect(html.contains("<span class=\"offsetcol\">00000000</span>  <span class=\"hexcol\">3C 26 3E 22 41 42"))
        #expect(html.contains("<span class=\"textcol\">&lt;&amp;&gt;&quot;AB</span>\r\n</pre>\r\n<p class=\"generatorinfo\">"))
        #expect(html.hasSuffix("</p>\r\n</body>\r\n</html>\r\n"))
        #expect(!html.contains("Fragment"))
    }

    @Test func htmlClipboardOffsets() throws {
        let html = try FormattedExporter.htmlClipboard(snapshot(mz), range: 0..<20, title: "é")
        let bytes = Array(html.utf8)
        func field(_ name: String) -> Int {
            let line = html.components(separatedBy: "\r\n").first { $0.hasPrefix(name + ":") }!
            return Int(line.dropFirst(name.count + 1))!
        }
        func at(_ i: Int, _ prefix: String) -> Bool { bytes[i...].starts(with: Array(prefix.utf8)) }
        #expect(html.hasPrefix("Version:0.9\r\nStartHTML:0000000105\r\n"))
        #expect(at(field("StartHTML"), "<!DOCTYPE"))
        #expect(at(field("StartFragment"), "<h1>é</h1>"))
        #expect(at(field("EndFragment"), "<!--EndFragment--></body>"))
        #expect(field("EndHTML") == bytes.count)
        #expect(at(field("StartFragment") - 20, "<!--StartFragment-->"))
    }

    @Test func rtf() throws {
        let rtf = try export(snapshot([0x5C, 0x7B, 0x7D, 0xE9]), 0..<4, .rtf, title: "x{y}")
        #expect(rtf.hasPrefix("{\\rtf1\\ansi\\ansicpg-535\\uc1\\deff0\\deftab720{\\fonttbl{\\f0\\fmodern Courier New;}}\r\n"))
        #expect(rtf.contains("{\\colortbl\\red255\\green255\\blue255;\\red0\\green0\\blue0;\\red0\\green0\\blue191;}\r\n"))
        #expect(rtf.contains("{\\info{\\author HxD}\r\n{\\doccomm https://mh-nexus.de/hxd/}\r\n{\\title x\\{y\\}}}\r\n"))
        #expect(rtf.contains("\\deflang1031\\pard\\plain\\f0\\fs20 \\cb0 \r\n\\cf2 \\sa100 \(headerRow)\\par\\pard\r\n"))
        #expect(rtf.contains("\\cf2 00000000  \\cf1 5C 7B 7D E9"))
        #expect(rtf.contains("  \\cf1 \\\\\\{\\}\\u233?\r\n\\par }"))
        #expect(rtf.hasSuffix("\r\n\\par }"))
    }

    @Test func tex() throws {
        let tex = try export(snapshot(Array("%$_#&~^ a".utf8)), 0..<9, .tex, title: "my_file")
        #expect(tex.hasPrefix("% Generated by HxD https://mh-nexus.de/hxd/\r\n\r\n\\documentclass[a4paper, 10pt]{article}\r\n\\usepackage[a4paper, margin=2cm]{geometry}"))
        #expect(tex.contains("\\usepackage[ansinew]{inputenc}\r\n%% Special Characters\r\n\\newcommand\\SPC{\\hspace*{0.6em}}"))
        #expect(tex.contains("\\DeclareInputText{172}{\\textlnot}\r\n\r\n\\title{my\\_file}\r\n\\begin{document}\r\n\\begin{ttfamily}\r\n\\noindent\r\n"))
        #expect(tex.contains("\\textcolor[rgb]{0,0,0.75}{Offset(h)\\SPC 00\\SPC 01\\SPC 02"))
        #expect(tex.contains("\\SPC 0F\\vspace*{0.5em}}\\\\\r\n\\textcolor[rgb]{0,0,0.75}{00000000}\\SPC \\SPC \\textcolor[rgb]{0,0,0}{25\\SPC 24"))
        #expect(tex.contains("\\textcolor[rgb]{0,0,0}{\\%\\$\\_\\#\\&\\TLD \\CIR \\SPC a}\\\\\r\n"))
        #expect(tex.hasSuffix("\\\\\r\n\r\n\\end{ttfamily}\r\n\\end{document}"))
    }
}

// MARK: - Plain export

@Suite struct PlainExportTests {
    @Test func hexValues() throws {
        let s = snapshot([.data([0x4D, 0x5A, 0x90]), .gap(1), .data([0xab])])
        #expect(try ExportText.collect { try PlainExporter.exportHexValues(s, range: 0..<5, to: $0) } == "4D 5A 90 ?? AB")
        let lines = try ExportText.collect {
            try PlainExporter.exportHexValues(s, range: 0..<5, options: .init(separator: "", bytesPerLine: 2, uppercase: false), to: $0)
        }
        #expect(lines == "4d5a\r\n90??\r\nab")
    }

    @Test func decodedText() throws {
        let s = snapshot([.data(Array("Hi\u{1}".utf8) + [0x80]), .gap(1)])
        #expect(try ExportText.collect { try PlainExporter.exportDecodedText(s, range: 0..<5, encoding: .windowsLatin1, to: $0) } == "Hi\u{1}€?")
        #expect(try ExportText.collect { try PlainExporter.exportDecodedText(s, range: 0..<4, encoding: .windowsLatin1, filtered: true, to: $0) } == "Hi.€")
    }

    @Test func largeExportStreamsInChunks() throws {
        let s = snapshot(pattern(300_000))
        var chunks = 0
        var total = 0
        try PlainExporter.exportHexValues(s, range: 0..<300_000) { chunks += 1; total += $0.utf8.count }
        #expect(chunks > 5)
        #expect(total == 300_000 * 3 - 1)
    }
}

@Suite struct IntelHexSegmentTests {
    @Test func segmentRecordsWrapWithinTheSegment() throws {
        let text = ":020000021000EC\r\n:04FFFE00AABBCCDDF1\r\n:00000001FF\r\n"
        let image = try RecordImporter.importRecords(text, format: .intelHex)
        let bytes = image.makeBuffer().snapshot()
        #expect(bytes.length == 0x2_0000)
        #expect(bytes.bytes(0x1_FFFE..<0x2_0000) == [0xAA, 0xBB])
        #expect(bytes.bytes(0x1_0000..<0x1_0002) == [0xCC, 0xDD])
    }
}

