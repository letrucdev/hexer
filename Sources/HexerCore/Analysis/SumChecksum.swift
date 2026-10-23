/// HxD's Custom checksum: the sum of fixed-size addends modulo 2^`resultWidth`.
///
/// The data is split into addends of `addendWidth` bits read in `byteOrder`. When the length is
/// not a multiple of the addend size, the data is treated as zero-padded at its end: a trailing
/// partial addend supplies the low-order bytes (little endian) or the high-order bytes (big endian).
/// The standard Checksum-8/16/32/64 are 8-bit addends with an 8/16/32/64-bit result.
public struct CustomChecksumParameters: Hashable, Codable, Sendable {
    public enum ByteOrder: String, Hashable, Codable, Sendable, CaseIterable {
        case littleEndian, bigEndian
    }

    /// Bits of the result: 8, 16, 32 or 64 in HxD (any 1...64 works).
    public var resultWidth: Int
    /// Bits per addend: 8, 16, 32 or 64.
    public var addendWidth: Int
    public var byteOrder: ByteOrder

    public init(resultWidth: Int, addendWidth: Int = 8, byteOrder: ByteOrder = .littleEndian) {
        self.resultWidth = resultWidth
        self.addendWidth = addendWidth
        self.byteOrder = byteOrder
    }

    /// The widths offered by HxD's Custom checksum dialog, for both result and addends.
    public static let dialogWidths = [8, 16, 32, 64]

    /// `resultWidth` limited to 1...64, as used by the calculation.
    public var effectiveResultWidth: Int { min(max(resultWidth, 1), 64) }

    /// Bytes per addend, 1...8.
    var addendBytes: Int { min(max(addendWidth / 8, 1), 8) }
}

struct SumHasher: ChecksumHasher {
    private let resultWidth: Int
    private let addendBytes: Int
    private let bigEndian: Bool
    private var sum: UInt64 = 0
    /// The start of an addend split across `update` calls.
    private var partial: [UInt8] = []

    init(_ p: CustomChecksumParameters) {
        resultWidth = p.effectiveResultWidth
        addendBytes = p.addendBytes
        bigEndian = p.byteOrder == .bigEndian
    }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        let n = data.count
        var i = 0
        if !partial.isEmpty {
            while i < n && partial.count < addendBytes {
                partial.append(data[i])
                i += 1
            }
            guard partial.count == addendBytes else { return }
            sum &+= addend(partial[...])
            partial.removeAll(keepingCapacity: true)
        }
        let end = i + (n - i) / addendBytes * addendBytes
        switch addendBytes {
        case 1: for b in data[i..<end] { sum &+= UInt64(b) }
        case 2: sum &+= Self.sum(data, i, end, as: UInt16.self, bigEndian: bigEndian)
        case 4: sum &+= Self.sum(data, i, end, as: UInt32.self, bigEndian: bigEndian)
        case 8: sum &+= Self.sum(data, i, end, as: UInt64.self, bigEndian: bigEndian)
        default:
            for k in stride(from: i, to: end, by: addendBytes) { sum &+= addend(data[k..<k + addendBytes]) }
        }
        partial.append(contentsOf: data[end..<n])
    }

    mutating func finalize() -> [UInt8] {
        if !partial.isEmpty {
            partial += repeatElement(0, count: addendBytes - partial.count)
            sum &+= addend(partial[...])
            partial = []
        }
        return bigEndianBytes(sum, bitWidth: resultWidth)
    }

    private func addend<C: Collection<UInt8>>(_ bytes: C) -> UInt64 {
        let ordered = bigEndian ? AnySequence(bytes) : AnySequence(bytes.reversed())
        return ordered.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func sum<T: FixedWidthInteger & UnsignedInteger & BitwiseCopyable>(
        _ data: UnsafeRawBufferPointer, _ start: Int, _ end: Int, as: T.Type, bigEndian: Bool
    ) -> UInt64 {
        var s: UInt64 = 0
        for k in stride(from: start, to: end, by: MemoryLayout<T>.size) {
            let raw = data.loadUnaligned(fromByteOffset: k, as: T.self)
            s &+= UInt64(bigEndian ? T(bigEndian: raw) : T(littleEndian: raw))
        }
        return s
    }
}
