import Foundation
import HexerCore

/// Lowercase letters and digits only, so `SHA-256`, `sha256` and `Sha_256` name the same algorithm.
private func normalized(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }

/// Comma-separated `key=value` or bare `key` items.
private func specItems(_ spec: String, _ what: String, keys: Set<String>) -> [String: String] {
    var out: [String: String] = [:]
    for item in spec.split(separator: ",") {
        let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard keys.contains(parts[0]) else { fail("checksum: unknown \(what) parameter \(parts[0]) (\(keys.sorted().joined(separator: ", ")))") }
        out[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return out
}

/// `--crc width=W,poly=P[,init=I][,xorout=X][,refin][,refout][,ref]` (Rocksoft model, normal form).
private func customCRC(_ spec: String) -> ChecksumAlgorithm {
    let v = specItems(spec, "--crc", keys: ["width", "poly", "init", "xorout", "refin", "refout", "ref"])
    guard let w = v["width"], let p = v["poly"] else { fail("checksum: --crc needs width= and poly=") }
    let width = parseNumber(w, "--crc width")
    guard (1...64).contains(width) else { fail("checksum: --crc width must be 1...64") }
    return .customCRC(CRCParameters(width: Int(width), polynomial: parseNumber(p, "--crc poly"),
                                    initialValue: v["init"].map { parseNumber($0, "--crc init") } ?? 0,
                                    finalXOR: v["xorout"].map { parseNumber($0, "--crc xorout") } ?? 0,
                                    reflectInput: v["refin"] != nil || v["ref"] != nil,
                                    reflectOutput: v["refout"] != nil || v["ref"] != nil))
}

/// `--sum result=R[,addend=A][,be]`: HxD's custom checksum (sum of A-bit addends modulo 2^R).
private func customSum(_ spec: String) -> ChecksumAlgorithm {
    let v = specItems(spec, "--sum", keys: ["result", "addend", "be", "le"])
    guard let r = v["result"] else { fail("checksum: --sum needs result=") }
    let result = parseNumber(r, "--sum result"), addend = v["addend"].map { parseNumber($0, "--sum addend") } ?? 8
    guard (1...64).contains(result), [8, 16, 32, 64].contains(addend) else {
        fail("checksum: --sum result must be 1...64, addend 8, 16, 32 or 64")
    }
    return .customChecksum(CustomChecksumParameters(resultWidth: Int(result), addendWidth: Int(addend),
                                                    byteOrder: v["be"] != nil ? .bigEndian : .littleEndian))
}

/// `checksum [-a ALG[,ALG…]] [--all] [--crc SPEC] [--sum SPEC] [--range RANGE] FILE`
///
/// Prints `NAME  HEX` per algorithm (HxD's names and uppercase digits). Without `-a`, `--all`,
/// `--crc` or `--sum`: CRC-32, MD5, SHA-1 and SHA-256.
func checksum(_ args: [String]) {
    let a = Arguments(args, command: "checksum", flags: ["--all"], options: ["-a", "--crc", "--sum", "--range"])
    let path = a.expect(1, usage: "checksum [-a ALG[,ALG...]] [--all] [--crc SPEC] [--sum SPEC] [--range RANGE] FILE")[0]
    let byName = Dictionary(uniqueKeysWithValues: ChecksumAlgorithm.standard.map { (normalized($0.displayName), $0) })
    var algorithms: [ChecksumAlgorithm] = a.flag("--all") ? ChecksumAlgorithm.standard : []
    for name in a.allValues("-a").flatMap({ $0.split(separator: ",") }) {
        guard let alg = byName[normalized(String(name))] else {
            fail("checksum: unknown algorithm \(name) (\(ChecksumAlgorithm.standard.map(\.displayName).joined(separator: ", ")))")
        }
        algorithms.append(alg)
    }
    algorithms += a.allValues("--crc").map(customCRC) + a.allValues("--sum").map(customSum)
    if algorithms.isEmpty { algorithms = [.crc32, .md5, .sha1, .sha256] }
    let snap = openSnapshot(path)
    let range = parseRange(a.value("--range"), length: snap.length)
    guard let results = ChecksumCalculator.compute(algorithms, snapshot: snap, range: range) else { fail("checksum: cancelled") }
    let out = Output()
    for r in results { out.write("\(r.algorithm.displayName)  \(r.hexString)\n") }
    out.close()
}

/// `stats [--range RANGE] FILE` — `XX count` for every byte value, then `total N` and
/// `entropy E` (bits per byte, 6 decimals).
func stats(_ args: [String]) {
    let a = Arguments(args, command: "stats", options: ["--range"])
    let path = a.expect(1, usage: "stats [--range RANGE] FILE")[0]
    let snap = openSnapshot(path)
    let range = parseRange(a.value("--range"), length: snap.length)
    guard let h = ByteStatistics.histogram(snapshot: snap, range: range) else { fail("stats: cancelled") }
    let out = Output()
    for b in 0..<256 { out.write(NumberBase.hexadecimal.format(UInt64(b), minDigits: 2) + " \(h[b])\n") }
    out.write("total \(ByteStatistics.total(h))\n")
    out.write(String(format: "entropy %.6f\n", ByteStatistics.entropy(h)))
    out.close()
}

/// `diff [--cmp | --backward] [--limit N] A B`
///
/// Default: one line per run of differing bytes (`CompareEngine.nextDifference`), as
/// `OFFSET(hex)  LENGTH  A-bytes | B-bytes` with at most 8 bytes shown per side (`…` when longer,
/// `EOF` past the end of a file). Bytes beyond the shorter file count as different. `--backward`
/// lists the same runs last first (`CompareEngine.previousDifference`).
///
/// `--cmp`: exactly `cmp -l` — `%6d %3o %3o` per differing byte of the common length (1-based
/// offset, octal values), then `cmp: EOF on SHORTER` on stderr if the lengths differ.
/// `--limit` caps the lines printed. The exit status is 0 whether or not the files differ.
func diff(_ args: [String]) {
    let a = Arguments(args, command: "diff", flags: ["--cmp", "--backward"], options: ["--limit"])
    let p = a.expect(2, usage: "diff [--cmp | --backward] [--limit N] A B")
    let x = openSnapshot(p[0]), y = openSnapshot(p[1])
    let limit = a.number("--limit") ?? .max
    let common = min(x.length, y.length)
    let out = Output()
    var lines: UInt64 = 0
    var offset: UInt64 = 0
    if a.flag("--cmp") {
        scan: while offset < common, let run = CompareEngine.nextDifference(x, y, from: offset) {
            let end = min(run.upperBound, common)
            var pos = run.lowerBound
            while pos < end {
                let n = min(end - pos, 1 << 16)
                let bx = x.bytes(pos..<pos + n), by = y.bytes(pos..<pos + n)
                for i in 0..<Int(n) where bx[i] != by[i] {
                    guard lines < limit else { break scan }
                    out.write(String(format: "%6llu %3o %3o\n", pos + UInt64(i) + 1, bx[i], by[i]))
                    lines += 1
                }
                pos += n
            }
            offset = end
        }
        out.close()
        if x.length != y.length && lines < limit { warn("cmp: EOF on \(x.length < y.length ? p[0] : p[1])") }
        return
    }
    func preview(_ s: ByteSnapshot, _ run: Range<UInt64>) -> String {
        guard run.lowerBound < s.length else { return "EOF" }
        let shown = run.lowerBound..<min(run.upperBound, run.lowerBound + 8)
        return hexBytes(s.bytes(shown)) + (run.upperBound - run.lowerBound > 8 && s.length > shown.upperBound ? " …" : "")
    }
    func emit(_ run: Range<UInt64>) {
        out.write(NumberBase.hexadecimal.format(run.lowerBound, minDigits: 8) + "  \(run.upperBound - run.lowerBound)  "
                  + preview(x, run) + " | " + preview(y, run) + "\n")
        lines += 1
    }
    if a.flag("--backward") {
        offset = max(x.length, y.length)
        while lines < limit, let run = CompareEngine.previousDifference(x, y, before: offset) {
            emit(run)
            offset = run.lowerBound
        }
    } else {
        while lines < limit, let run = CompareEngine.nextDifference(x, y, from: offset) {
            emit(run)
            offset = run.upperBound
        }
    }
    out.close()
}
