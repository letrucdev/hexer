import Foundation

/// Variable-length integers as used in WebAssembly and DWARF.
public enum LEB128 {
    public struct Value: Equatable, Sendable {
        public var unsigned: UInt64
        public var signed: Int64
        public var width: Int
    }

    /// Decodes up to 10 bytes; nil if the value does not terminate within them.
    public static func decode(_ bytes: [UInt8], signed: Bool) -> Value? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for (i, b) in bytes.prefix(10).enumerated() {
            if shift < 64 { result |= UInt64(b & 0x7F) << shift }
            shift += 7
            if b & 0x80 == 0 {
                var s = Int64(bitPattern: result)
                if signed && shift < 64 && b & 0x40 != 0 { s |= -(Int64(1) << Int64(shift)) }
                return Value(unsigned: result, signed: s, width: i + 1)
            }
        }
        return nil
    }

    public static func encode(unsigned value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    public static func encode(signed value: Int64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while true {
            let b = UInt8(truncatingIfNeeded: v & 0x7F)
            v >>= 7
            if (v == 0 && b & 0x40 == 0) || (v == -1 && b & 0x40 != 0) {
                out.append(b)
                return out
            }
            out.append(b | 0x80)
        }
    }
}

/// Decodes one UTF-8 sequence, naming the specific problem when it is malformed.
public enum UTF8Inspector {
    public static func decode(_ bytes: [UInt8]) -> InspectorValue {
        guard let b0 = bytes.first else { return InspectorValue(text: "—", width: 1, isValid: false) }
        func invalid(_ why: String, _ w: Int = 1) -> InspectorValue { InspectorValue(text: "Invalid: \(why)", width: w, isValid: false) }
        let length: Int, initial: UInt32
        switch b0 {
        case 0x00...0x7F: return value(UInt32(b0), width: 1)
        case 0x80...0xBF: return invalid("continuation byte")
        case 0xC0...0xDF: length = 2; initial = UInt32(b0 & 0x1F)
        case 0xE0...0xEF: length = 3; initial = UInt32(b0 & 0x0F)
        case 0xF0...0xF7: length = 4; initial = UInt32(b0 & 0x07)
        default: return invalid("lead byte")
        }
        guard bytes.count >= length else { return InspectorValue(text: "—", width: length, isValid: false) }
        var cp = initial
        for i in 1..<length {
            guard bytes[i] & 0xC0 == 0x80 else { return invalid("missing continuation byte", i) }
            cp = cp << 6 | UInt32(bytes[i] & 0x3F)
        }
        let minimum: UInt32 = [0, 0, 0x80, 0x800, 0x10000][length]
        if cp < minimum { return invalid(String(format: "overlong encoding (U+%04X)", cp), length) }
        if (0xD800...0xDFFF).contains(cp) { return invalid(String(format: "UTF-16 surrogate half (U+%04X)", cp), length) }
        if cp > 0x10FFFF { return invalid("beyond U+10FFFF", length) }
        return value(cp, width: length)
    }

    private static func value(_ cp: UInt32, width: Int) -> InspectorValue {
        let scalar = Unicode.Scalar(cp)!
        let shown = scalar.properties.generalCategory == .control ? "" : " \(Character(scalar))"
        return InspectorValue(text: String(format: "U+%04X", cp) + shown, width: width, isValid: true)
    }
}

/// Windows, DOS and Unix timestamps.
public enum DateCodecs {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static let oleEpoch = Date(timeIntervalSince1970: -2_209_161_600) // 1899-12-30
    static let minDate = Date(timeIntervalSince1970: -62_135_596_800) // 0001-01-01
    static let maxDate = Date(timeIntervalSince1970: 253_402_300_799) // 9999-12-31 23:59:59

    public static func format(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// Parses "yyyy-MM-dd HH:mm:ss" (seconds and time optional), as UTC.
    public static func parse(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "T" })
        guard let datePart = parts.first else { return nil }
        let d = datePart.split(separator: "-").compactMap { Int($0) }
        guard d.count == 3 else { return nil }
        var t = [0, 0, 0]
        if parts.count > 1 {
            let tp = parts[1].split(separator: ":").compactMap { Int($0) }
            guard (2...3).contains(tp.count) else { return nil }
            for (i, v) in tp.enumerated() { t[i] = v }
        }
        let comps = DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1], second: t[2])
        guard comps.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: comps)
    }

    static func inRange(_ d: Date) -> Date? { d >= minDate && d <= maxDate ? d : nil }

    public static func oleDate(_ days: Double) -> Date? {
        guard days.isFinite, days > -657_435, days < 2_958_466 else { return nil }
        // Negative OLE dates count days backwards but the time of day forwards.
        let whole = days.rounded(.towardZero)
        let fraction = abs(days - whole)
        return inRange(oleEpoch.addingTimeInterval((whole + fraction) * 86_400))
    }

    public static func oleValue(_ date: Date) -> Double {
        date.timeIntervalSince(oleEpoch) / 86_400
    }

    /// 100-ns intervals since 1601-01-01 UTC.
    public static func fileTime(_ v: UInt64) -> Date? {
        guard v < UInt64(Int64.max) else { return nil }
        let seconds = Double(v / 10_000_000) - 11_644_473_600
        return inRange(Date(timeIntervalSince1970: seconds))
    }

    public static func fileTimeValue(_ date: Date) -> UInt64? {
        let s = date.timeIntervalSince1970 + 11_644_473_600
        guard s >= 0 else { return nil }
        return UInt64(s) * 10_000_000
    }

    public static func unixDate(_ seconds: Int64) -> Date? {
        guard abs(seconds) < 300_000_000_000 else { return nil }
        return inRange(Date(timeIntervalSince1970: Double(seconds)))
    }

    public static func dosDate(_ v: UInt16) -> String? {
        let day = Int(v & 0x1F), month = Int(v >> 5 & 0x0F), year = Int(v >> 9) + 1980
        guard (1...12).contains(month), day >= 1,
              DateComponents(year: year, month: month, day: day).isValidDate(in: calendar) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func dosTime(_ v: UInt16) -> String? {
        let second = Int(v & 0x1F) * 2, minute = Int(v >> 5 & 0x3F), hour = Int(v >> 11)
        guard hour < 24, minute < 60, second < 60 else { return nil }
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    public static func dosDateValue(_ s: String) -> UInt16? {
        let d = s.split(separator: "-").compactMap { Int($0) }
        guard d.count == 3, (1980...2107).contains(d[0]), (1...12).contains(d[1]), (1...31).contains(d[2]) else { return nil }
        return UInt16((d[0] - 1980) << 9 | d[1] << 5 | d[2])
    }

    public static func dosTimeValue(_ s: String) -> UInt16? {
        let t = s.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(t.count), t[0] < 24, t[1] < 60 else { return nil }
        let sec = t.count == 3 ? t[2] : 0
        guard sec < 60 else { return nil }
        return UInt16(t[0] << 11 | t[1] << 5 | sec / 2)
    }
}

/// GUIDs in Microsoft's mixed-endian layout: Data1–3 little-endian, Data4 as bytes.
public enum GUIDCodec {
    public static func format(_ b: [UInt8]) -> String {
        precondition(b.count >= 16)
        func h(_ r: [Int]) -> String { r.map { String(format: "%02X", b[$0]) }.joined() }
        return "{\(h([3, 2, 1, 0]))-\(h([5, 4]))-\(h([7, 6]))-\(h([8, 9]))-\(h(Array(10...15)))}"
    }

    public static func parse(_ s: String) -> [UInt8]? {
        let hex = s.filter { $0.isHexDigit }
        guard hex.count == 32 else { return nil }
        let raw = stride(from: 0, to: 32, by: 2).map { i -> UInt8 in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[a..<hex.index(a, offsetBy: 2)], radix: 16)!
        }
        let order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
        return order.map { raw[$0] }
    }
}
