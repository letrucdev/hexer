/// A CRC in the Rocksoft ("Williams") model, as set up in HxD's Custom CRC dialog.
///
/// `polynomial`, `initialValue` and `finalXOR` are written in normal (MSB-first) form without the
/// implicit top bit, as in the CRC catalogue: CRC-32 is poly 0x04C11DB7, init and final XOR
/// 0xFFFFFFFF, reflected in and out. HxD offers widths 8, 16, 24 and 32; any width in 1...64
/// works, and values are masked to the width.
public struct CRCParameters: Hashable, Codable, Sendable {
    public var width: Int
    public var polynomial: UInt64
    public var initialValue: UInt64
    public var finalXOR: UInt64
    public var reflectInput: Bool
    public var reflectOutput: Bool

    public init(width: Int, polynomial: UInt64, initialValue: UInt64 = 0, finalXOR: UInt64 = 0,
                reflectInput: Bool = false, reflectOutput: Bool = false) {
        self.width = width
        self.polynomial = polynomial
        self.initialValue = initialValue
        self.finalXOR = finalXOR
        self.reflectInput = reflectInput
        self.reflectOutput = reflectOutput
    }

    /// The widths offered by HxD's Custom CRC dialog.
    public static let dialogWidths = [8, 16, 24, 32]

    public static let crc8 = CRCParameters(width: 8, polynomial: 0x07)
    public static let crc16ARC = CRCParameters(width: 16, polynomial: 0x8005, reflectInput: true, reflectOutput: true)
    public static let crc16CCITTFalse = CRCParameters(width: 16, polynomial: 0x1021, initialValue: 0xFFFF)
    public static let crc32 = CRCParameters(width: 32, polynomial: 0x04C1_1DB7, initialValue: 0xFFFF_FFFF,
                                            finalXOR: 0xFFFF_FFFF, reflectInput: true, reflectOutput: true)
    public static let crc32C = CRCParameters(width: 32, polynomial: 0x1EDC_6F41, initialValue: 0xFFFF_FFFF,
                                             finalXOR: 0xFFFF_FFFF, reflectInput: true, reflectOutput: true)

    /// `width` limited to 1...64, as used by the calculation.
    public var effectiveWidth: Int { min(max(width, 1), 64) }

    /// All ones in the low `effectiveWidth` bits.
    public var mask: UInt64 { UInt64.max >> (64 - effectiveWidth) }

    /// Reverses the low `width` bits of `value`.
    static func reflect(_ value: UInt64, _ width: Int) -> UInt64 {
        var v = value, r: UInt64 = 0
        for _ in 0..<width {
            r = r << 1 | v & 1
            v >>= 1
        }
        return r
    }
}

/// Slicing-by-8 table-driven CRC for any width in 1...64.
///
/// Reflected CRCs keep the register bit-reversed in its low `width` bits; normal ones keep it in
/// the top bits of a 64-bit register. Either way widths below 8 need no special case.
struct CRCHasher: ChecksumHasher {
    private let width: Int
    private let reflected: Bool
    private let reflectOutput: Bool
    private let finalXOR: UInt64
    /// `tables[k << 8 | i]` is the register contribution of byte `i` followed by `k` zero bytes.
    private let tables: [UInt64]
    private var register: UInt64

    init(_ p: CRCParameters) {
        let w = p.effectiveWidth, mask = p.mask
        width = w
        reflected = p.reflectInput
        reflectOutput = p.reflectOutput
        finalXOR = p.finalXOR & mask
        var t = [UInt64](repeating: 0, count: 8 << 8)
        if reflected {
            let poly = CRCParameters.reflect(p.polynomial & mask, w)
            for i in 0..<256 {
                var c = UInt64(i)
                for _ in 0..<8 { c = c & 1 != 0 ? c >> 1 ^ poly : c >> 1 }
                t[i] = c
            }
            for k in 1..<8 {
                for i in 0..<256 {
                    let c = t[(k - 1) << 8 | i]
                    t[k << 8 | i] = c >> 8 ^ t[Int(c & 0xFF)]
                }
            }
            register = CRCParameters.reflect(p.initialValue & mask, w)
        } else {
            let poly = (p.polynomial & mask) << (64 - w)
            for i in 0..<256 {
                var c = UInt64(i) << 56
                for _ in 0..<8 { c = c >> 63 != 0 ? c << 1 ^ poly : c << 1 }
                t[i] = c
            }
            for k in 1..<8 {
                for i in 0..<256 {
                    let c = t[(k - 1) << 8 | i]
                    t[k << 8 | i] = c << 8 ^ t[Int(c >> 56)]
                }
            }
            register = (p.initialValue & mask) << (64 - w)
        }
        tables = t
    }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        let n = data.count
        var r = register, i = 0
        let reflected = reflected
        tables.withUnsafeBufferPointer { t in
            @inline(__always) func at(_ k: Int, _ byte: UInt64) -> UInt64 { t[k << 8 | Int(byte & 0xFF)] }
            if reflected {
                while i + 8 <= n {
                    let x = r ^ UInt64(littleEndian: data.loadUnaligned(fromByteOffset: i, as: UInt64.self))
                    let lo = at(7, x) ^ at(6, x >> 8) ^ at(5, x >> 16) ^ at(4, x >> 24)
                    r = lo ^ at(3, x >> 32) ^ at(2, x >> 40) ^ at(1, x >> 48) ^ at(0, x >> 56)
                    i += 8
                }
                while i < n {
                    r = at(0, r ^ UInt64(data[i])) ^ r >> 8
                    i += 1
                }
            } else {
                while i + 8 <= n {
                    let x = r ^ UInt64(bigEndian: data.loadUnaligned(fromByteOffset: i, as: UInt64.self))
                    let hi = at(7, x >> 56) ^ at(6, x >> 48) ^ at(5, x >> 40) ^ at(4, x >> 32)
                    r = hi ^ at(3, x >> 24) ^ at(2, x >> 16) ^ at(1, x >> 8) ^ at(0, x)
                    i += 8
                }
                while i < n {
                    r = at(0, r >> 56 ^ UInt64(data[i])) ^ r << 8
                    i += 1
                }
            }
        }
        register = r
    }

    mutating func finalize() -> [UInt8] {
        // The register in normal orientation is `reflect(register)` for reflected CRCs.
        let value = reflected
            ? (reflectOutput ? register : CRCParameters.reflect(register, width))
            : (reflectOutput ? CRCParameters.reflect(register >> (64 - width), width) : register >> (64 - width))
        return bigEndianBytes(value ^ finalXOR, bitWidth: width)
    }
}

/// The low `bitWidth` bits of `value` as `(bitWidth + 7) / 8` bytes, most significant first.
func bigEndianBytes(_ value: UInt64, bitWidth: Int) -> [UInt8] {
    let count = (bitWidth + 7) / 8
    return (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(count - 1 - $0))) }
}
