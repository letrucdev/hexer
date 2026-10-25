import Foundation

/// How rows are laid out in the editor-view, HTML, RTF and TeX exports (HxD takes these from the
/// editor's current settings).
public struct ExportLayout: Equatable, Sendable {
    public var bytesPerRow: Int
    public var groupSize: Int
    public var columns: VisibleColumns
    public var offsetBase: NumberBase
    public var offsetDigits: Int
    public var encoding: TextEncoding
    public var uppercase: Bool
    /// Used by the editor view and the hex-values/decoded-text exports; HTML, RTF and TeX always
    /// use HxD's CRLF.
    public var lineBreak: String

    public init(bytesPerRow: Int = 16, groupSize: Int = 1, columns: VisibleColumns = .hexAndText,
                offsetBase: NumberBase = .hexadecimal, offsetDigits: Int = 8, encoding: TextEncoding = .windowsLatin1,
                uppercase: Bool = true, lineBreak: String = "\r\n") {
        self.bytesPerRow = max(1, bytesPerRow)
        self.groupSize = max(1, groupSize)
        self.columns = columns
        self.offsetBase = offsetBase
        self.offsetDigits = max(1, offsetDigits)
        self.encoding = encoding
        self.uppercase = uppercase
        self.lineBreak = lineBreak
    }
}

/// Colors and font of the HTML, RTF and TeX exports. Defaults are HxD's default theme: white
/// background, offsets in #0000BF, data in the black window text color, Courier New 10.
public struct ExportStyle: Equatable, Sendable {
    public var backgroundColor: RGBColor
    public var offsetColor: RGBColor
    /// Color of the hex and text columns (HxD uses the editor font's color).
    public var textColor: RGBColor
    public var fontName: String
    /// In points: RTF `\fs` is twice this, TeX uses it as the document class size.
    public var fontSize: Int
    /// TeX page margin (`geometry` package).
    public var texMarginCentimeters: Int

    public init(backgroundColor: RGBColor = .white, offsetColor: RGBColor = RGBColor(0x0000BF),
                textColor: RGBColor = .black, fontName: String = "Courier New", fontSize: Int = 10,
                texMarginCentimeters: Int = 2) {
        self.backgroundColor = backgroundColor
        self.offsetColor = offsetColor
        self.textColor = textColor
        self.fontName = fontName
        self.fontSize = fontSize
        self.texMarginCentimeters = texMarginCentimeters
    }
}

/// The formatted "Export/Copy as" formats that print rows like the editor.
public enum FormattedFormat: String, CaseIterable, Sendable {
    /// Plain text: `Offset(h) 00 01 …`, a blank line, then `00000000  4D 5A …  MZ..`.
    case editorView
    case html
    case rtf
    case tex

    public var displayName: String {
        switch self {
        case .editorView: "Editor view"
        case .html: "HTML"
        case .rtf: "Rich Text Format"
        case .tex: "TeX"
        }
    }

    public var fileExtension: String {
        switch self {
        case .editorView: "txt"
        case .html: "html"
        case .rtf: "rtf"
        case .tex: "tex"
        }
    }
}

/// Editor view, HTML, RTF and TeX exports with HxD 2.5's templates.
///
/// Rows are aligned to `bytesPerRow` in document offsets; a range starting or ending mid-row
/// leaves the missing bytes blank, so columns stay aligned. Undefined or unreadable bytes print
/// as `??` in the hex column and `?` in the text column (HxD refuses such ranges; see
/// `ExportText.containsUndefined`). Titles are escaped for the target format (HxD inserts them
/// verbatim).
///
/// TeX output uses `\usepackage[ansinew]{inputenc}` like HxD, so non-ASCII text-column
/// characters need the file to be written in Windows-1252.
public enum FormattedExporter {
    /// - Parameters:
    ///   - folds: Row-aligned byte ranges (sorted, non-overlapping) whose rows are left out, as
    ///     the editor folds undefined sections; each is replaced by one line holding its offset
    ///     and the text of `foldLine` for the bytes left out.
    public static func export(_ snapshot: ByteSnapshot, range: Range<UInt64>, format: FormattedFormat,
                              layout: ExportLayout = .init(), style: ExportStyle = .init(), title: String = "",
                              folds: [Range<UInt64>] = [], foldLine: (Range<UInt64>) -> String = { _ in "" },
                              isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in },
                              to sink: (String) throws -> Void) throws {
        let dialect = Dialect(format: format, layout: layout, style: style)
        try withoutActuallyEscaping(sink) { sink in
            var out = ChunkWriter(sink: sink)
            try out.write(dialect.documentStart(title: title))
            try writeRows(snapshot, range: range, dialect: dialect, layout: layout, folds: folds, foldLine: foldLine,
                          out: &out, isCancelled: isCancelled, progress: progress)
            try out.write(dialect.documentEnd(fragmentMarkers: false))
            try out.flush()
        }
    }

    /// HTML in the Windows "HTML Format" clipboard layout (`Version:0.9 StartHTML:…` header and
    /// `<!--StartFragment-->`/`<!--EndFragment-->` markers), as HxD copies it. Offsets count UTF-8
    /// bytes. The result is built in memory.
    public static func htmlClipboard(_ snapshot: ByteSnapshot, range: Range<UInt64>, layout: ExportLayout = .init(),
                                     style: ExportStyle = .init(), title: String = "",
                                     isCancelled: () -> Bool = { false },
                                     progress: (Double) -> Void = { _ in }) throws -> String {
        let dialect = Dialect(format: .html, layout: layout, style: style)
        var body = ""
        try withoutActuallyEscaping({ (s: String) in body += s }) { sink in
            var out = ChunkWriter(sink: sink)
            try writeRows(snapshot, range: range, dialect: dialect, layout: layout, out: &out,
                          isCancelled: isCancelled, progress: progress)
            try out.flush()
        }
        let head = dialect.htmlHead(title: title) + "<!--StartFragment-->"
        let fragment = dialect.htmlBodyStart(title: title) + body + Dialect.htmlGeneratorInfo
        let tail = "<!--EndFragment-->" + Dialect.htmlEnd
        let headerLength = 105 // the header below with 10-digit numbers
        let startFragment = headerLength + head.utf8.count
        let endFragment = startFragment + fragment.utf8.count
        let endHTML = endFragment + tail.utf8.count
        func n(_ v: Int) -> String { String(format: "%010d", v) }
        let header = "Version:0.9\r\nStartHTML:\(n(headerLength))\r\nEndHTML:\(n(endHTML))\r\nStartFragment:\(n(startFragment))\r\nEndFragment:\(n(endFragment))\r\n"
        return header + head + fragment + tail
    }

    // MARK: - Rows

    private static func writeRows(_ snapshot: ByteSnapshot, range: Range<UInt64>, dialect: Dialect, layout: ExportLayout,
                                  folds: [Range<UInt64>] = [], foldLine: (Range<UInt64>) -> String = { _ in "" },
                                  out: inout ChunkWriter, isCancelled: () -> Bool, progress: (Double) -> Void) throws {
        let renderer = RowRenderer(layout: layout)
        try out.write(dialect.headerRow(dialect.escape(renderer.headerRow())))
        let separator = dialect.escape("  ")
        let bpr = UInt64(layout.bytesPerRow)
        var rowStart: UInt64 = 0
        var firstColumn = 0
        var bytes: [UInt8] = []
        var undefined: [Bool] = []
        bytes.reserveCapacity(layout.bytesPerRow)
        undefined.reserveCapacity(layout.bytesPerRow)

        func emit() throws {
            guard !bytes.isEmpty else { return }
            let offset = dialect.offsetColumn(dialect.escape(renderer.offset(rowStart)))
            var line = offset + separator
            switch layout.columns {
            case .hexAndText:
                line += dialect.hexColumn(dialect.escape(renderer.hex(bytes, undefined, column: firstColumn)))
                line += separator
                line += dialect.textColumn(dialect.escape(renderer.text(bytes, undefined, column: firstColumn)))
            case .hex:
                line += dialect.hexColumn(dialect.escape(renderer.hex(bytes, undefined, column: firstColumn)))
            case .text:
                line += dialect.textColumn(dialect.escape(renderer.text(bytes, undefined, column: firstColumn)))
            }
            try out.write(line + dialect.lineBreak)
            bytes.removeAll(keepingCapacity: true)
            undefined.removeAll(keepingCapacity: true)
        }

        /// Appends `n` bytes at `offset` (from `source`, or undefined when nil).
        func append(_ offset: UInt64, _ n: UInt64, _ source: UnsafeRawBufferPointer?) throws {
            var pos = offset
            var i = 0
            while pos < offset + n {
                let column = Int(pos % bpr)
                if bytes.isEmpty || rowStart != pos - UInt64(column) {
                    try emit()
                    rowStart = pos - UInt64(column)
                    firstColumn = column
                }
                let take = Int(min(UInt64(layout.bytesPerRow - column), offset + n - pos))
                if let source {
                    bytes.append(contentsOf: source[i..<i + take])
                    undefined.append(contentsOf: repeatElement(false, count: take))
                } else {
                    bytes.append(contentsOf: repeatElement(0, count: take))
                    undefined.append(contentsOf: repeatElement(true, count: take))
                }
                pos += UInt64(take)
                i += take
                if firstColumn + bytes.count == layout.bytesPerRow { try emit() }
            }
        }

        var cursor = range.lowerBound
        for fold in folds where fold.overlaps(range) {
            let hidden = max(cursor, fold.lowerBound)..<min(range.upperBound, fold.upperBound)
            if cursor < hidden.lowerBound {
                try SpanReader.forEachSpan(snapshot, in: cursor..<hidden.lowerBound, isCancelled: isCancelled, progress: progress) {
                    try append($0, $1, $2)
                }
            }
            try emit()
            let line = dialect.offsetColumn(dialect.escape(renderer.offset(hidden.lowerBound))) + separator + dialect.escape(foldLine(hidden))
            try out.write(line + dialect.lineBreak)
            cursor = hidden.upperBound
        }
        if cursor < range.upperBound {
            try SpanReader.forEachSpan(snapshot, in: cursor..<range.upperBound, isCancelled: isCancelled, progress: progress) {
                try append($0, $1, $2)
            }
        }
        try emit()
    }
}

/// Builds the plain text of the offset, hex and text columns like HxD's editor.
struct RowRenderer {
    let layout: ExportLayout
    let table: EncodingTable
    let hexDigits: [UInt8]

    init(layout: ExportLayout) {
        self.layout = layout
        table = layout.encoding.table
        hexDigits = layout.uppercase ? Hex.upperASCII : Hex.lowerASCII
    }

    func offset(_ value: UInt64) -> String {
        layout.offsetBase.format(value, minDigits: layout.offsetDigits, uppercase: layout.uppercase)
    }

    /// `Offset(h)` centred over the offset column, then the column numbers of the hex column.
    func headerRow() -> String {
        var field = Array(repeating: Character(" "), count: layout.offsetDigits + 2)
        let title = Array("Offset(\(layout.offsetBase.suffix))")
        // Delphi's Delete + Insert at a 1-based index, as HxD overlays the title.
        let index = (layout.offsetDigits - title.count) / 2 + 1
        if index >= 1 && index <= field.count {
            field.removeSubrange(index - 1..<min(index - 1 + title.count, field.count))
        }
        let at = min(max(index, 1), field.count + 1) - 1
        field.insert(contentsOf: title, at: at)
        var header = String(field)
        if layout.columns.showsHex {
            let g = layout.groupSize
            let gap = String(repeating: " ", count: (g - 1) * 2 + 1)
            let groups = layout.bytesPerRow / g
            header += (0..<groups).map {
                layout.offsetBase.format(UInt64($0 * g), minDigits: 2, uppercase: layout.uppercase)
            }.joined(separator: gap)
        } else {
            while header.last == " " { header.removeLast() }
        }
        return header
    }

    /// The hex column for bytes starting at `column`, padded to the full row width when the text
    /// column follows.
    func hex(_ bytes: [UInt8], _ undefined: [Bool], column: Int) -> String {
        let bpr = layout.bytesPerRow
        var out: [UInt8] = []
        if column > 0 { out += hexRun(nil, nil, column: 0, count: column, keepTrailing: true) }
        let last = column + bytes.count - 1
        let keep = !(last == bpr - 1 || layout.columns == .hex)
        out += hexRun(bytes, undefined, column: column, count: bytes.count, keepTrailing: keep)
        if last < bpr - 1 && layout.columns == .hexAndText {
            out += hexRun(nil, nil, column: last + 1, count: bpr - last - 1, keepTrailing: false)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// HxD's hex formatting of `count` bytes from `column`: groups of `groupSize` bytes, each
    /// followed by a space; the trailing space is dropped unless `keepTrailing` (or the run ends
    /// inside a group). Without bytes the run is blank.
    func hexRun(_ bytes: [UInt8]?, _ undefined: [Bool]?, column: Int, count: Int, keepTrailing: Bool) -> [UInt8] {
        guard count > 0 else { return [] }
        let g = layout.groupSize
        let c0 = column % g
        let head = c0 > 0 ? min(count, g - c0) : 0
        let tail = (count - head) % g
        var width = (count - head - tail) / g * (2 * g + 1)
        var endsOnGroup = true
        if head > 0 {
            width += head * 2
            if c0 + head == g { width += 1 } else { endsOnGroup = false }
        }
        if tail > 0 {
            width += tail * 2
            endsOnGroup = false
        }
        var out = [UInt8](repeating: 0x20, count: width)
        if let bytes {
            for i in 0..<count {
                let p = 2 * i + (i + c0) / g
                if undefined?[i] == true {
                    out[p] = 0x3F
                    out[p + 1] = 0x3F
                } else {
                    out[p] = hexDigits[Int(bytes[i] >> 4)]
                    out[p + 1] = hexDigits[Int(bytes[i] & 0xF)]
                }
            }
        }
        if !keepTrailing && endsOnGroup { out.removeLast() }
        return out
    }

    /// The text column: blanks for the columns before `column`, then the decoded characters.
    func text(_ bytes: [UInt8], _ undefined: [Bool], column: Int) -> String {
        var s = String(repeating: " ", count: column)
        for i in bytes.indices { s.append(undefined[i] ? "?" : table.display[Int(bytes[i])]) }
        return s
    }
}

/// The format-specific wrapping of HxD's formatted exporters.
private struct Dialect {
    let format: FormattedFormat
    let layout: ExportLayout
    let style: ExportStyle

    var lineBreak: String {
        switch format {
        case .editorView: layout.lineBreak
        case .html: "\r\n"
        case .rtf: "\r\n\\par "
        case .tex: "\\\\\r\n"
        }
    }

    func documentStart(title: String) -> String {
        switch format {
        case .editorView: ""
        case .html: htmlHead(title: title) + htmlBodyStart(title: title)
        case .rtf: rtfHeader(title: title)
        case .tex: texHeader(title: title)
        }
    }

    func documentEnd(fragmentMarkers: Bool) -> String {
        switch format {
        case .editorView: ""
        case .html: Self.htmlGeneratorInfo + (fragmentMarkers ? "<!--EndFragment-->" : "") + Self.htmlEnd
        case .rtf: "}"
        case .tex: "\r\n\\end{ttfamily}\r\n\\end{document}"
        }
    }

    func headerRow(_ row: String) -> String {
        switch format {
        case .editorView: row + lineBreak + lineBreak
        case .html: "<span class=\"offsetheader\">" + row + "</span>" + lineBreak
        case .rtf: "\\cf\(rtfIndex(style.offsetColor)) \\sa\(style.fontSize / 2 * 20) " + row + "\\par\\pard\r\n"
        case .tex: "\\textcolor[rgb]{\(texColor(style.offsetColor))}{" + row + "\\vspace*{0.5em}}" + lineBreak
        }
    }

    func offsetColumn(_ s: String) -> String { column(s, class: "offsetcol", color: style.offsetColor) }
    func hexColumn(_ s: String) -> String { column(s, class: "hexcol", color: style.textColor) }
    func textColumn(_ s: String) -> String { column(s, class: "textcol", color: style.textColor) }

    private func column(_ s: String, class name: String, color: RGBColor) -> String {
        switch format {
        case .editorView: s
        case .html: "<span class=\"\(name)\">" + s + "</span>"
        case .rtf: "\\cf\(rtfIndex(color)) " + s
        case .tex: "\\textcolor[rgb]{\(texColor(color))}{" + s + "}"
        }
    }

    func escape(_ s: String) -> String {
        switch format {
        case .editorView:
            return s
        case .html:
            var out = ""
            for c in s {
                switch c {
                case "\"": out += "&quot;"
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                default: out.append(c)
                }
            }
            return out
        case .rtf:
            var out = ""
            for unit in s.utf16 {
                switch unit {
                case 0x5C: out += "\\\\"
                case 0x7B: out += "\\{"
                case 0x7D: out += "\\}"
                case 0x80...: out += "\\u\(Int16(bitPattern: unit))?"
                default: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
                }
            }
            return out
        case .tex:
            var out = ""
            for c in s { out += Self.texSpecial[c] ?? String(c) }
            return out
        }
    }

    // MARK: HTML

    static let htmlGeneratorInfo = "</pre>\r\n<p class=\"generatorinfo\">Generated by <a href=\"https://mh-nexus.de/hxd/\" class=\"generatorlink\">HxD</a></p>\r\n"
    static let htmlEnd = "</body>\r\n</html>\r\n"

    func htmlHead(title: String) -> String {
        let offset = style.offsetColor.hexString, data = style.textColor.hexString
        return "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">\r\n<html>\r\n<head>\r\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\r\n<meta name=\"Generator\" content=\"HxD\">\r\n<title>\(escape(title))</title>\r\n<style type=\"text/css\">\r\n  body { background-color:\(style.backgroundColor.hexString) }\r\n  .offsetheader { color:\(offset); line-height:200% }\r\n  .offsetcol { color:\(offset) }\r\n  .hexcol { color:\(data) }\r\n  .textcol { color:\(data) }\r\n  .generatorinfo { font:8pt Verdana, Arial, Helvetica, sans-serif; color:#999999 }\r\n  .generatorlink { font-weight:bold; text-decoration:underline; color:#999999 }\r\n</style>\r\n</head>\r\n<body>\r\n"
    }

    func htmlBodyStart(title: String) -> String {
        "<h1>" + escape(title) + "</h1>\r\n<pre>\r\n"
    }

    // MARK: RTF

    /// Color table entries: background, data, offsets (HxD's order); `\cfN` refers to the first
    /// equal entry.
    private var rtfColors: [RGBColor] { [style.backgroundColor, style.textColor, style.offsetColor] }

    private func rtfIndex(_ color: RGBColor) -> Int { rtfColors.firstIndex(of: color) ?? 0 }

    private func rtfHeader(title: String) -> String {
        var s = "{\\rtf1\\ansi\\ansicpg-535\\uc1\\deff0\\deftab720{\\fonttbl{\\f0\\fmodern \(escape(style.fontName));}}\r\n"
        s += "{\\colortbl"
        for c in rtfColors { s += "\\red\(c.red)\\green\(c.green)\\blue\(c.blue);" }
        s += "}\r\n"
        s += "{\\info{\\author HxD}\r\n{\\doccomm https://mh-nexus.de/hxd/}\r\n{\\title \(escape(title))}}\r\n"
        s += "\\deflang1031\\pard\\plain\\f0\\fs\(style.fontSize * 2) \\cb\(rtfIndex(style.backgroundColor)) \r\n"
        return s
    }

    // MARK: TeX

    /// HxD's escapes for characters TeX treats specially (`%` is written as `\%`; HxD's literal
    /// is `\%<y`, apparently a typo).
    static let texSpecial: [Character: String] = [
        "{": "\\{", "}": "\\}", "\\": "\\BS ", "~": "\\TLD ", "^": "\\CIR ", " ": "\\SPC ", "-": "\\HYP ",
        "\"": "\\QOT ", "@": "$@$", "$": "\\$", "&": "\\&", "<": "\\LOW ", ">": "\\GRE ", "_": "\\_", "#": "\\#",
        "%": "\\%", "\u{A4}": "\\CURR ", "\u{20AC}": "\\EURcr ", "\u{B4}": "\\textasciiacute", "\u{17D}": "\\v{Z}",
        "\u{17E}": "\\v{z}", "\u{AD}": "\\mbox{\\char 173}", "\u{2013}": "\\texttwelveudash ",
        "\u{2014}": "\\textthreequartersemdash ",
    ]

    /// `r,g,b` with each component formatted like Delphi's `%1.2g` of `value / 255`.
    private func texColor(_ c: RGBColor) -> String {
        [c.red, c.green, c.blue].map { String(format: "%1.2g", Double($0) / 255) }.joined(separator: ",")
    }

    private func texHeader(title: String) -> String {
        var titleText = ""
        for c in title { titleText += c == " " ? " " : (Self.texSpecial[c] ?? String(c)) }
        return "% Generated by HxD https://mh-nexus.de/hxd/\r\n\r\n\\documentclass[a4paper, \(style.fontSize)pt]{article}\r\n\\usepackage[a4paper, margin=\(style.texMarginCentimeters)cm]{geometry}\r\n\\usepackage[T1]{fontenc}\r\n\\usepackage{color}\r\n\\usepackage{alltt}\r\n\\usepackage{times}\r\n\\usepackage{textcomp}\r\n\\usepackage{marvosym}\r\n\\usepackage[ansinew]{inputenc}\r\n"
            + "%% Special Characters\r\n\\newcommand\\SPC{\\hspace*{0.6em}}\r\n\\newcommand\\BS{\\mbox{\\char 92}}\r\n\\newcommand\\TLD{\\mbox{\\char 126}}\r\n\\newcommand\\CIR{\\mbox{\\char 94}}\r\n\\newcommand\\HYP{\\mbox{\\char 45}}\r\n\\newcommand\\QOT{\\mbox{\\char 34}}\r\n\\newcommand\\CURR{\\textcurrency}\r\n\\newcommand\\LOW{\\mbox{\\char 60}}\r\n\\newcommand\\GRE{\\mbox{\\char 62}}\r\n\\DeclareInputText{172}{\\textlnot}\r\n"
            + "\r\n\\title{\(titleText)}\r\n\\begin{document}\r\n\\begin{ttfamily}\r\n\\noindent\r\n"
    }
}
