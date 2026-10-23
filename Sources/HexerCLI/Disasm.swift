import HexerCore
import HexerDisasm

/// `disasm --arch x86-16|x86-32|x86-64|arm64 [--offset N] [--length N] [--count N] [--base ADDR] [--att] FILE`
///
/// Decodes from file offset N (default 0) to the end, `--length` bytes, or `--count` instructions.
/// Prints `ADDRESS  BYTES  TEXT` (address = base + offset, 8+ uppercase hex digits; bytes padded to
/// 10 for x86, 4 for ARM64). An undecodable sequence prints `(bad)` for one byte (x86) or one word
/// (ARM64), and decoding continues after it.
func disasm(_ args: [String]) {
    let usage = "disasm --arch x86-16|x86-32|x86-64|arm64 [--offset N] [--length N] [--count N] [--base ADDR] [--att] FILE"
    let a = Arguments(args, command: "disasm", flags: ["--att"], options: ["--arch", "--offset", "--length", "--count", "--base"])
    let path = a.expect(1, usage: usage)[0]
    guard let archName = a.value("--arch") else { fail("usage: hexer-cli \(usage)") }
    guard let arch = DisassemblyArchitecture(rawValue: archName.lowercased().replacingOccurrences(of: "-", with: "_")) else {
        fail("disasm: unknown architecture \(archName) (x86-16, x86-32, x86-64, arm64)")
    }
    let disassembler = attempt("disasm") { try Disassembler(arch, syntax: a.flag("--att") ? .att : .intel) }
    let snap = openSnapshot(path)
    let start = min(a.number("--offset") ?? 0, snap.length)
    let end = a.number("--length").map { min(snap.length, start + min($0, snap.length - start)) } ?? snap.length
    let count = a.number("--count").map { Int(clamping: $0) } ?? 0
    let base = a.number("--base") ?? 0
    let maxLength = arch.maxInstructionLength
    let shownBytes = arch == .arm64 ? 4 : 10
    let out = Output()
    var printed = 0
    func emit(_ address: UInt64, _ bytes: [UInt8], _ text: String) {
        let hex = hexBytes(bytes)
        out.write(NumberBase.hexadecimal.format(address, minDigits: 8) + "  " + hex
                  + String(repeating: " ", count: max(0, shownBytes * 3 - 1 - hex.count)) + "  " + text + "\n")
        printed += 1
    }
    var pos = start
    while pos < end && (count == 0 || printed < count) {
        let n = Int(min(end - pos, 1 << 16))
        let bytes = snap.bytes(pos..<pos + UInt64(n))
        let atEnd = pos + UInt64(n) == end
        var consumed = 0
        var needsMore = false
        for insn in disassembler.disassemble(bytes, address: base &+ pos, maxCount: count == 0 ? 0 : count - printed) {
            // Re-decode instructions near the chunk's end with full lookahead.
            if !atEnd && n - consumed < maxLength {
                needsMore = true
                break
            }
            emit(insn.address, insn.bytes, insn.text)
            consumed += insn.size
        }
        if !needsMore && consumed < n && (count == 0 || printed < count) && (atEnd || n - consumed >= maxLength) {
            let bad = min(arch.instructionAlignment, n - consumed)
            emit(base &+ pos &+ UInt64(consumed), Array(bytes[consumed..<consumed + bad]), "(bad)")
            consumed += bad
        }
        pos += UInt64(consumed)
    }
    out.close()
}
