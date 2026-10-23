import Foundation
import Testing
@testable import HexerCore

private let check = Array("123456789".utf8)

private func snapshot(_ bytes: [UInt8]) -> ByteSnapshot {
    EditableBuffer(source: MemoryByteSource(bytes)).snapshot()
}

private func randomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
    var rng = SeededRandom(state: seed)
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
}

private func hex(_ algorithm: ChecksumAlgorithm, _ data: [UInt8]) -> String {
    algorithm.checksum(of: data).hexString
}

private func value(_ result: ChecksumResult) -> UInt64 {
    result.bytes.reduce(0) { $0 << 8 | UInt64($1) }
}

@Suite struct ChecksumTests {
    @Test func standardListAndNames() {
        #expect(ChecksumAlgorithm.standard.map(\.displayName) == [
            "Checksum-8", "Checksum-16", "Checksum-32", "Checksum-64", "CRC-16", "CRC-16/CCITT-FALSE", "CRC-32",
            "CRC-32C", "MD2", "MD4", "MD5", "SHA-1", "SHA-256", "SHA-384", "SHA-512",
        ])
        #expect(ChecksumAlgorithm.customChecksum(CustomChecksumParameters(resultWidth: 16)).displayName == "Custom checksum")
        #expect(ChecksumAlgorithm.customCRC(.crc8).displayName == "Custom CRC (8-bit)")
    }

    @Test func crcCheckValues() {
        #expect(hex(.crc16, check) == "BB3D")
        #expect(hex(.crc16CCITTFalse, check) == "29B1")
        #expect(hex(.crc32, check) == "CBF43926")
        #expect(hex(.crc32C, check) == "E3069283")
        #expect(ChecksumAlgorithm.crc32.checksum(of: check).bytes == [0xCB, 0xF4, 0x39, 0x26])
        #expect(hex(.crc32, []) == "00000000")
    }

    @Test func sumChecksums() {
        // 0x31 + 0x32 + ... + 0x39 = 0x1DD
        #expect(hex(.checksum8, check) == "DD")
        #expect(hex(.checksum16, check) == "01DD")
        #expect(hex(.checksum32, check) == "000001DD")
        #expect(hex(.checksum64, check) == "00000000000001DD")
        #expect(hex(.checksum8, [0xFF, 0xFF, 0x03]) == "01")
    }

    @Test func customCRC() {
        #expect(hex(.customCRC(CRCParameters(width: 32, polynomial: 0x04C1_1DB7, initialValue: 0xFFFF_FFFF,
                                             finalXOR: 0xFFFF_FFFF, reflectInput: true, reflectOutput: true)), check) == "CBF43926")
        #expect(hex(.customCRC(CRCParameters(width: 8, polynomial: 0x07)), check) == "F4")
    }

    /// Entries of the CRC catalogue (reveng.sourceforge.io) covering odd widths and refin != refout.
    @Test func catalogueCRCs() {
        let catalogue: [(String, CRCParameters, UInt64, String)] = [
            ("CRC-3/GSM", CRCParameters(width: 3, polynomial: 0x3, finalXOR: 0x7), 0x4, "4"),
            ("CRC-4/G-704", CRCParameters(width: 4, polynomial: 0x3, reflectInput: true, reflectOutput: true), 0x7, "7"),
            ("CRC-5/USB", CRCParameters(width: 5, polynomial: 0x05, initialValue: 0x1F, finalXOR: 0x1F,
                                        reflectInput: true, reflectOutput: true), 0x19, "19"),
            ("CRC-7/MMC", CRCParameters(width: 7, polynomial: 0x09), 0x75, "75"),
            ("CRC-12/UMTS", CRCParameters(width: 12, polynomial: 0x80F, reflectOutput: true), 0xDAF, "DAF"),
            ("CRC-16/KERMIT", CRCParameters(width: 16, polynomial: 0x1021, reflectInput: true, reflectOutput: true), 0x2189, "2189"),
            ("CRC-24/OPENPGP", CRCParameters(width: 24, polynomial: 0x86_4CFB, initialValue: 0xB7_04CE), 0x21_CF02, "21CF02"),
            ("CRC-64/ECMA-182", CRCParameters(width: 64, polynomial: 0x42F0_E1EB_A9EA_3693), 0x6C40_DF5F_0B49_7347,
             "6C40DF5F0B497347"),
            ("CRC-64/XZ", CRCParameters(width: 64, polynomial: 0x42F0_E1EB_A9EA_3693, initialValue: .max, finalXOR: .max,
                                        reflectInput: true, reflectOutput: true), 0x995D_C9BB_DF19_39FA, "995DC9BBDF1939FA"),
        ]
        for (name, p, expected, hexString) in catalogue {
            let r = ChecksumAlgorithm.customCRC(p).checksum(of: check)
            #expect(value(r) == expected, "\(name)")
            #expect(r.hexString == hexString, "\(name)")
        }
    }

    /// Bit-at-a-time Rocksoft CRC, straight from the model's definition.
    func referenceCRC(_ p: CRCParameters, _ data: [UInt8]) -> UInt64 {
        func reflect(_ v: UInt64, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 << 1 | v >> UInt64($1) & 1 } }
        let w = p.width, mask = UInt64.max >> (64 - w), top = UInt64(1) << (w - 1)
        var reg = p.initialValue & mask
        for byte in data {
            let b = p.reflectInput ? reflect(UInt64(byte), 8) : UInt64(byte)
            for k in (0..<8).reversed() {
                let feedback = (reg & top != 0) != (b >> UInt64(k) & 1 != 0)
                reg = reg << 1 & mask
                if feedback { reg ^= p.polynomial & mask }
            }
        }
        if p.reflectOutput { reg = reflect(reg, w) }
        return reg ^ p.finalXOR & mask
    }

    @Test func tableCRCMatchesBitwiseReference() {
        var rng = SeededRandom(state: 42)
        for _ in 0..<300 {
            let p = CRCParameters(width: Int.random(in: 1...64, using: &rng), polynomial: rng.next(),
                                  initialValue: rng.next(), finalXOR: rng.next(),
                                  reflectInput: Bool.random(using: &rng), reflectOutput: Bool.random(using: &rng))
            let data = (0..<Int.random(in: 0...40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            #expect(value(ChecksumAlgorithm.customCRC(p).checksum(of: data)) == referenceCRC(p, data), "\(p)")
        }
    }

    @Test func customChecksum() {
        func sum(_ result: Int, _ addend: Int, _ order: CustomChecksumParameters.ByteOrder, _ data: [UInt8]) -> String {
            hex(.customChecksum(CustomChecksumParameters(resultWidth: result, addendWidth: addend, byteOrder: order)), data)
        }
        // "12" "34" "56" "78" "9" as 16-bit addends; the trailing "9" is zero-padded.
        #expect(sum(16, 16, .littleEndian, check) == "D509") // 3231+3433+3635+3837+0039
        #expect(sum(16, 16, .bigEndian, check) == "09D4") // 3132+3334+3536+3738+3900 = 109D4
        #expect(sum(32, 16, .bigEndian, check) == "000109D4")
        #expect(sum(32, 32, .littleEndian, [1, 0, 0, 0, 2, 0, 0, 0, 3]) == "00000006")
        #expect(sum(32, 32, .bigEndian, [0, 0, 0, 1, 0, 0, 0, 2, 3]) == "03000003")
        #expect(sum(8, 64, .bigEndian, [0, 0, 0, 0, 0, 0, 1, 0xFF]) == "FF")
        #expect(sum(64, 64, .littleEndian, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 2]) == "0000000000000001")
        // Checksum-N is the 8-bit-addend special case.
        #expect(sum(16, 8, .bigEndian, check) == hex(.checksum16, check))
    }

    static let md2Vectors: [(String, String)] = [
        ("", "8350E5A3E24C153DF2275C9F80692773"),
        ("a", "32EC01EC4A6DAC72C0AB96FB34C0B5D1"),
        ("abc", "DA853B0D3F88D99B30283A69E6DED6BB"),
        ("message digest", "AB4F496BFB2A530B219FF33031FE06B0"),
        ("abcdefghijklmnopqrstuvwxyz", "4E8DDFF3650292AB5A4108C3AA47940B"),
        ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "DA33DEF2A42DF13975352846C30338CD"),
        (String(repeating: "1234567890", count: 8), "D5976F79D83D3A0DC9806C3C66F3EFD8"),
    ]

    static let md4Vectors: [(String, String)] = [
        ("", "31D6CFE0D16AE931B73C59D7E0C089C0"),
        ("a", "BDE52CB31DE33E46245E05FBDBD6FB24"),
        ("abc", "A448017AAF21D8525FC10AE87AA6729D"),
        ("message digest", "D9130A8164549FE818874806E1C7014B"),
        ("abcdefghijklmnopqrstuvwxyz", "D79E1C308AA5BBCDEEA8ED63DF412DA9"),
        ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "043F8582F241DB351CE627E153E7F0E4"),
        (String(repeating: "1234567890", count: 8), "E33B4DDC9C38F2199C3E7B164FCC0536"),
    ]

    @Test func md2RFC1319() {
        #expect(Set(MD2Hasher.piSubst).count == 256)
        for (input, digest) in Self.md2Vectors { #expect(hex(.md2, Array(input.utf8)) == digest, "\(input)") }
    }

    @Test func md4RFC1320() {
        for (input, digest) in Self.md4Vectors { #expect(hex(.md4, Array(input.utf8)) == digest, "\(input)") }
    }

    @Test func cryptoKitDigests() {
        let abc = Array("abc".utf8)
        #expect(hex(.md5, abc) == "900150983CD24FB0D6963F7D28E17F72")
        #expect(hex(.sha1, abc) == "A9993E364706816ABA3E25717850C26C9CD0D89D")
        #expect(hex(.sha256, abc) == "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        #expect(hex(.sha384, abc) == "CB00753F45A35E8BB5A03D699AC65007272C32AB0EDED1631A8B605A43FF5BED8086072BA1E7CC2358BAECA134C825A7")
        #expect(hex(.sha512, abc) == "DDAF35A193617ABACC417349AE20413112E6FA4E89A97EA20A9EEEE64B55D39A2192992A274FC1A836BA3C23A3FEEBBD454D4423643CE80E2A9AC94FA54CA49F")
    }

    static let everything: [ChecksumAlgorithm] = ChecksumAlgorithm.standard + [
        .customChecksum(CustomChecksumParameters(resultWidth: 32, addendWidth: 32, byteOrder: .littleEndian)),
        .customChecksum(CustomChecksumParameters(resultWidth: 64, addendWidth: 64, byteOrder: .bigEndian)),
        .customChecksum(CustomChecksumParameters(resultWidth: 16, addendWidth: 16, byteOrder: .bigEndian)),
        .customCRC(.crc8),
        .customCRC(CRCParameters(width: 24, polynomial: 0x86_4CFB, initialValue: 0xB7_04CE)),
        .customCRC(CRCParameters(width: 5, polynomial: 0x05, initialValue: 0x1F, finalXOR: 0x1F, reflectInput: true, reflectOutput: true)),
    ]

    /// Data split over many chunks (of a multi-piece snapshot) hashes like the bytes in one go.
    @Test(arguments: [7, 4093, 4 << 20])
    func multiChunkMatchesOneShot(chunkSize: Int) throws {
        let original = randomBytes(40_000, seed: 7)
        let buffer = EditableBuffer(source: MemoryByteSource(original))
        try buffer.insert([1, 2, 3, 4, 5], at: 1000, selectionBefore: Selection(caret: 1000))
        try buffer.overwrite(Array(repeating: 0xAA, count: 777), at: 20_000, selectionBefore: Selection(caret: 20_000))
        let model = buffer.snapshot().bytes(0..<buffer.length)
        let range: Range<UInt64> = 3..<buffer.length - 5
        let data = chunkSize == 7 ? Array(model[3..<1003]) : Array(model[3..<model.count - 5])
        let r: Range<UInt64> = chunkSize == 7 ? 3..<1003 : range
        let results = try #require(ChecksumCalculator.compute(Self.everything, snapshot: buffer.snapshot(), range: r,
                                                               chunkSize: chunkSize))
        #expect(results.map(\.algorithm) == Self.everything)
        for result in results {
            #expect(result == result.algorithm.checksum(of: data), "\(result.algorithm)")
        }
    }

    @Test func rangeIsClampedAndProgressReported() throws {
        var reported: [Double] = []
        let results = try #require(ChecksumCalculator.compute([.crc32], snapshot: snapshot(check), range: 0..<100,
                                                               chunkSize: 2, progress: { reported.append($0) }))
        #expect(results[0].hexString == "CBF43926")
        #expect(reported.first == 0 && reported.last == 1)
        #expect(reported == reported.sorted())
    }

    @Test func cancellation() {
        var calls = 0
        let result = ChecksumCalculator.compute([.md5, .crc32], snapshot: snapshot(randomBytes(1000, seed: 1)), range: 0..<1000,
                                                chunkSize: 100, isCancelled: { calls += 1; return calls > 3 })
        #expect(result == nil)
    }

    @Test func expectedValueComparison() {
        let crc = ChecksumAlgorithm.crc32.checksum(of: check)
        #expect(crc.matches("CBF43926"))
        #expect(crc.matches("cbf43926"))
        #expect(crc.matches(" 0xCB F4 39 26\n"))
        #expect(!crc.matches("CBF43927"))
        #expect(!crc.matches("CBF4392G"))
        #expect(!crc.matches(""))
        let small = ChecksumAlgorithm.checksum16.checksum(of: [1])
        #expect(small.hexString == "0001")
        #expect(small.matches("1") && small.matches("0x0001") && small.matches("00000001"))
        #expect(ChecksumResult.normalizedHex(" 0Xab cd ") == "ABCD")
        #expect(ChecksumResult.normalizedHex("AB-CD") == nil)
    }

    @Test func algorithmsAreCodable() throws {
        let data = try JSONEncoder().encode(Self.everything)
        #expect(try JSONDecoder().decode([ChecksumAlgorithm].self, from: data) == Self.everything)
    }
}

@Suite struct ByteStatisticsTests {
    @Test func histogramMatchesNaiveCount() throws {
        let data = randomBytes(10_003, seed: 3)
        var naive = [UInt64](repeating: 0, count: 256)
        for b in data { naive[Int(b)] += 1 }
        #expect(ByteStatistics.histogram(of: data) == naive)
        let h = try #require(ByteStatistics.histogram(snapshot: snapshot(data), range: 0..<20_000, chunkSize: 13))
        #expect(h == naive)
        #expect(ByteStatistics.total(h) == 10_003)
        let sub = try #require(ByteStatistics.histogram(snapshot: snapshot(data), range: 100..<200))
        #expect(sub == ByteStatistics.histogram(of: Array(data[100..<200])))
    }

    @Test func helpers() {
        let uniform = ByteStatistics.histogram(of: (0..<1024).map { UInt8(truncatingIfNeeded: $0) })
        #expect(abs(ByteStatistics.entropy(uniform) - 8) < 1e-9)
        #expect(ByteStatistics.mostFrequent(uniform)! == (0, 4))
        let constant = ByteStatistics.histogram(of: [7, 7, 7])
        #expect(ByteStatistics.entropy(constant) == 0)
        #expect(ByteStatistics.mostFrequent(constant)! == (7, 3))
        #expect(ByteStatistics.entropy(ByteStatistics.histogram(of: [1, 2, 1, 2])) == 1)
        #expect(ByteStatistics.mostFrequent(ByteStatistics.histogram(of: [9, 3, 9, 3, 5]))! == (3, 2))
        let empty = ByteStatistics.histogram(of: [])
        #expect(ByteStatistics.mostFrequent(empty) == nil)
        #expect(ByteStatistics.entropy(empty) == 0)
    }

    @Test func undefinedBytesAreNotCounted() throws {
        let buffer = EditableBuffer(source: MemoryByteSource([1, 2, 3, 4, 5, 6]))
        try buffer.apply("Gap", replacing: 4..<4, with: [Piece.undefined(length: 2)],
                         selectionBefore: Selection(caret: 4), selectionAfter: Selection(caret: 4))
        let s = buffer.snapshot()
        #expect(s.undefinedByteCount(in: 0..<8) == 2)
        #expect(s.undefinedByteCount(in: 5..<8) == 1)
        let h = try #require(ByteStatistics.histogram(snapshot: s, range: 0..<8))
        #expect(ByteStatistics.total(h) == 6)
        #expect(h[0] == 0)
    }

    @Test func cancellation() {
        #expect(ByteStatistics.histogram(snapshot: snapshot([1, 2, 3]), range: 0..<3, isCancelled: { true }) == nil)
    }
}

@Suite struct CompareEngineTests {
    /// Maximal runs of differing offsets, the slow way.
    func naiveRuns(_ x: [UInt8], _ y: [UInt8]) -> [Range<UInt64>] {
        var runs: [Range<UInt64>] = []
        var start: Int?
        for i in 0..<max(x.count, y.count) {
            if i >= x.count || i >= y.count || x[i] != y[i] {
                if start == nil { start = i }
            } else if let s = start {
                runs.append(UInt64(s)..<UInt64(i))
                start = nil
            }
        }
        if let s = start { runs.append(UInt64(s)..<UInt64(max(x.count, y.count))) }
        return runs
    }

    @Test func identical() {
        let a = snapshot(check), b = snapshot(check)
        #expect(CompareEngine.nextDifference(a, b, from: 0) == nil)
        #expect(CompareEngine.previousDifference(a, b, before: 9) == nil)
        #expect(CompareEngine.differingOffsets(in: 0..<9, a, b).isEmpty)
    }

    @Test func runsForwardAndBackward() {
        let a = snapshot([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let b = snapshot([0, 1, 0, 0, 4, 5, 6, 0, 8, 9])
        #expect(CompareEngine.nextDifference(a, b, from: 0) == 2..<4)
        #expect(CompareEngine.nextDifference(a, b, from: 3) == 3..<4)
        #expect(CompareEngine.nextDifference(a, b, from: 4) == 7..<8)
        #expect(CompareEngine.nextDifference(a, b, from: 8) == nil)
        #expect(CompareEngine.previousDifference(a, b, before: 10) == 7..<8)
        #expect(CompareEngine.previousDifference(a, b, before: 7) == 2..<4)
        #expect(CompareEngine.previousDifference(a, b, before: 3) == 2..<3)
        #expect(CompareEngine.previousDifference(a, b, before: 2) == nil)
        #expect(CompareEngine.differingOffsets(in: 0..<10, a, b) == [2..<4, 7..<8])
        #expect(CompareEngine.differingOffsets(in: 3..<8, a, b) == [3..<4, 7..<8])
    }

    @Test func lengthMismatch() {
        let a = snapshot([0, 1, 2, 3])
        let b = snapshot([0, 1, 2, 3, 4, 5])
        #expect(CompareEngine.nextDifference(a, b, from: 0) == 4..<6)
        #expect(CompareEngine.nextDifference(b, a, from: 5) == 5..<6)
        #expect(CompareEngine.nextDifference(a, b, from: 6) == nil)
        #expect(CompareEngine.previousDifference(a, b, before: 100) == 4..<6)
        #expect(CompareEngine.previousDifference(a, b, before: 5) == 4..<5)
        #expect(CompareEngine.previousDifference(a, b, before: 4) == nil)
        #expect(CompareEngine.differingOffsets(in: 0..<100, a, b) == [4..<6])
        // A difference touching the end of the shorter one joins the extra bytes.
        let c = snapshot([0, 1, 9, 9, 4, 5, 6])
        #expect(CompareEngine.nextDifference(a, c, from: 0) == 2..<7)
        #expect(CompareEngine.previousDifference(a, c, before: 7) == 2..<7)
        #expect(CompareEngine.nextDifference(snapshot([]), a, from: 0) == 0..<4)
    }

    @Test(arguments: [1, 2, 3])
    func randomRunsMatchNaive(seed: UInt64) {
        var rng = SeededRandom(state: seed)
        let x = randomBytes(30_000, seed: seed)
        var y = x
        for _ in 0..<40 {
            let at = Int.random(in: 0..<y.count, using: &rng)
            for i in at..<min(y.count, at + Int.random(in: 1...70, using: &rng)) { y[i] = y[i] &+ 1 }
        }
        y += [1, 2, 3].prefix(Int(seed) - 1)
        let expected = naiveRuns(x, y)
        let a = snapshot(x), b = snapshot(y)
        let chunk = [64, 100, 4096][Int(seed) - 1]

        var forward: [Range<UInt64>] = []
        var offset: UInt64 = 0
        while let run = CompareEngine.nextDifference(a, b, from: offset, chunkSize: chunk) {
            forward.append(run)
            offset = run.upperBound
        }
        #expect(forward == expected)

        var backward: [Range<UInt64>] = []
        offset = UInt64(max(x.count, y.count))
        while let run = CompareEngine.previousDifference(a, b, before: offset, chunkSize: chunk) {
            backward.append(run)
            offset = run.lowerBound
        }
        #expect(backward.reversed() == expected)

        let window: Range<UInt64> = 12_000..<12_800
        let clipped = expected.compactMap { r -> Range<UInt64>? in
            let r = r.clamped(to: window)
            return r.isEmpty ? nil : r
        }
        #expect(CompareEngine.differingOffsets(in: window, a, b) == clipped)
    }

    @Test func cancellationAndProgress() {
        let x = randomBytes(5000, seed: 9)
        var y = x
        y[4900] ^= 1
        let a = snapshot(x), b = snapshot(y)
        #expect(CompareEngine.nextDifference(a, b, from: 0, chunkSize: 100, isCancelled: { true }) == nil)
        #expect(CompareEngine.previousDifference(a, b, before: 5000, chunkSize: 100, isCancelled: { true }) == nil)
        var reported: [Double] = []
        #expect(CompareEngine.nextDifference(a, b, from: 0, chunkSize: 100, progress: { reported.append($0) }) == 4900..<4901)
        #expect(reported.last == 1)
        #expect(reported == reported.sorted())
    }
}
