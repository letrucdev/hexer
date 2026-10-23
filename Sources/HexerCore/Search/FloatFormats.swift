/// Little-endian encoders and decoders for the four floating point types of HxD's search.
///
/// Real48 (Turbo Pascal `Real`): byte 0 is the exponent biased by 129 (0 means zero), then a 39-bit
/// fraction with an implicit leading 1, then the sign in the top bit of byte 5; no infinities, NaNs or
/// denormals. Extended: 64-bit significand with an explicit integer bit, then sign and a 15-bit exponent
/// biased by 16383.
extension SearchQuery.FloatType {
    /// The little-endian bytes of `value`, or nil if this type cannot represent it (overflow, a nonzero
    /// value that would round to zero, or infinity/NaN in Real48). Single rounds from `value`; to avoid
    /// double rounding from decimal text, `SearchEngine` parses Single patterns as `Float` directly.
    public func encode(_ value: Double) -> [UInt8]? {
        switch self {
        case .single:
            let f = Float(value)
            if f.isInfinite && !value.isInfinite { return nil }
            if f == 0 && value != 0 { return nil }
            return DataInspector.writeUInt(UInt64(f.bitPattern), 4, littleEndian: true)
        case .double:
            return DataInspector.writeUInt(value.bitPattern, 8, littleEndian: true)
        case .real48:
            return Self.real48(value)
        case .extended:
            return Self.extended(value)
        }
    }

    /// Decodes the first `byteCount` bytes (little-endian); Extended values are rounded to Double.
    public func decode(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= byteCount else { return nil }
        let v = DataInspector.readUInt(bytes, min(byteCount, 8), littleEndian: true)
        switch self {
        case .single: return Double(Float(bitPattern: UInt32(v)))
        case .double: return Double(bitPattern: v)
        case .real48:
            let exponent = Int(v & 0xFF)
            guard exponent != 0 else { return 0 }
            let fraction = (v >> 8) & (1 << 39 - 1)
            let negative = v >> 47 & 1 == 1
            let bits = (negative ? 1 << 63 : 0) | UInt64(exponent - 129 + 1023) << 52 | fraction << 13
            return Double(bitPattern: bits)
        case .extended:
            let significand = v
            let top = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
            let sign: Double = top & 0x8000 != 0 ? -1 : 1
            let exponent = Int(top & 0x7FFF)
            if exponent == 0x7FFF {
                return significand << 1 == 0 ? sign * .infinity : .nan
            }
            // The significand is rounded once to Double, then scaled (exact unless the result is subnormal).
            return sign * Double(sign: .plus, exponent: exponent - 16383 - 63, significand: Double(significand))
        }
    }

    private static func real48(_ value: Double) -> [UInt8]? {
        guard value.isFinite else { return nil }
        if value == 0 { return [UInt8](repeating: 0, count: 6) }
        let bits = value.bitPattern
        let biased = Int(bits >> 52 & 0x7FF)
        guard biased != 0 else { return nil } // Double denormals are far below Real48's range.
        var exponent = biased - 1023 + 129
        let fraction52 = bits & (1 << 52 - 1)
        // Round the 52-bit fraction to 39 bits, ties to even.
        var fraction = fraction52 >> 13
        let rest = fraction52 & 0x1FFF
        if rest > 0x1000 || (rest == 0x1000 && fraction & 1 == 1) { fraction += 1 }
        if fraction == 1 << 39 {
            fraction = 0
            exponent += 1
        }
        guard (1...255).contains(exponent) else { return nil }
        let sign: UInt64 = value.sign == .minus ? 1 << 47 : 0
        return DataInspector.writeUInt(sign | fraction << 8 | UInt64(exponent), 6, littleEndian: true)
    }

    private static func extended(_ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        let sign: UInt16 = value.sign == .minus ? 0x8000 : 0
        let biased = Int(bits >> 52 & 0x7FF)
        let fraction = bits & (1 << 52 - 1)
        let exponent: Int
        let significand: UInt64
        switch biased {
        case 0x7FF:
            exponent = 0x7FFF
            significand = fraction == 0 ? 1 << 63 : 0xC000_0000_0000_0000 | fraction << 11
        case 0 where fraction == 0:
            exponent = 0
            significand = 0
        case 0:
            // Double denormal: normalize; Extended's range covers it.
            let shift = fraction.leadingZeroBitCount
            significand = fraction << shift
            exponent = 16383 - 1074 + 63 - shift
        default:
            exponent = biased - 1023 + 16383
            significand = 1 << 63 | fraction << 11
        }
        return DataInspector.writeUInt(significand, 8, littleEndian: true)
            + DataInspector.writeUInt(UInt64(sign | UInt16(exponent)), 2, littleEndian: true)
    }
}
