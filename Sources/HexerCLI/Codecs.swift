import Foundation
import HexerCore

/// The `export --format` names.
private enum ExportFormat {
    case intelHex(IntelHexVariant)
    case sRecord(SRecordVariant)
    case source(SourceLanguage)
    case formatted(FormattedFormat)
    case hexValues
    case text

    static let byName: [(String, ExportFormat)] = [
        ("ihex16", .intelHex(.bits16)), ("ihex20", .intelHex(.bits20)), ("ihex32", .intelHex(.bits32)),
        ("s19", .sRecord(.s19)), ("s28", .sRecord(.s28)), ("s37", .sRecord(.s37)),
        ("c", .source(.c)), ("pascal", .source(.pascal)), ("csharp", .source(.cSharp)), ("java", .source(.java)),
        ("vbnet", .source(.visualBasic)), ("purebasic", .source(.pureBasic)),
        ("editor", .formatted(.editorView)), ("html", .formatted(.html)), ("rtf", .formatted(.rtf)), ("tex", .formatted(.tex)),
        ("hex", .hexValues), ("text", .text),
    ]
}

/// `export --format FMT [--range RANGE] [--per-line N] [--lf] FILE [-o OUT]`
///
/// Writes HxD's "Export" formats with HxD's defaults (CRLF line breaks, 32 bytes per record,
/// 80-column source code, 16 bytes per editor row; `--per-line` overrides the count, `--lf` the line
/// break). Output goes to OUT or stdout, as UTF-8 except TeX, which is Windows-1252 as its
/// `inputenc` declares. Source code headers name FILE; formatted exports use its name as title.
func export(_ args: [String]) {
    let names = ExportFormat.byName.map(\.0).joined(separator: "|")
    let usage = "export --format \(names) [--range RANGE] [--per-line N] [--lf] FILE [-o OUT]"
    let a = Arguments(args, command: "export", flags: ["--lf"], options: ["--format", "--range", "--per-line", "-o"])
    let path = a.expect(1, usage: usage)[0]
    guard let name = a.value("--format") else { fail("usage: hexer-cli \(usage)") }
    guard let format = ExportFormat.byName.first(where: { $0.0 == name.lowercased() })?.1 else {
        fail("export: unknown format \(name) (\(names))")
    }
    let snap = openSnapshot(path)
    let range = parseRange(a.value("--range"), length: snap.length)
    let lineBreak = a.flag("--lf") ? "\n" : "\r\n"
    let perLine = a.number("--per-line").map { Int(clamping: $0) }
    let out = Output.to(a.value("-o"))
    var sink: (String) -> Void = { out.write($0) }
    if case .formatted(.tex) = format {
        sink = { s in out.write(bytes: s.data(using: .windowsCP1252).map(Array.init) ?? Array(s.utf8)) }
    }
    attempt("export") {
        switch format {
        case .intelHex(let variant):
            try RecordExporter.exportIntelHex(snap, range: range, variant: variant,
                                              options: RecordExportOptions(bytesPerLine: perLine ?? 32, lineBreak: lineBreak), to: sink)
        case .sRecord(let variant):
            try RecordExporter.exportSRecord(snap, range: range, variant: variant,
                                             options: RecordExportOptions(bytesPerLine: perLine ?? 32, lineBreak: lineBreak), to: sink)
        case .source(let language):
            let options = SourceCodeOptions(lineWrap: perLine.map { .bytesPerLine($0) } ?? .charactersPerLine(80),
                                            sourceName: path, lineBreak: lineBreak)
            try SourceCodeExporter.export(snap, range: range, language: language, options: options, to: sink)
        case .formatted(let f):
            let layout = ExportLayout(bytesPerRow: perLine ?? 16, lineBreak: lineBreak)
            try FormattedExporter.export(snap, range: range, format: f, layout: layout,
                                         title: URL(fileURLWithPath: path).lastPathComponent, to: sink)
        case .hexValues:
            try PlainExporter.exportHexValues(snap, range: range, options: HexValuesOptions(bytesPerLine: perLine ?? 0, lineBreak: lineBreak),
                                              to: sink)
        case .text:
            try PlainExporter.exportDecodedText(snap, range: range, encoding: .windowsLatin1, to: sink)
        }
    }
    out.close()
}

/// `import [--format ihex|srec|etl] [--fill-gaps BYTE] IN -o OUT`
///
/// Parses an Intel Hex, Motorola S-Record or ETL Extended file (format detected from the first
/// character when not given) and writes the image from address 0 to its last byte, with gaps filled
/// with BYTE (default 0), via `FileWriter`.
func importRecords(_ args: [String]) {
    let usage = "import [--format ihex|srec|etl] [--fill-gaps BYTE] IN -o OUT"
    let a = Arguments(args, command: "import", options: ["--format", "--fill-gaps", "-o"])
    let path = a.expect(1, usage: usage)[0]
    guard let outPath = a.value("-o") else { fail("usage: hexer-cli \(usage)") }
    let fill = a.number("--fill-gaps") ?? 0
    guard fill <= 0xFF else { fail("import: --fill-gaps must be a byte value") }
    let data = attempt("import") { try Data(contentsOf: URL(fileURLWithPath: path)) }
    let format: HexRecordFormat
    switch a.value("--format")?.lowercased() {
    case "ihex", "intelhex", "hex": format = .intelHex
    case "srec", "s19", "s28", "s37", "mot": format = .motorolaSRecord
    case "etl", "eef": format = .etlExtended
    case nil:
        guard let detected = RecordImporter.detectFormat(data) else { fail("import: cannot detect the format of \(path); use --format") }
        format = detected
    case let other?: fail("import: unknown format \(other) (ihex, srec, etl)")
    }
    let image = attempt("import") {
        try RecordImporter.importRecords(data, format: format, fileName: URL(fileURLWithPath: path).lastPathComponent)
    }
    let registry = SourceRegistry()
    let gap = PieceRef.generator(registry.register(Generator.pattern([UInt8(fill)])))
    let pieces = image.pieces(registry: registry).map { $0.ref == .undefined ? Piece(gap, start: 0, length: $0.length) : $0 }
    writeSnapshot(EditableBuffer(pieces: pieces, registry: registry).snapshot(), to: outPath, command: "import")
}
