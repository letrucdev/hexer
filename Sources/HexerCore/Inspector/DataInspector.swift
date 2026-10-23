import Foundation

/// The data types of the data inspector, in HxD's default order.
public enum InspectorType: String, CaseIterable, Codable, Sendable {
    case binary, int8, uint8, int16, uint16, int24, uint24, int32, uint32, int64, uint64
    case sleb128, uleb128
    case ansiChar, wideChar, utf8CodePoint
    case float32, float64
    case oleTime, fileTime, dosDate, dosTime, dosDateTime, timeT32, timeT64
    case guid
    case x86_16, x86_32, x86_64, arm64

    public var displayName: String {
        switch self {
        case .binary: "Binary (8 bit)"
        case .int8: "Int8"
        case .uint8: "UInt8"
        case .int16: "Int16"
        case .uint16: "UInt16"
        case .int24: "Int24"
        case .uint24: "UInt24"
        case .int32: "Int32"
        case .uint32: "UInt32"
        case .int64: "Int64"
        case .uint64: "UInt64"
        case .sleb128: "LEB128"
        case .uleb128: "ULEB128"
        case .ansiChar: "AnsiChar"
        case .wideChar: "WideChar (UTF-16)"
        case .utf8CodePoint: "UTF-8 code point"
        case .float32: "Single (float32)"
        case .float64: "Double (float64)"
        case .oleTime: "OLETIME"
        case .fileTime: "FILETIME"
        case .dosDate: "DOS date"
        case .dosTime: "DOS time"
        case .dosDateTime: "DOS time & date"
        case .timeT32: "time_t (32 bit)"
        case .timeT64: "time_t (64 bit)"
        case .guid: "GUID"
        case .x86_16: "Disassembly (x86-16)"
        case .x86_32: "Disassembly (x86-32)"
        case .x86_64: "Disassembly (x86-64)"
        case .arm64: "Disassembly (ARM64)"
        }
    }

    /// The row title inside its category: disassembly rows drop the repeated "Disassembly".
    public var shortName: String {
        switch self {
        case .x86_16: "x86-16"
        case .x86_32: "x86-32"
        case .x86_64: "x86-64"
        case .arm64: "ARM64"
        default: displayName
        }
    }

    public enum Category: String, CaseIterable, Sendable {
        case integers = "Integers", characters = "Characters", floatingPoint = "Floating point"
        case dateTime = "Date & time", other = "Other", disassembly = "Disassembly"
    }

    public var category: Category {
        switch self {
        case .binary, .int8, .uint8, .int16, .uint16, .int24, .uint24, .int32, .uint32, .int64, .uint64, .sleb128, .uleb128: .integers
        case .ansiChar, .wideChar, .utf8CodePoint: .characters
        case .float32, .float64: .floatingPoint
        case .oleTime, .fileTime, .dosDate, .dosTime, .dosDateTime, .timeT32, .timeT64: .dateTime
        case .guid: .other
        case .x86_16, .x86_32, .x86_64, .arm64: .disassembly
        }
    }

    /// Bytes the type occupies, or nil when it depends on the data (LEB128, UTF-8, code).
    public var fixedWidth: Int? {
        switch self {
        case .binary, .int8, .uint8, .ansiChar: 1
        case .int16, .uint16, .wideChar, .dosDate, .dosTime: 2
        case .int24, .uint24: 3
        case .int32, .uint32, .float32, .dosDateTime, .timeT32: 4
        case .int64, .uint64, .float64, .oleTime, .fileTime, .timeT64: 8
        case .guid: 16
        case .sleb128, .uleb128, .utf8CodePoint, .x86_16, .x86_32, .x86_64, .arm64: nil
        }
    }

    /// Disassembly rows are decoded by the app (HexerDisasm), not by `DataInspector`.
    public var isDisassembly: Bool { self == .x86_16 || self == .x86_32 || self == .x86_64 || self == .arm64 }

    /// Types whose value can be typed into the inspector to overwrite the bytes.
    public var isEditable: Bool { !isDisassembly && self != .utf8CodePoint }
}

public struct InspectorOptions: Equatable, Sendable {
    public var littleEndian = true
    public var hexIntegers = false
    public var encoding: TextEncoding = .windowsLatin1
    public init(littleEndian: Bool = true, hexIntegers: Bool = false, encoding: TextEncoding = .windowsLatin1) {
        self.littleEndian = littleEndian
        self.hexIntegers = hexIntegers
        self.encoding = encoding
    }
}

public struct InspectorValue: Equatable, Sendable {
    public var text: String
    /// Bytes the value occupies (for variable-width types: the bytes consumed).
    public var width: Int
    public var isValid: Bool

    public init(text: String, width: Int, isValid: Bool) {
        self.text = text
        self.width = width
        self.isValid = isValid
    }
}

public enum InspectorError: Error, Equatable {
    case invalidInput, outOfRange, notEditable
}

/// Interprets bytes at the caret as each inspector type, and encodes typed values back.
public enum DataInspector {
    static let notEnoughBytes = "—"
    static let invalid = "Invalid"

    /// Decodes `type` from `bytes` (the bytes at the caret; 16 are enough for every type).
    public static func decode(_ type: InspectorType, _ bytes: [UInt8], options: InspectorOptions) -> InspectorValue {
        if let w = type.fixedWidth, bytes.count < w { return InspectorValue(text: notEnoughBytes, width: w, isValid: false) }
        let le = options.littleEndian
        func u(_ n: Int) -> UInt64 { readUInt(bytes, n, littleEndian: le) }
        func signed(_ n: Int) -> Int64 {
            let v = u(n)
            let shift = UInt64(64 - n * 8)
            return Int64(bitPattern: v << shift) >> Int64(shift)
        }
        func int(_ v: Int64, _ bits: Int) -> String {
            options.hexIntegers ? hex(UInt64(bitPattern: v) & mask(bits), digits: bits / 4) : String(v)
        }
        func uint(_ v: UInt64, _ bits: Int) -> String {
            options.hexIntegers ? hex(v, digits: bits / 4) : String(v)
        }
        func ok(_ s: String, _ w: Int) -> InspectorValue { InspectorValue(text: s, width: w, isValid: true) }
        func bad(_ w: Int, _ s: String = invalid) -> InspectorValue { InspectorValue(text: s, width: w, isValid: false) }

        switch type {
        case .binary:
            let s = String(bytes[0], radix: 2)
            return ok(String(repeating: "0", count: 8 - s.count) + s, 1)
        case .int8: return ok(int(signed(1), 8), 1)
        case .uint8: return ok(uint(u(1), 8), 1)
        case .int16: return ok(int(signed(2), 16), 2)
        case .uint16: return ok(uint(u(2), 16), 2)
        case .int24: return ok(int(signed(3), 24), 3)
        case .uint24: return ok(uint(u(3), 24), 3)
        case .int32: return ok(int(signed(4), 32), 4)
        case .uint32: return ok(uint(u(4), 32), 4)
        case .int64: return ok(int(signed(8), 64), 8)
        case .uint64: return ok(uint(u(8), 64), 8)
        case .sleb128, .uleb128:
            guard let leb = LEB128.decode(bytes, signed: type == .sleb128) else { return bad(0, bytes.count < 10 ? notEnoughBytes : invalid) }
            let text: String
            if type == .sleb128 {
                text = options.hexIntegers ? (leb.signed < 0 ? "-" + hex(UInt64(-(leb.signed + 1)) + 1, digits: 1) : hex(UInt64(leb.signed), digits: 1)) : String(leb.signed)
            } else {
                text = options.hexIntegers ? hex(leb.unsigned, digits: 1) : String(leb.unsigned)
            }
            return ok(text, leb.width)
        case .ansiChar:
            guard let c = options.encoding.table.characters[Int(bytes[0])] else { return bad(1) }
            return ok(printable(c), 1)
        case .wideChar:
            let v = UInt16(u(2))
            guard let scalar = Unicode.Scalar(v) else { return bad(2) }
            return ok(printable(Character(scalar)), 2)
        case .utf8CodePoint:
            return UTF8Inspector.decode(bytes)
        case .float32:
            return ok(formatFloat("\(Float(bitPattern: UInt32(u(4))))"), 4)
        case .float64:
            return ok(formatFloat("\(Double(bitPattern: u(8)))"), 8)
        case .oleTime:
            let d = Double(bitPattern: u(8))
            guard let date = DateCodecs.oleDate(d) else { return bad(8) }
            return ok(DateCodecs.format(date), 8)
        case .fileTime:
            guard let date = DateCodecs.fileTime(u(8)) else { return bad(8) }
            return ok(DateCodecs.format(date), 8)
        case .dosDate:
            guard let s = DateCodecs.dosDate(UInt16(u(2))) else { return bad(2) }
            return ok(s, 2)
        case .dosTime:
            guard let s = DateCodecs.dosTime(UInt16(u(2))) else { return bad(2) }
            return ok(s, 2)
        case .dosDateTime:
            let v = UInt32(u(4))
            guard let d = DateCodecs.dosDate(UInt16(v >> 16)), let t = DateCodecs.dosTime(UInt16(v & 0xFFFF)) else { return bad(4) }
            return ok("\(d) \(t)", 4)
        case .timeT32:
            guard let date = DateCodecs.unixDate(Int64(Int32(truncatingIfNeeded: signed(4)))) else { return bad(4) }
            return ok(DateCodecs.format(date), 4)
        case .timeT64:
            guard let date = DateCodecs.unixDate(signed(8)) else { return bad(8) }
            return ok(DateCodecs.format(date), 8)
        case .guid:
            return ok(GUIDCodec.format(Array(bytes.prefix(16))), 16)
        case .x86_16, .x86_32, .x86_64, .arm64:
            return bad(0, "")
        }
    }

    /// Encodes `text` as `type`, producing the bytes to write at the caret.
    public static func encode(_ type: InspectorType, _ text: String, options: InspectorOptions) throws -> [UInt8] {
        let t = text.trimmingCharacters(in: .whitespaces)
        let le = options.littleEndian
        func bytes(_ v: UInt64, _ n: Int) -> [UInt8] { writeUInt(v, n, littleEndian: le) }
        func parseSigned(_ bits: Int) throws -> [UInt8] {
            if options.hexIntegers {
                guard let v = UInt64(stripHex(t), radix: 16), v <= mask(bits) else { throw InspectorError.outOfRange }
                return bytes(v, bits / 8)
            }
            guard let v = Int64(t) else { throw InspectorError.invalidInput }
            let lo = -(Int64(1) << (bits - 1)), hi = bits == 64 ? Int64.max : (Int64(1) << (bits - 1)) - 1
            guard v >= lo && v <= hi else { throw InspectorError.outOfRange }
            return bytes(UInt64(bitPattern: v) & mask(bits), bits / 8)
        }
        func parseUnsigned(_ bits: Int) throws -> [UInt8] {
            guard let v = options.hexIntegers ? UInt64(stripHex(t), radix: 16) : UInt64(t) else { throw InspectorError.invalidInput }
            guard v <= mask(bits) else { throw InspectorError.outOfRange }
            return bytes(v, bits / 8)
        }
        switch type {
        case .binary:
            guard t.count <= 8, let v = UInt8(t, radix: 2) else { throw InspectorError.invalidInput }
            return [v]
        case .int8: return try parseSigned(8)
        case .uint8: return try parseUnsigned(8)
        case .int16: return try parseSigned(16)
        case .uint16: return try parseUnsigned(16)
        case .int24: return try parseSigned(24)
        case .uint24: return try parseUnsigned(24)
        case .int32: return try parseSigned(32)
        case .uint32: return try parseUnsigned(32)
        case .int64: return try parseSigned(64)
        case .uint64: return try parseUnsigned(64)
        case .sleb128:
            guard let v = Int64(t) else { throw InspectorError.invalidInput }
            return LEB128.encode(signed: v)
        case .uleb128:
            guard let v = UInt64(t) else { throw InspectorError.invalidInput }
            return LEB128.encode(unsigned: v)
        case .ansiChar:
            guard t.count == 1, let b = options.encoding.table.byte(for: Character(t)) else { throw InspectorError.invalidInput }
            return [b]
        case .wideChar:
            guard t.unicodeScalars.count == 1, let s = t.unicodeScalars.first, s.value <= 0xFFFF else { throw InspectorError.invalidInput }
            return bytes(UInt64(s.value), 2)
        case .float32:
            guard let v = Float(t) else { throw InspectorError.invalidInput }
            return bytes(UInt64(v.bitPattern), 4)
        case .float64:
            guard let v = Double(t) else { throw InspectorError.invalidInput }
            return bytes(v.bitPattern, 8)
        case .oleTime:
            guard let date = DateCodecs.parse(t) else { throw InspectorError.invalidInput }
            return bytes(DateCodecs.oleValue(date).bitPattern, 8)
        case .fileTime:
            guard let date = DateCodecs.parse(t), let v = DateCodecs.fileTimeValue(date) else { throw InspectorError.invalidInput }
            return bytes(v, 8)
        case .dosDate:
            guard let v = DateCodecs.dosDateValue(t) else { throw InspectorError.invalidInput }
            return bytes(UInt64(v), 2)
        case .dosTime:
            guard let v = DateCodecs.dosTimeValue(t) else { throw InspectorError.invalidInput }
            return bytes(UInt64(v), 2)
        case .dosDateTime:
            let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let d = DateCodecs.dosDateValue(parts[0]), let tm = DateCodecs.dosTimeValue(parts[1]) else { throw InspectorError.invalidInput }
            return bytes(UInt64(d) << 16 | UInt64(tm), 4)
        case .timeT32:
            guard let date = DateCodecs.parse(t) else { throw InspectorError.invalidInput }
            let s = Int64(date.timeIntervalSince1970.rounded(.down))
            guard s >= Int64(Int32.min) && s <= Int64(Int32.max) else { throw InspectorError.outOfRange }
            return bytes(UInt64(bitPattern: s) & 0xFFFF_FFFF, 4)
        case .timeT64:
            guard let date = DateCodecs.parse(t) else { throw InspectorError.invalidInput }
            return bytes(UInt64(bitPattern: Int64(date.timeIntervalSince1970.rounded(.down))), 8)
        case .guid:
            guard let g = GUIDCodec.parse(t) else { throw InspectorError.invalidInput }
            return g
        case .utf8CodePoint, .x86_16, .x86_32, .x86_64, .arm64:
            throw InspectorError.notEditable
        }
    }

    // MARK: Helpers

    static func readUInt(_ b: [UInt8], _ n: Int, littleEndian: Bool) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n {
            let byte = UInt64(littleEndian ? b[n - 1 - i] : b[i])
            v = v << 8 | byte
        }
        return v
    }

    static func writeUInt(_ v: UInt64, _ n: Int, littleEndian: Bool) -> [UInt8] {
        var out = (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
        if !littleEndian { out.reverse() }
        return out
    }

    static func mask(_ bits: Int) -> UInt64 { bits >= 64 ? .max : (UInt64(1) << UInt64(bits)) - 1 }

    static func hex(_ v: UInt64, digits: Int) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return s.count < digits ? String(repeating: "0", count: digits - s.count) + s : s
    }

    static func stripHex(_ s: String) -> String {
        var t = s
        if t.lowercased().hasPrefix("0x") { t.removeFirst(2) }
        if t.lowercased().hasSuffix("h") { t.removeLast() }
        return t
    }

    static func printable(_ c: Character) -> String {
        guard let s = c.unicodeScalars.first else { return "" }
        if s.properties.generalCategory == .control { return String(format: "(U+%04X)", s.value) }
        return String(c)
    }

    /// Shortest representation that round-trips, with E notation for very large/small values.
    static func formatFloat(_ description: String) -> String {
        switch description {
        case "nan", "-nan": return "NaN"
        case "inf": return "+Inf"
        case "-inf": return "-Inf"
        default: break
        }
        var s = description.replacingOccurrences(of: "e+", with: "E+").replacingOccurrences(of: "e-", with: "E-")
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }
}
