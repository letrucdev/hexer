import Foundation

/// The text record formats HxD can import (File ▸ Import).
public enum HexRecordFormat: String, CaseIterable, Sendable {
    case intelHex
    case motorolaSRecord
    /// ETL Extended Format (*.eef): S-Record-like `X0`–`X9` records with a 16-bit byte count.
    case etlExtended

    public var displayName: String {
        switch self {
        case .intelHex: "Intel Hex"
        case .motorolaSRecord: "Motorola S-Record"
        case .etlExtended: "ETL Extended"
        }
    }

    /// File name extensions offered in HxD's open dialog.
    public var fileExtensions: [String] {
        switch self {
        case .intelHex: ["hex"]
        case .motorolaSRecord: ["mot", "srec", "s", "s19", "s28", "s37"]
        case .etlExtended: ["eef"]
        }
    }
}

/// Parses Intel Hex, Motorola S-Record and ETL Extended files into an `ImportedImage`.
///
/// Follows HxD 2.5: lines are trimmed of leading and trailing whitespace (any byte ≤ 0x20) and
/// empty lines are skipped; checksums are verified; records may come in any order and overlap
/// (later records win); addresses no record covers become undefined gaps.
///
/// - Intel Hex: record types 00–05. Type 02 sets a segment base (`value * 16`, data addresses
///   wrap at 1 MiB), type 04 a linear base (`value << 16`); 03/05 give start addresses; lines
///   after the 01 EOF record are an error. A missing EOF record is accepted.
/// - S-Record: S0 (kept as metadata), S1/S2/S3 data with 16/24/32-bit addresses, S5 record counts
///   (checked against the data records since the previous S5 or the beginning), S7/S8/S9 start
///   addresses. S4 and S6 are rejected, as in HxD.
/// - ETL Extended (reconstructed from HxD's importer): `X` + type digit, a 16-bit byte count, a
///   24-bit address for X0–X3 and X7 (none for the others), data, and an S-Record style checksum
///   (ones' complement of the sum of count, address and data bytes). X7 carries data; X0, X1 and
///   X3 carry text and X2 an annotation (a color byte, bit 7 a flag and bits 0–5 an EGA palette
///   index, then text), all kept as metadata; X4–X6, X8 and X9 are checked and ignored.
public enum RecordImporter {
    /// Guesses the format from the first non-blank character (`:`, `S` or `X`).
    public static func detectFormat(_ data: Data) -> HexRecordFormat? {
        for byte in data where byte > 0x20 {
            switch byte {
            case UInt8(ascii: ":"): return .intelHex
            case UInt8(ascii: "S"): return .motorolaSRecord
            case UInt8(ascii: "X"): return .etlExtended
            default: return nil
            }
        }
        return nil
    }

    public static func importRecords(_ data: Data, format: HexRecordFormat, fileName: String = "",
                                     isCancelled: () -> Bool = { false },
                                     progress: (Double) -> Void = { _ in }) throws -> ImportedImage {
        try data.withUnsafeBytes { raw in
            try parse(raw, format: format, fileName: fileName, isCancelled: isCancelled, progress: progress)
        }
    }

    public static func importRecords(_ bytes: [UInt8], format: HexRecordFormat, fileName: String = "",
                                     isCancelled: () -> Bool = { false },
                                     progress: (Double) -> Void = { _ in }) throws -> ImportedImage {
        try bytes.withUnsafeBytes { raw in
            try parse(raw, format: format, fileName: fileName, isCancelled: isCancelled, progress: progress)
        }
    }

    public static func importRecords(_ text: String, format: HexRecordFormat, fileName: String = "") throws -> ImportedImage {
        try importRecords(Array(text.utf8), format: format, fileName: fileName)
    }

    // MARK: - Parsing

    private static func parse(_ raw: UnsafeRawBufferPointer, format: HexRecordFormat, fileName: String,
                              isCancelled: () -> Bool, progress: (Double) -> Void) throws -> ImportedImage {
        var state = ParseState(fileName: fileName)
        var lineNumber = 0
        var pos = 0
        let count = raw.count
        var nextReport = 0
        while pos < count {
            // One line, ended by CR, LF or CRLF.
            var end = pos
            while end < count && raw[end] != 0x0A && raw[end] != 0x0D { end += 1 }
            let next = end < count && raw[end] == 0x0D && end + 1 < count && raw[end + 1] == 0x0A ? end + 2 : end + 1
            lineNumber += 1
            var start = pos
            var stop = end
            while start < stop && raw[start] <= 0x20 { start += 1 }
            while stop > start && raw[stop - 1] <= 0x20 { stop -= 1 }
            if start < stop {
                var line = LineCursor(raw: raw, start: start, end: stop, line: lineNumber, leading: start - pos,
                                      fileName: fileName)
                switch format {
                case .intelHex: try state.intelHex(&line)
                case .motorolaSRecord: try state.sRecord(&line)
                case .etlExtended: try state.etl(&line)
                }
            }
            pos = next
            if pos >= nextReport {
                if isCancelled() { throw CancellationError() }
                progress(Double(min(pos, count)) / Double(max(count, 1)))
                nextReport = pos + (1 << 20)
            }
        }
        return ImportedImage(runs: state.builder.runs(), startAddresses: state.startAddresses, metadata: state.metadata)
    }
}

/// Reads fields of one trimmed line; positions are 0-based within the trimmed line.
private struct LineCursor {
    let raw: UnsafeRawBufferPointer
    let start: Int
    let end: Int
    let line: Int
    let leading: Int
    let fileName: String
    var pos = 0

    init(raw: UnsafeRawBufferPointer, start: Int, end: Int, line: Int, leading: Int, fileName: String) {
        self.raw = raw
        self.start = start
        self.end = end
        self.line = line
        self.leading = leading
        self.fileName = fileName
    }

    var length: Int { end - start }
    var remaining: Int { length - pos }

    func char(_ i: Int) -> UInt8 { raw[start + i] }

    /// Up to `n` characters from `i`, as text for an error message.
    func text(_ i: Int, _ n: Int) -> String {
        let a = min(i, length), b = min(i + n, length)
        return String((a..<b).map { Character(Unicode.Scalar(char($0))) })
    }

    func error(_ kind: HexImportError.Kind, at i: Int) -> HexImportError {
        HexImportError(kind: kind, line: line, column: leading + i + 1, fileName: fileName)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x41...0x46: c - 0x41 + 10
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }

    /// Two hex digits forming a value in `lo...hi`.
    mutating func byte(_ lo: UInt8 = 0, _ hi: UInt8 = 0xFF) throws -> UInt8 {
        guard remaining >= 2, let h = Self.nibble(char(pos)), let l = Self.nibble(char(pos + 1)),
              (lo...hi).contains(h << 4 | l) else {
            throw error(.hexDigits(min: lo, max: hi, found: text(pos, 2)), at: pos)
        }
        pos += 2
        return h << 4 | l
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n { out[i] = try byte() }
        return out
    }

    /// Big-endian value of `n` bytes.
    mutating func value(_ n: Int, into sum: inout Int) throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<n {
            let b = try byte()
            sum += Int(b)
            v = v << 8 | UInt64(b)
        }
        return v
    }

    /// Reads the checksum byte and compares it with `expected`.
    mutating func checksum(_ expected: UInt8) throws {
        let at = pos
        let found = try byte()
        if found != expected { throw error(.checksum(expected: expected, found: found), at: at) }
    }

    func expectEnd() throws {
        if pos < length { throw error(.expectedEndOfLine(found: text(pos, 1)), at: pos) }
    }
}

private struct ParseState {
    let fileName: String
    var builder = SparseImageBuilder()
    var startAddresses: [UInt64] = []
    var metadata: [ImportedImage.MetadataRecord] = []
    // Intel Hex
    var sawEOF = false
    var base: UInt64 = 0
    var segmentMode = false
    // S-Record
    var dataRecords: UInt64 = 0

    init(fileName: String) { self.fileName = fileName }

    mutating func write(_ data: [UInt8], at address: UInt64) {
        data.withUnsafeBytes { builder.write($0, at: address) }
    }

    // MARK: Intel Hex

    mutating func intelHex(_ line: inout LineCursor) throws {
        if sawEOF { throw line.error(.lineAfterEndOfFile, at: 0) }
        if line.char(0) != UInt8(ascii: ":") {
            throw line.error(.expected(":", found: line.text(0, 1)), at: 0)
        }
        line.pos = 1
        let count = try line.byte()
        let addrHi = try line.byte()
        let addrLo = try line.byte()
        let type = try line.byte(0, 5)
        let data = try line.bytes(Int(count))
        let sum = data.reduce(Int(count) + Int(addrHi) + Int(addrLo) + Int(type)) { $0 + Int($1) }
        try line.checksum(UInt8(truncatingIfNeeded: 0x100 - (sum & 0xFF)))
        try line.expectEnd()
        let offset = UInt64(addrHi) << 8 | UInt64(addrLo)

        func require(_ n: Int) throws {
            if data.count != n {
                throw line.error(.wrongDataLength(recordType: Hex.upper[Int(type)], expected: n, found: data.count), at: 1)
            }
        }
        switch type {
        case 0x00:
            if segmentMode && offset + UInt64(data.count) > 0x1_0000 {
                // I16HEX addresses wrap within the 64 KiB segment: SBA·16 + ((DRLO + i) mod 64K).
                let first = Int(0x1_0000 - offset)
                write(Array(data[..<first]), at: (base + offset) % 0x10_0000)
                write(Array(data[first...]), at: base % 0x10_0000)
            } else {
                write(data, at: segmentMode ? (base + offset) % 0x10_0000 : base + offset)
            }
        case 0x01:
            try require(0)
            sawEOF = true
        case 0x02:
            try require(2)
            base = (UInt64(data[0]) << 8 | UInt64(data[1])) * 16
            segmentMode = true
        case 0x03:
            try require(4)
            let cs = UInt64(data[0]) << 8 | UInt64(data[1])
            let ip = UInt64(data[2]) << 8 | UInt64(data[3])
            startAddresses.append(cs * 16 + ip)
        case 0x04:
            try require(2)
            base = (UInt64(data[0]) << 8 | UInt64(data[1])) << 16
            segmentMode = false
        default:
            try require(4)
            startAddresses.append(data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }
    }

    // MARK: S-Record

    mutating func sRecord(_ line: inout LineCursor) throws {
        // S0, S1, S2, S3, S5, S7, S8, S9 (no S4 or S6, as in HxD).
        let addressBytes: [Int?] = [2, 2, 3, 4, nil, 2, nil, 4, 3, 2]
        guard line.length >= 2, line.char(0) == UInt8(ascii: "S"),
              (0x30...0x39).contains(line.char(1)), let width = addressBytes[Int(line.char(1) - 0x30)] else {
            throw line.error(.sRecordType(found: line.text(0, 2)), at: 0)
        }
        let type = Int(line.char(1) - 0x30)
        line.pos = 2
        let count = try line.byte()
        var sum = Int(count)
        let address = try line.value(width, into: &sum)
        guard Int(count) >= width + 1 else {
            throw line.error(.byteCountTooSmall(count: Int(count), minimum: width + 1), at: 2)
        }
        let data = try line.bytes(Int(count) - width - 1)
        sum = data.reduce(sum) { $0 + Int($1) }
        try line.checksum(UInt8(truncatingIfNeeded: 0xFF - (sum & 0xFF)))
        try line.expectEnd()

        switch type {
        case 0:
            metadata.append(.init(type: "S0", address: address, bytes: data))
        case 1, 2, 3:
            write(data, at: address)
            dataRecords += 1
        case 5:
            if dataRecords != address {
                throw line.error(.recordCount(expected: address, found: dataRecords), at: 0)
            }
            dataRecords = 0
        default:
            startAddresses.append(address)
        }
    }

    // MARK: ETL Extended

    mutating func etl(_ line: inout LineCursor) throws {
        guard line.length >= 2, line.char(0) == UInt8(ascii: "X"), (0x30...0x39).contains(line.char(1)) else {
            throw line.error(.etlRecordType(found: line.text(0, 2)), at: 0)
        }
        let type = Int(line.char(1) - 0x30)
        line.pos = 2
        var sum = 0
        let count = Int(try line.value(2, into: &sum))
        let width = type <= 3 || type == 7 ? 3 : 0
        let address = try line.value(width, into: &sum)
        guard count >= width + 1 else {
            throw line.error(.byteCountTooSmall(count: count, minimum: width + 1), at: 2)
        }
        let data = try line.bytes(count - width - 1)
        sum = data.reduce(sum) { $0 + Int($1) }
        try line.checksum(UInt8(truncatingIfNeeded: 0xFF - (sum & 0xFF)))
        try line.expectEnd()

        switch type {
        case 0, 1, 2, 3:
            metadata.append(.init(type: "X\(type)", address: address, bytes: data))
        case 7:
            write(data, at: address)
        default:
            break
        }
    }
}
