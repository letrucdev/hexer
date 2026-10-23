/// Options for the "Hexadecimal values" export.
public struct HexValuesOptions: Equatable, Sendable {
    /// Between two values on a line.
    public var separator: String
    /// Values per line; 0 writes everything on one line.
    public var bytesPerLine: Int
    public var uppercase: Bool
    public var lineBreak: String

    public init(separator: String = " ", bytesPerLine: Int = 0, uppercase: Bool = true, lineBreak: String = "\r\n") {
        self.separator = separator
        self.bytesPerLine = max(0, bytesPerLine)
        self.uppercase = uppercase
        self.lineBreak = lineBreak
    }
}

/// The plain "Hexadecimal values" and "Decoded text" exports.
public enum PlainExporter {
    /// `4D 5A 90 00 …`: two digits per byte, `??` for undefined bytes. With `bytesPerLine` set,
    /// lines are counted from the start of the range and the last line has no line break.
    public static func exportHexValues(_ snapshot: ByteSnapshot, range: Range<UInt64>, options: HexValuesOptions = .init(),
                                       isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in },
                                       to sink: (String) throws -> Void) throws {
        let perLine = UInt64(options.bytesPerLine)
        try withoutActuallyEscaping(sink) { sink in
            var out = ChunkWriter(sink: sink)
            var index: UInt64 = 0
            func value(_ b: UInt8?) throws {
                if index > 0 {
                    try out.write(perLine > 0 && index % perLine == 0 ? options.lineBreak : options.separator)
                }
                if let b { out.writeHex(b, uppercase: options.uppercase) } else { try out.write("??") }
                index += 1
                try out.flushIfNeeded()
            }
            try SpanReader.forEachSpan(snapshot, in: range, isCancelled: isCancelled, progress: progress) { _, length, bytes in
                if let bytes {
                    for b in bytes { try value(b) }
                } else {
                    for _ in 0..<length { try value(nil) }
                }
            }
            try out.flush()
        }
    }

    /// The bytes decoded with `encoding`, one character per byte. Unfiltered (the default), control
    /// characters are kept and unassigned bytes become "."; filtered, the text column's "."
    /// placeholders are used. Undefined bytes become "?".
    public static func exportDecodedText(_ snapshot: ByteSnapshot, range: Range<UInt64>, encoding: TextEncoding,
                                         filtered: Bool = false,
                                         isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in },
                                         to sink: (String) throws -> Void) throws {
        let table = encoding.table
        try withoutActuallyEscaping(sink) { sink in
            var out = ChunkWriter(sink: sink)
            try SpanReader.forEachSpan(snapshot, in: range, chunkSize: 64 * 1024,
                                       isCancelled: isCancelled, progress: progress) { _, length, bytes in
                if let bytes {
                    try out.write(table.decode(bytes, filtered: filtered))
                } else {
                    var left = length
                    while left > 0 {
                        let n = min(left, 4096)
                        try out.write(String(repeating: "?", count: Int(n)))
                        left -= n
                    }
                }
            }
            try out.flush()
        }
    }
}
