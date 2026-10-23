import HexerCore

/// The datatype options shared by `find` and `replace`.
let searchFlags: Set<String> = ["--text", "--hex", "--int", "--float", "--utf16", "--case", "--be", "--signed", "--unsigned"]
let searchOptions: Set<String> = ["--width", "--type", "--encoding"]

/// The `SearchQuery` the datatype options describe (HxD's defaults otherwise: text, Windows-1252,
/// case-insensitive; integers of any width, little endian; Single floats).
func searchQuery(_ a: Arguments, pattern: String) -> SearchQuery {
    let types: [(String, SearchQuery.DataType)] = [("--text", .text), ("--hex", .hex), ("--int", .integer), ("--float", .float)]
    let chosen = types.filter { a.flag($0.0) }
    guard chosen.count <= 1 else { fail("\(a.command): choose one of --text, --hex, --int, --float") }
    let order: SearchQuery.ByteOrder = a.flag("--be") ? .bigEndian : .littleEndian
    var query = SearchQuery(chosen.first?.1 ?? .text, pattern: pattern)
    switch query.dataType {
    case .text:
        var encoding = TextEncoding.windowsLatin1
        if let name = a.value("--encoding") {
            guard let e = TextEncoding(rawValue: name.lowercased()) else {
                fail("\(a.command): unknown encoding \(name) (\(TextEncoding.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            encoding = e
        }
        query.text = .init(encoding: a.flag("--utf16") ? .utf16LittleEndian : .editor(encoding), caseSensitive: a.flag("--case"))
    case .hex:
        break
    case .integer:
        var width = SearchQuery.IntegerWidth.any
        if let w = a.value("--width") {
            guard let v = Int(w), v > 0, let iw = SearchQuery.IntegerWidth(rawValue: v) else {
                fail("\(a.command): --width must be 8, 16, 24, 32 or 64")
            }
            width = iw
        }
        let signedness: SearchQuery.Signedness = a.flag("--signed") ? .signed : a.flag("--unsigned") ? .unsigned : .either
        query.integer = .init(width: width, byteOrder: order, signedness: signedness)
    case .float:
        var type = SearchQuery.FloatType.single
        if let t = a.value("--type") {
            guard let ft = SearchQuery.FloatType(rawValue: t.lowercased()) else {
                fail("\(a.command): --type must be single, double, real48 or extended")
            }
            type = ft
        }
        query.float = .init(type: type, byteOrder: order)
    }
    return query
}

/// `find [type options] [--backward] [--from N] [--limit N] PATTERN FILE`
///
/// Prints one line per match, `OFFSET:MATCH`, with the decimal offset of the first byte. Text matches
/// are written as the raw matched bytes of the file, which is exactly `LC_ALL=C grep -obUa` output for
/// a case-sensitive pattern without newlines; other datatypes print the match as hex bytes
/// (`OFFSET:4D 5A`). Matches don't overlap: forward, each search resumes at the end of the previous
/// match (like grep), starting at `--from` (default 0). `--backward` lists them last first, each lying
/// entirely before the previous one, below `--from` (default: the end of the file).
func find(_ args: [String]) {
    let usage = "find [--text|--hex|--int|--float] [options] [--backward] [--from N] [--limit N] PATTERN FILE"
    let a = Arguments(args, command: "find", flags: searchFlags.union(["--backward"]),
                      options: searchOptions.union(["--from", "--limit"]))
    let p = a.expect(2, usage: usage)
    let snap = openSnapshot(p[1])
    let query = searchQuery(a, pattern: p[0])
    let compiled = attempt("find") { try SearchEngine.compile(query) }
    let limit = a.number("--limit").map { Int(clamping: $0) } ?? .max
    let out = Output()
    func emit(_ m: Range<UInt64>) {
        out.write("\(m.lowerBound):")
        let bytes = snap.bytes(m)
        if query.dataType == .text { out.write(bytes: bytes) } else { out.write(hexBytes(bytes)) }
        out.write("\n")
    }
    if a.flag("--backward") {
        var upper = min(a.number("--from") ?? snap.length, snap.length)
        var count = 0
        while count < limit, let hit = attempt("find", {
            try SearchEngine.findNext(in: snap, query: compiled, from: upper, direction: .backward, range: 0..<upper)
        }) {
            emit(hit)
            count += 1
            upper = hit.lowerBound
        }
    } else {
        let from = min(a.number("--from") ?? 0, snap.length)
        let result = attempt("find") {
            try SearchEngine.findAll(in: snap, query: compiled, range: from..<snap.length, limit: limit)
        }
        result.matches.forEach(emit)
        if result.truncated {
            out.flush()
            warn("find: stopped after \(limit) matches (--limit)")
        }
    }
    out.close()
}

/// `replace [type options] [--range RANGE] PATTERN REPLACEMENT FILE -o OUT`
///
/// Replace all, as HxD does it: the non-overlapping matches of `find` are replaced by the replacement
/// encoded with the same datatype and options (integers at each match's width), and the result is
/// written to OUT with `FileWriter`. OUT may be FILE. The number of replacements goes to stderr.
func replace(_ args: [String]) {
    let usage = "replace [--text|--hex|--int|--float] [options] [--range RANGE] PATTERN REPLACEMENT FILE -o OUT"
    let a = Arguments(args, command: "replace", flags: searchFlags, options: searchOptions.union(["--range", "-o"]))
    let p = a.expect(3, usage: usage)
    guard let outPath = a.value("-o") else { fail("usage: hexer-cli \(usage)") }
    let buffer = openBuffer(p[2])
    let snap = buffer.snapshot()
    let range = parseRange(a.value("--range"), length: snap.length)
    let compiled = attempt("replace") { try SearchEngine.compile(searchQuery(a, pattern: p[0])) }
    let replacement = attempt("replace") { try SearchEngine.compileReplacement(p[1], for: compiled) }
    let matches = attempt("replace") { try ReplaceEngine.findMatches(in: snap, search: compiled, range: range) }
    var pieces: [Int: [Piece]] = [:]
    for (length, bytes) in replacement.bytesByMatchLength { pieces[length] = buffer.addPieces(bytes) }
    let tree = ReplaceEngine.replacingAll(in: snap.tree, matches: matches) { pieces[Int($0.upperBound - $0.lowerBound)] ?? [] }
    attempt("replace") {
        try buffer.apply("Replace all", tree: tree, selectionBefore: Selection(caret: 0), selectionAfter: Selection(caret: 0))
    }
    writeSnapshot(buffer.snapshot(), to: outPath, command: "replace")
    warn("replace: \(matches.count) replacement\(matches.count == 1 ? "" : "s")")
}
