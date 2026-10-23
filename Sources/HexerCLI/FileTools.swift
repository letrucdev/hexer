import Foundation
import HexerCore

/// The `split --preset` names of HxD's part sizes, in `FileTools.splitPresets` order.
private let presetNames = ["floppy1200", "floppy1440", "zip100", "zip200", "cd650", "cd700"]

/// A byte count with an optional binary suffix: `1440K`, `100M`, `2G` (or plain decimal / 0x hex).
private func parseSize(_ s: String, _ what: String) -> UInt64 {
    let units: [Character: UInt64] = ["k": 1 << 10, "m": 1 << 20, "g": 1 << 30]
    guard let last = s.lowercased().last, let unit = units[last] else { return parseNumber(s, what) }
    let (v, overflow) = parseNumber(String(s.dropLast()), what).multipliedReportingOverflow(by: unit)
    guard !overflow else { fail("\(what) is too large: \(s)") }
    return v
}

/// `split (--size N | --preset NAME) [--base PATH] FILE`
///
/// HxD's Split: parts of N bytes named BASE.001, BASE.002, … (more digits past 999 parts); BASE
/// defaults to FILE. Prints each part's path. N takes a K, M or G suffix (KiB, MiB, GiB).
func splitFile(_ args: [String]) {
    let usage = "split (--size N | --preset \(presetNames.joined(separator: "|"))) [--base PATH] FILE"
    let a = Arguments(args, command: "split", options: ["--size", "--preset", "--base"])
    let path = a.expect(1, usage: usage)[0]
    let partSize: UInt64
    switch (a.value("--size"), a.value("--preset")) {
    case (let size?, nil):
        partSize = parseSize(size, "--size")
    case (nil, let name?):
        guard let i = presetNames.firstIndex(of: name.lowercased()) else {
            fail("split: unknown preset \(name) (\(presetNames.joined(separator: ", ")))")
        }
        partSize = FileTools.splitPresets[i].size
    default:
        fail("usage: hexer-cli \(usage)")
    }
    guard partSize > 0 else { fail("split: the part size must be at least one byte") }
    let source = URL(fileURLWithPath: path)
    var st = stat()
    guard stat(path, &st) == 0 else { fail("split: cannot open \(path): \(String(cString: strerror(errno)))") }
    let count = FileTools.partCount(length: UInt64(max(st.st_size, 0)), partSize: partSize)
    let base = a.value("--base") ?? path
    let parts = FileTools.partURLs(base: URL(fileURLWithPath: base), count: count)
    attempt("split") { try FileTools.split(source, partSize: partSize, to: parts) }
    // The paths as given (relative stays relative), like split(1).
    let out = Output()
    for url in parts { out.write(base + "." + url.pathExtension + "\n") }
    out.close()
}

/// `concat -o OUT FILE...`
///
/// HxD's Concatenate: the files one after another. OUT may be one of the inputs.
func concatFiles(_ args: [String]) {
    let a = Arguments(args, command: "concat", options: ["-o"])
    guard let output = a.value("-o"), !a.positional.isEmpty else { fail("usage: hexer-cli concat -o OUT FILE...") }
    let sources = a.positional.map { URL(fileURLWithPath: $0) }
    attempt("concat") {
        try writeReplacing(output) { temp in try FileTools.concatenate(sources, to: URL(fileURLWithPath: temp)) }
    }
}
