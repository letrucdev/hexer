/// The address width of an Intel Hex export (HxD's "16/20/32 Bit Intel Hex").
public enum IntelHexVariant: String, CaseIterable, Sendable {
    /// I8HEX: data records only, addresses below 64 KiB.
    case bits16
    /// I16HEX: type 02 extended segment address records, addresses below 1 MiB.
    case bits20
    /// I32HEX: type 04 extended linear address records, addresses below 4 GiB.
    case bits32

    public var displayName: String {
        switch self {
        case .bits16: "16 Bit Intel Hex"
        case .bits20: "20 Bit Intel Hex"
        case .bits32: "32 Bit Intel Hex"
        }
    }

    /// The first address the variant cannot express.
    public var addressLimit: UInt64 {
        switch self {
        case .bits16: 0x1_0000
        case .bits20: 0x10_0000
        case .bits32: 0x1_0000_0000
        }
    }
}

/// The address width of a Motorola S-Record export (HxD's "Motorola S19/S28/S37-Records").
public enum SRecordVariant: String, CaseIterable, Sendable {
    case s19, s28, s37

    public var displayName: String {
        switch self {
        case .s19: "Motorola S19-Records"
        case .s28: "Motorola S28-Records"
        case .s37: "Motorola S37-Records"
        }
    }

    var addressBytes: Int {
        switch self {
        case .s19: 2
        case .s28: 3
        case .s37: 4
        }
    }

    public var addressLimit: UInt64 { 1 << (8 * UInt64(addressBytes)) }

    var dataType: String {
        switch self {
        case .s19: "S1"
        case .s28: "S2"
        case .s37: "S3"
        }
    }

    /// HxD's fixed termination record (start address 0).
    public var terminator: String {
        switch self {
        case .s19: "S9030000FC"
        case .s28: "S804000000FB"
        case .s37: "S70500000000FA"
        }
    }
}

/// Options for Intel Hex and S-Record exports.
public struct RecordExportOptions: Equatable, Sendable {
    /// Data bytes per record. HxD's default is 32 for both formats; Intel Hex allows 1–255,
    /// S-Records 1–250 (values outside are clamped).
    public var bytesPerLine: Int
    public var lineBreak: String

    public init(bytesPerLine: Int = 32, lineBreak: String = "\r\n") {
        self.bytesPerLine = bytesPerLine
        self.lineBreak = lineBreak
    }
}

/// Intel Hex and Motorola S-Record export, as HxD 2.5 writes them.
///
/// Records hold the bytes at their document offsets (address = offset) and are aligned to
/// multiples of `bytesPerLine`, so a range starting mid-line begins with a short record.
/// Undefined and unreadable bytes are skipped; the next defined byte starts a new record at its
/// own address, so imported files with gaps round-trip.
///
/// - Intel Hex: no header; data records `:LLAAAA00…CC`; the 20-bit variant precedes the first
///   record and every segment change with `:02000002SSSSCC` (segment = `(address - address %
///   0xFFF0) / 16`, HxD's scheme), the 32-bit one with `:02000004UUUUCC`; ends with `:00000001FF`.
/// - S-Records: `S00600004844521B` ("HDR") header, S1/S2/S3 data records, and the fixed
///   terminator `S9030000FC` / `S804000000FB` / `S70500000000FA`; no S5 count record.
public enum RecordExporter {
    public static func exportIntelHex(_ snapshot: ByteSnapshot, range: Range<UInt64>, variant: IntelHexVariant,
                                      options: RecordExportOptions = .init(),
                                      isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in },
                                      to sink: (String) throws -> Void) throws {
        if let end = SpanReader.definedEnd(snapshot, in: range), end > variant.addressLimit {
            throw ExportError.addressRangeExceeded(format: variant.displayName, limit: variant.addressLimit)
        }
        let perLine = UInt64(min(max(options.bytesPerLine, 1), 255))
        let lineBreak = options.lineBreak
        try withoutActuallyEscaping(sink) { sink in
            var out = ChunkWriter(sink: sink)
            var lastUpper: UInt64?

            func extended(type: UInt8, value: UInt64) throws {
                let sum = 2 + Int(type) + Int(value >> 8 & 0xFF) + Int(value & 0xFF)
                try out.write(":020000")
                out.writeHex(type)
                out.writeHex(UInt8(value >> 8 & 0xFF))
                out.writeHex(UInt8(value & 0xFF))
                out.writeHex(UInt8(truncatingIfNeeded: 0x100 - (sum & 0xFF)))
                try out.write(lineBreak)
            }

            func record(_ address: UInt64, _ data: ArraySlice<UInt8>) throws {
                let field: UInt64
                switch variant {
                case .bits16:
                    field = address
                case .bits20:
                    field = address % 0xFFF0
                    let segment = (address - field) / 16
                    if segment != lastUpper {
                        try extended(type: 0x02, value: segment)
                        lastUpper = segment
                    }
                case .bits32:
                    field = address & 0xFFFF
                    if address >> 16 != lastUpper {
                        try extended(type: 0x04, value: address >> 16)
                        lastUpper = address >> 16
                    }
                }
                var sum = data.count + Int(field >> 8) + Int(field & 0xFF)
                try out.write(":")
                out.writeHex(UInt8(data.count))
                out.writeHex(UInt8(field >> 8))
                out.writeHex(UInt8(field & 0xFF))
                out.writeHex(0)
                for b in data {
                    out.writeHex(b)
                    sum += Int(b)
                }
                out.writeHex(UInt8(truncatingIfNeeded: 0x100 - (sum & 0xFF)))
                try out.write(lineBreak)
            }

            // Records never cross a 64 KiB window of their 16-bit address field.
            var assembler = RecordAssembler { address in
                let field = variant == .bits20 ? address % 0xFFF0 : address & 0xFFFF
                return min(perLine - address % perLine, 0x1_0000 - field)
            }
            try SpanReader.forEachSpan(snapshot, in: range, isCancelled: isCancelled, progress: progress) { offset, _, bytes in
                if let bytes { try assembler.feed(offset, bytes, emit: record) }
            }
            try assembler.finish(emit: record)
            try out.write(":00000001FF" + lineBreak)
            try out.flush()
        }
    }

    public static func exportSRecord(_ snapshot: ByteSnapshot, range: Range<UInt64>, variant: SRecordVariant,
                                     options: RecordExportOptions = .init(),
                                     isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in },
                                     to sink: (String) throws -> Void) throws {
        if let end = SpanReader.definedEnd(snapshot, in: range), end > variant.addressLimit {
            throw ExportError.addressRangeExceeded(format: variant.displayName, limit: variant.addressLimit)
        }
        let perLine = UInt64(min(max(options.bytesPerLine, 1), 250))
        let lineBreak = options.lineBreak
        let width = variant.addressBytes
        try withoutActuallyEscaping(sink) { sink in
            var out = ChunkWriter(sink: sink)
            try out.write("S00600004844521B" + lineBreak)

            func record(_ address: UInt64, _ data: ArraySlice<UInt8>) throws {
                let count = data.count + width + 1
                var sum = count
                try out.write(variant.dataType)
                out.writeHex(UInt8(count))
                for i in stride(from: width - 1, through: 0, by: -1) {
                    let b = UInt8(truncatingIfNeeded: address >> (8 * UInt64(i)))
                    out.writeHex(b)
                    sum += Int(b)
                }
                for b in data {
                    out.writeHex(b)
                    sum += Int(b)
                }
                out.writeHex(UInt8(truncatingIfNeeded: 0xFF - (sum & 0xFF)))
                try out.write(lineBreak)
            }

            var assembler = RecordAssembler { address in perLine - address % perLine }
            try SpanReader.forEachSpan(snapshot, in: range, isCancelled: isCancelled, progress: progress) { offset, _, bytes in
                if let bytes { try assembler.feed(offset, bytes, emit: record) }
            }
            try assembler.finish(emit: record)
            try out.write(variant.terminator + lineBreak)
            try out.flush()
        }
    }
}

/// Cuts a stream of defined chunks into records: a record ends at a gap or when it reaches the
/// length `limit(start)` allows for its start address.
struct RecordAssembler {
    let limit: (UInt64) -> UInt64
    private var start: UInt64 = 0
    private var bytes: [UInt8] = []

    init(limit: @escaping (UInt64) -> UInt64) {
        self.limit = limit
        bytes.reserveCapacity(256)
    }

    mutating func feed(_ offset: UInt64, _ chunk: UnsafeRawBufferPointer,
                       emit: (UInt64, ArraySlice<UInt8>) throws -> Void) throws {
        if !bytes.isEmpty && start + UInt64(bytes.count) != offset { try finish(emit: emit) }
        var i = 0
        while i < chunk.count {
            if bytes.isEmpty { start = offset + UInt64(i) }
            let room = Int(limit(start)) - bytes.count
            let n = min(room, chunk.count - i)
            bytes.append(contentsOf: chunk[i..<i + n])
            i += n
            if bytes.count == Int(limit(start)) { try finish(emit: emit) }
        }
    }

    mutating func finish(emit: (UInt64, ArraySlice<UInt8>) throws -> Void) throws {
        guard !bytes.isEmpty else { return }
        try emit(start, bytes[...])
        bytes.removeAll(keepingCapacity: true)
    }
}
