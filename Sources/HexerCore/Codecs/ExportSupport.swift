import Foundation

/// Errors raised by the exporters before any output is written.
public enum ExportError: Error, Equatable, Sendable, LocalizedError {
    /// The data reaches beyond the addresses the record format can express.
    case addressRangeExceeded(format: String, limit: UInt64)

    public var errorDescription: String? {
        switch self {
        case .addressRangeExceeded(let format, let limit):
            // HxD: 'The maximum supported file size (%s) of the "%s" file format was exceeded.\r\nChoose another format'
            "The maximum supported file size (\(ExportText.sizeString(limit))) of the \"\(format)\" file format was exceeded.\nChoose another format"
        }
    }
}

/// Text shared by the exporters.
public enum ExportText {
    /// HxD refuses formatted and source-code exports of ranges with undefined bytes with this
    /// message; Hexer's exporters render such bytes instead (see each exporter), so the app can
    /// show it when it prefers HxD's behaviour (check with `containsUndefined`).
    public static let undefinedDataMessage = "Exporting is not possible, as a part of the selected data is undefined"

    /// Whether any byte of `range` is undefined (a gap from an import) or unreadable.
    public static func containsUndefined(_ snapshot: ByteSnapshot, in range: Range<UInt64>) -> Bool {
        var found = false
        let range = clamp(range, snapshot.length)
        snapshot.tree.forEachPiece(in: range) { piece, _ in
            if piece.ref == .undefined { found = true }
            return !found
        }
        return found
    }

    /// Runs an exporter and returns its whole output, for clipboard copies and small ranges.
    public static func collect(_ export: (_ sink: (String) throws -> Void) throws -> Void) rethrows -> String {
        var text = ""
        try export { text += $0 }
        return text
    }

    public static func sizeString(_ bytes: UInt64) -> String {
        let units: [(UInt64, String)] = [(1 << 30, "GiB"), (1 << 20, "MiB"), (1 << 10, "KiB")]
        for (size, name) in units where bytes >= size && bytes % size == 0 { return "\(bytes / size) \(name)" }
        return "\(bytes) bytes"
    }

    static func clamp(_ range: Range<UInt64>, _ length: UInt64) -> Range<UInt64> {
        min(range.lowerBound, length)..<min(range.upperBound, length)
    }
}

/// An sRGB color for HTML, RTF and TeX exports.
public struct RGBColor: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xRRGGBB`.
    public init(_ rgb: UInt32) {
        self.init(red: UInt8(truncatingIfNeeded: rgb >> 16), green: UInt8(truncatingIfNeeded: rgb >> 8),
                  blue: UInt8(truncatingIfNeeded: rgb))
    }

    /// `#RRGGBB` with uppercase digits, as HxD writes CSS colors.
    public var hexString: String { "#" + Hex.upper[Int(red)] + Hex.upper[Int(green)] + Hex.upper[Int(blue)] }

    public static let white = RGBColor(0xFFFFFF)
    public static let black = RGBColor(0x000000)
}

/// Two-digit hex strings for every byte value.
enum Hex {
    static let upper: [String] = (0..<256).map { String(format: "%02X", $0) }
    static let lower: [String] = (0..<256).map { String(format: "%02x", $0) }
    static let upperASCII: [UInt8] = Array("0123456789ABCDEF".utf8)
    static let lowerASCII: [UInt8] = Array("0123456789abcdef".utf8)

    /// `value` as exactly `digits` uppercase hex digits (higher digits are dropped).
    static func digits(_ value: UInt64, _ digits: Int) -> String {
        var out = [UInt8](repeating: 0, count: digits)
        var v = value
        for i in stride(from: digits - 1, through: 0, by: -1) {
            out[i] = upperASCII[Int(v & 0xF)]
            v >>= 4
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Collects output and hands it to the caller's sink in chunks of about 64 KiB.
struct ChunkWriter {
    private let sink: (String) throws -> Void
    private var bytes: [UInt8] = []
    private let limit = 64 * 1024

    init(sink: @escaping (String) throws -> Void) {
        self.sink = sink
        bytes.reserveCapacity(limit + 1024)
    }

    mutating func write(_ s: String) throws {
        bytes.append(contentsOf: s.utf8)
        if bytes.count >= limit { try flush() }
    }

    /// Two hex digits for `byte`.
    mutating func writeHex(_ byte: UInt8, uppercase: Bool = true) {
        let table = uppercase ? Hex.upperASCII : Hex.lowerASCII
        bytes.append(table[Int(byte >> 4)])
        bytes.append(table[Int(byte & 0xF)])
    }

    mutating func flushIfNeeded() throws {
        if bytes.count >= limit { try flush() }
    }

    mutating func flush() throws {
        guard !bytes.isEmpty else { return }
        try sink(String(decoding: bytes, as: UTF8.self))
        bytes.removeAll(keepingCapacity: true)
    }
}

/// Walks a range of a snapshot as defined chunks and undefined gaps (unreadable bytes count as
/// undefined), with cancellation and progress reporting.
enum SpanReader {
    /// Calls `body` with consecutive spans covering `range`: defined spans of at most
    /// `chunkSize` bytes with their contents, undefined spans (any length) with `nil`.
    static func forEachSpan(_ snapshot: ByteSnapshot, in range: Range<UInt64>, chunkSize: Int = 1 << 20,
                            isCancelled: () -> Bool, progress: (Double) -> Void,
                            _ body: (_ offset: UInt64, _ length: UInt64, _ bytes: UnsafeRawBufferPointer?) throws -> Void) throws {
        let range = ExportText.clamp(range, snapshot.length)
        guard !range.isEmpty else { return }
        let total = Double(range.upperBound - range.lowerBound)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }

        func report(_ end: UInt64) throws {
            if isCancelled() { throw CancellationError() }
            progress(Double(end - range.lowerBound) / total)
        }

        func emitDefined(_ start: UInt64, _ end: UInt64) throws {
            var pos = start
            while pos < end {
                let n = Int(min(UInt64(chunkSize), end - pos))
                if snapshot.copyBytes(pos..<pos + UInt64(n), into: buffer) {
                    try body(pos, UInt64(n), UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
                } else {
                    // Some bytes could not be read: split by state.
                    let (bytes, states) = snapshot.read(pos..<pos + UInt64(n))
                    try bytes.withUnsafeBytes { raw in
                        var i = 0
                        while i < n {
                            let bad = states[i] == .undefined || states[i] == .unreadable
                            var j = i + 1
                            while j < n && (states[j] == .undefined || states[j] == .unreadable) == bad { j += 1 }
                            try body(pos + UInt64(i), UInt64(j - i), bad ? nil : UnsafeRawBufferPointer(rebasing: raw[i..<j]))
                            i = j
                        }
                    }
                }
                pos += UInt64(n)
                try report(pos)
            }
        }

        var pending: (start: UInt64, end: UInt64, defined: Bool)?
        func flush() throws {
            guard let p = pending else { return }
            pending = nil
            if p.defined {
                try emitDefined(p.start, p.end)
            } else {
                try body(p.start, p.end - p.start, nil)
                try report(p.end)
            }
        }

        try snapshot.tree.forEachPiece(in: range) { piece, offset in
            let defined = piece.ref != .undefined
            let end = offset + piece.length
            if let p = pending, p.defined == defined, p.end == offset {
                pending = (p.start, end, defined)
            } else {
                try flush()
                pending = (offset, end, defined)
            }
            return true
        }
        try flush()
    }

    /// The end of the last defined byte in `range`, or nil if there is none (pieces only, no reads).
    static func definedEnd(_ snapshot: ByteSnapshot, in range: Range<UInt64>) -> UInt64? {
        var end: UInt64?
        snapshot.tree.forEachPiece(in: ExportText.clamp(range, snapshot.length)) { piece, offset in
            if piece.ref != .undefined { end = offset + piece.length }
            return true
        }
        return end
    }
}
