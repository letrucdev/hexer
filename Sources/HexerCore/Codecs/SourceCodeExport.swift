/// The languages of HxD's "Export/Copy as" source code formats.
public enum SourceLanguage: String, CaseIterable, Sendable {
    case pascal, c, cSharp, java, visualBasic, pureBasic

    public var displayName: String {
        switch self {
        case .pascal: "Pascal"
        case .c: "C"
        case .cSharp: "C#"
        case .java: "Java"
        case .visualBasic: "Visual Basic .NET"
        case .pureBasic: "PureBasic"
        }
    }

    /// The default file name extension of HxD's save dialog.
    public var fileExtension: String {
        switch self {
        case .pascal: "pas"
        case .c: "c"
        case .cSharp: "cs"
        case .java: "java"
        case .visualBasic: "vb"
        case .pureBasic: "pb"
        }
    }

    /// One array element, e.g. `0x4D`, `$4D`, `(byte)0x4D`, `&H4D`.
    func element(_ b: UInt8) -> String {
        switch self {
        case .pascal, .pureBasic: "$" + Hex.upper[Int(b)]
        case .c, .cSharp: "0x" + Hex.upper[Int(b)]
        case .java: "(byte)0x" + Hex.upper[Int(b)]
        case .visualBasic: "&H" + Hex.upper[Int(b)]
        }
    }

    /// Text before the first element of each data line.
    var indent: String {
        switch self {
        case .pascal, .pureBasic: "  "
        case .c, .cSharp, .java, .visualBasic: "\t"
        }
    }

    var linePrefix: String { self == .pureBasic ? "Data.b " : "" }
    /// Text at the end of the declaration and of every data line (VB's line continuation).
    var lineSuffix: String { self == .visualBasic ? " _" : "" }
    var separator: String { ", " }
    /// The separator after the last element of a line that is not the last line.
    var lineEndSeparator: String { self == .pureBasic ? "" : "," }

    func comment(_ lines: [String]) -> [String] {
        lines.enumerated().map { i, line in
            let first = i == 0, last = i == lines.count - 1
            switch self {
            case .pascal: return (first ? "{ " : "  ") + line + (last ? " }" : "")
            case .c, .cSharp, .java: return (first ? "/* " : "   ") + line + (last ? " */" : "")
            case .visualBasic: return "' " + line
            case .pureBasic: return "; " + line
            }
        }
    }

    func declaration(count: Int, lineBreak: String) -> String {
        switch self {
        case .pascal: "RawData: array[0..\(count - 1)] of Byte = ("
        case .c: "unsigned char rawData[\(count)] = {"
        case .cSharp: "byte[] rawData = {"
        case .java: "byte rawData[] = {"
        case .visualBasic: "Dim rawData As Byte() = {"
        case .pureBasic: "#RawDataItemCount = \(count)" + lineBreak + lineBreak + "DataSection" + lineBreak + "  DS_RawData:"
        }
    }

    func footer(lineBreak: String) -> String {
        switch self {
        case .pascal: ");"
        case .c, .cSharp, .java: "};"
        case .visualBasic: "}"
        case .pureBasic:
            ["EndDataSection", "", "Structure RawDataArray", "  Items.b[#RawDataItemCount]", "EndStructure", "",
             "Define *rawData.RawDataArray = ?DS_RawData"].joined(separator: lineBreak)
        }
    }
}

/// Options for source code exports. Defaults are HxD's (Options ▸ Export: line break determined
/// by 80 characters per line).
public struct SourceCodeOptions: Equatable, Sendable {
    public enum LineWrap: Equatable, Sendable {
        /// A fixed number of array elements per line.
        case bytesPerLine(Int)
        /// As many elements as fit in this many columns (a tab counts as 4), as HxD computes it.
        case charactersPerLine(Int)
    }

    public var lineWrap: LineWrap
    /// First comment line, e.g. the document's path; HxD writes `<path> (<file date>)`.
    public var sourceName: String?
    /// Shown in parentheses after `sourceName` (alone if there is no name).
    public var timestamp: String?
    public var offsetBase: NumberBase
    public var offsetDigits: Int
    public var lineBreak: String

    public init(lineWrap: LineWrap = .charactersPerLine(80), sourceName: String? = nil, timestamp: String? = nil,
                offsetBase: NumberBase = .hexadecimal, offsetDigits: Int = 8, lineBreak: String = "\r\n") {
        self.lineWrap = lineWrap
        self.sourceName = sourceName
        self.timestamp = timestamp
        self.offsetBase = offsetBase
        self.offsetDigits = offsetDigits
        self.lineBreak = lineBreak
    }
}

/// Pascal, C, C#, Java, Visual Basic .NET and PureBasic array exports with HxD 2.5's templates:
///
///     /* file.bin (23.10.2026 12:00:00)
///        StartOffset(h): 00000000, EndOffset(h): 00000013, Length(h): 00000014 */
///
///     unsigned char rawData[20] = {
///     	0x4D, 0x5A, …, 0x00,
///     	0x00, …, 0xFF
///     };
///
/// Lines are counted from the start of the range. Undefined bytes are written as 0 (HxD refuses
/// such ranges; see `ExportText.containsUndefined`). An empty range produces no output.
public enum SourceCodeExporter {
    /// Array elements per line for `language` under `wrap` (HxD's default gives C 12, Pascal 15,
    /// Java 6, VB 12, PureBasic 14).
    public static func valuesPerLine(_ language: SourceLanguage, wrap: SourceCodeOptions.LineWrap) -> Int {
        switch wrap {
        case .bytesPerLine(let n):
            return max(1, n)
        case .charactersPerLine(let columns):
            let indentWidth = language.indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let available = columns - indentWidth - language.linePrefix.count - language.lineSuffix.count
            let element = language.element(0xFF).count
            let atEnd = element + language.lineEndSeparator.count
            let inLine = element + language.separator.count
            return available >= atEnd ? 1 + (available - atEnd) / inLine : 1
        }
    }

    public static func export(_ snapshot: ByteSnapshot, range: Range<UInt64>, language: SourceLanguage,
                              options: SourceCodeOptions = .init(),
                              isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in },
                              to sink: (String) throws -> Void) throws {
        let range = ExportText.clamp(range, snapshot.length)
        guard !range.isEmpty else { return }
        let count = range.upperBound - range.lowerBound
        let lb = options.lineBreak
        let perLine = UInt64(valuesPerLine(language, wrap: options.lineWrap))
        let elements = (0..<256).map { language.element(UInt8($0)) }

        try withoutActuallyEscaping(sink) { sink in
            var out = ChunkWriter(sink: sink)
            var lines: [String] = []
            switch (options.sourceName, options.timestamp) {
            case let (name?, time?): lines.append("\(name) (\(time))")
            case let (name?, nil): lines.append(name)
            case let (nil, time?): lines.append(time)
            case (nil, nil): break
            }
            let base = options.offsetBase
            func number(_ v: UInt64) -> String { base.format(v, minDigits: options.offsetDigits) }
            let s = base.suffix
            lines.append("StartOffset(\(s)): \(number(range.lowerBound)), EndOffset(\(s)): \(number(range.upperBound - 1)), Length(\(s)): \(number(count))")
            for line in language.comment(lines) { try out.write(line + lb) }
            try out.write(lb)
            try out.write(language.declaration(count: Int(clamping: count), lineBreak: lb) + language.lineSuffix + lb)

            var index: UInt64 = 0
            func element(_ b: UInt8) throws {
                if index % perLine == 0 { try out.write(language.indent + language.linePrefix) }
                try out.write(elements[Int(b)])
                index += 1
                if index == count {
                    try out.write(language.lineSuffix + lb)
                } else if index % perLine == 0 {
                    try out.write(language.lineEndSeparator + language.lineSuffix + lb)
                } else {
                    try out.write(language.separator)
                }
            }
            try SpanReader.forEachSpan(snapshot, in: range, isCancelled: isCancelled, progress: progress) { _, length, bytes in
                if let bytes {
                    for b in bytes { try element(b) }
                } else {
                    for _ in 0..<length { try element(0) }
                }
            }
            try out.write(language.footer(lineBreak: lb) + lb)
            try out.flush()
        }
    }
}
