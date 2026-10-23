import CoreFoundation
import Foundation
import HexerCore
import HexerDisasm

/// `selftest` — known-answer and differential checks of the core in this very binary, for builds
/// the test suite doesn't run on (the x86_64 slice of a universal build under Rosetta, another Mac).
/// Prints PASS/FAIL per check; exit status 1 if any fails.
func selftest(_ args: [String]) {
    _ = Arguments(args, command: "selftest").expect(0, usage: "selftest")
    var failed = 0
    let out = Output()
    func check(_ name: String, _ body: () throws -> String?) {
        let problem: String?
        do { problem = try body() } catch { problem = describe(error) }
        if let problem {
            failed += 1
            out.write("FAIL \(name): \(problem)\n")
        } else {
            out.write("PASS \(name)\n")
        }
        out.flush()
    }
    func snapshot(_ bytes: [UInt8]) -> ByteSnapshot { EditableBuffer(source: MemoryByteSource(bytes)).snapshot() }
    func expect<T: Equatable>(_ got: T, _ want: T) -> String? { got == want ? nil : "got \(got), expected \(want)" }
    var rng = SplitMix64(seed: 0x4845_5845_52)

    check("checksums of \"123456789\" (CRC catalogue check values)") {
        let data = snapshot(Array("123456789".utf8))
        let algorithms: [ChecksumAlgorithm] = [.checksum8, .crc16, .crc16CCITTFalse, .crc32, .crc32C]
        let got = ChecksumCalculator.compute(algorithms, snapshot: data, range: 0..<data.length)!.map { $0.hexString.uppercased() }
        return expect(got, ["DD", "BB3D", "29B1", "CBF43926", "E3069283"])
    }
    check("digests of \"abc\" (RFC 1319, 1320, 1321, FIPS 180)") {
        let data = snapshot(Array("abc".utf8))
        let got = ChecksumCalculator.compute([.md2, .md4, .md5, .sha1, .sha256], snapshot: data, range: 0..<data.length)!
            .map { $0.hexString.lowercased() }
        return expect(got, ["da853b0d3f88d99b30283a69e6ded6bb", "a448017aaf21d8525fc10ae87aa6729d",
                            "900150983cd24fb0d6963f7d28e17f72", "a9993e364706816aba3e25717850c26c9cd0d89d",
                            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"])
    }
    check("text encodings agree with CoreFoundation and HxD's EBCDIC 500 table") {
        let cf: [TextEncoding: CFStringBuiltInEncodings] = [
            .windowsLatin1: .windowsLatin1, .macRoman: .macRoman,
        ]
        for (encoding, cfEncoding) in cf {
            let table = encoding.table
            for byte in 0x20...0xFF where byte != 0x7F {
                let b = [UInt8(byte)]
                let reference = CFStringCreateWithBytes(nil, b, 1, cfEncoding.rawValue, false) as String?
                guard let c = table.characters[byte] else {
                    if reference != nil && encoding != .windowsLatin1 { return "\(encoding) \(byte) has no character" }
                    continue
                }
                if reference.map(Character.init) != c { return "\(encoding) byte \(byte): \(c) vs \(reference ?? "nil")" }
                if table.byte(for: c) != UInt8(byte) { return "\(encoding) does not encode \(c) back to \(byte)" }
            }
        }
        let ebcdic = TextEncoding.ebcdic500.table
        return expect([0xC1, 0x81, 0xF0, 0x4A, 0x5A].map { ebcdic.characters[$0] }, ["A", "a", "0", "[", "]"])
    }
    check("piece tree: 4000 random edits and undo all vs an array") {
        var model = (0..<5000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let original = model
        let buffer = EditableBuffer(source: MemoryByteSource(model))
        for step in 0..<4000 {
            let at = UInt64.random(in: 0...UInt64(model.count), using: &rng)
            let bytes = (0..<Int.random(in: 1...40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            switch Int.random(in: 0..<3, using: &rng) {
            case 0:
                try buffer.insert(bytes, at: at, selectionBefore: Selection(caret: at))
                model.insert(contentsOf: bytes, at: Int(at))
            case 1:
                try buffer.overwrite(bytes, at: at, selectionBefore: Selection(caret: at))
                let end = min(Int(at) + bytes.count, model.count)
                model.replaceSubrange(Int(at)..<end, with: bytes)
            default:
                let end = min(at + UInt64(bytes.count), UInt64(model.count))
                try buffer.delete(at..<end, selectionBefore: Selection(caret: at))
                model.removeSubrange(Int(at)..<Int(end))
            }
            if step % 500 == 0, buffer.snapshot().bytes(0..<buffer.length) != model { return "differs after edit \(step)" }
        }
        if buffer.snapshot().bytes(0..<buffer.length) != model { return "differs after the edits" }
        while buffer.canUndo { buffer.undo() }
        return buffer.snapshot().bytes(0..<buffer.length) == original ? nil : "undo all does not restore the data"
    }
    check("find all vs a naive scan, across search chunks") {
        var bytes = (0..<300_000).map { _ in UInt8.random(in: 0...3, using: &rng) }
        let needle: [UInt8] = [1, 2, 3, 0, 1]
        for at in [0, 65_535, 131_071, 299_995] { bytes.replaceSubrange(at..<at + needle.count, with: needle) }
        var naive: [UInt64] = []
        var i = 0
        while i + needle.count <= bytes.count {
            if bytes[i..<i + needle.count].elementsEqual(needle) { naive.append(UInt64(i)); i += needle.count } else { i += 1 }
        }
        let query = try SearchEngine.compile(SearchQuery(.hex, pattern: "01 02 03 00 01"))
        let found = try SearchEngine.findAll(in: snapshot(bytes), query: query, chunkSize: 1 << 16).matches.map(\.lowerBound)
        return expect(found, naive)
    }
    check("Intel Hex and S-Record export, then import") {
        let bytes = (0..<70_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let data = snapshot(bytes)
        let ihex = try ExportText.collect { sink in
            try RecordExporter.exportIntelHex(data, range: 0..<data.length, variant: .bits32, to: sink)
        }
        let srec = try ExportText.collect { sink in
            try RecordExporter.exportSRecord(data, range: 0..<data.length, variant: .s37, to: sink)
        }
        for (text, format) in [(ihex, HexRecordFormat.intelHex), (srec, .motorolaSRecord)] {
            let image = try RecordImporter.importRecords(text, format: format)
            if image.dataBytes != bytes { return "\(format) round trip differs" }
        }
        return nil
    }
    check("save to a file and read it back") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hexer-selftest-\(getpid())")
        defer { unlink(url.path) }
        let buffer = EditableBuffer(source: MemoryByteSource(Array(repeating: 0xAA, count: 9 << 20)))
        try buffer.insert([1, 2, 3], at: 4 << 20, selectionBefore: Selection(caret: 0))
        try buffer.apply("Fill", replacing: 0..<1000, with: buffer.generatedPieces(.pattern([0xDE, 0xAD]), count: 1000),
                         selectionBefore: Selection(caret: 0), selectionAfter: Selection(caret: 0))
        try FileWriter.write(buffer.snapshot(), to: url)
        let saved = EditableBuffer(source: try FileByteSource(url: url)).snapshot()
        let want = buffer.snapshot()
        return saved.length == want.length && saved.bytes(0..<saved.length) == want.bytes(0..<want.length)
            ? nil : "the file differs from the document"
    }
    check("disassembly (Capstone \(Disassembler.version))") {
        let x64 = try Disassembler(.x86_64).disassemble([0x55, 0x48, 0x89, 0xE5, 0xC3]).map(\.text)
        let arm = try Disassembler(.arm64).disassemble([0xFD, 0x03, 0x00, 0x91, 0xC0, 0x03, 0x5F, 0xD6]).map(\.text)
        return expect(x64 + arm, ["push rbp", "mov rbp, rsp", "ret", "mov x29, sp", "ret"])
    }

    out.write(failed == 0 ? "selftest: all checks passed\n" : "selftest: \(failed) failed\n")
    out.close()
    if failed > 0 { exit(1) }
}

/// A small seedable generator, so failures are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
