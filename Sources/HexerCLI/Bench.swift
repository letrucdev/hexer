import Foundation
import HexerCore

/// `bench [--runs N] FILE` — the best of N runs (default 3, after one warm-up read) of a full
/// sequential read, CRC-32, SHA-256 and a find of the 4-byte pattern `DE AD BE EF`, with throughput.
func bench(_ args: [String]) {
    let a = Arguments(args, command: "bench", options: ["--runs"])
    let path = a.expect(1, usage: "bench [--runs N] FILE")[0]
    let runs = max(1, Int(clamping: a.number("--runs") ?? 3))
    let snap = openSnapshot(path)
    let range = 0..<snap.length
    let mib = Double(snap.length) / Double(1 << 20)

    func readAll() -> UInt8 {
        var x: UInt8 = 0
        snap.forEachChunk(in: range) { _, chunk in
            if let last = chunk.last { x ^= last }
            return true
        }
        return x
    }
    _ = readAll()

    let out = Output()
    out.write(path + String(format: ": %.1f MiB, best of %d runs\n", mib, runs))
    func measure(_ name: String, _ body: () -> String) {
        var best = Duration.seconds(1_000_000)
        var note = ""
        for _ in 0..<runs {
            let t = ContinuousClock.now
            note = body()
            best = min(best, ContinuousClock.now - t)
        }
        let seconds = Double(best.components.seconds) + Double(best.components.attoseconds) / 1e18
        out.write(name.padding(toLength: 8, withPad: " ", startingAt: 0)
                  + String(format: "%10.2f ms %9.1f MiB/s  ", seconds * 1000, mib / max(seconds, 1e-9)) + note + "\n")
        out.flush()
    }
    measure("read") { String(format: "xor %02X", readAll()) }
    measure("CRC-32") { ChecksumCalculator.compute([.crc32], snapshot: snap, range: range)!.map(\.hexString).joined() }
    measure("SHA-256") { ChecksumCalculator.compute([.sha256], snapshot: snap, range: range)!.map(\.hexString).joined() }
    let query = attempt("bench") { try SearchEngine.compile(.hex("DE AD BE EF")) }
    measure("find") {
        let n = attempt("bench") { try SearchEngine.findAll(in: snap, query: query, range: range).matches.count }
        return "\(n) matches of DE AD BE EF"
    }
    out.close()
}
