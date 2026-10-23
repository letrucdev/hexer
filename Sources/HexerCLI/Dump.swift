import HexerCore

/// `dump [-s offset] [-l length] [--xxd] file` — prints like `xxd` with `--xxd`, else HxD-style.
func dump(_ args: [String]) {
    let a = Arguments(args, command: "dump", flags: ["--xxd"], options: ["-s", "-l"])
    let path = a.expect(1, usage: "dump [-s offset] [-l length] [--xxd] file")[0]
    let snap = openSnapshot(path)
    let start = a.number("-s") ?? 0
    let length = a.number("-l") ?? (snap.length - min(start, snap.length))
    let end = min(snap.length, start &+ length < start ? .max : start + length)
    let output = Output()
    let xxd = a.flag("--xxd")
    // Lines are built from lookup tables; String(format:) per byte is far too slow for big files.
    let hexDigits = Array((xxd ? "0123456789abcdef" : "0123456789ABCDEF").utf8)
    let text = TextEncoding.windowsLatin1.table.display.map { String($0) }
    let chunk: UInt64 = 1 << 16
    var offset = start
    while offset < end {
        let block = snap.bytes(offset..<min(end, offset + chunk))
        var i = 0
        while i < block.count {
            let row = block[i..<min(i + 16, block.count)]
            var ascii: [UInt8] = []
            ascii.reserveCapacity(80)
            let at = offset + UInt64(i)
            if xxd {
                for shift in stride(from: 28, through: 0, by: -4) { ascii.append(hexDigits[Int(at >> UInt64(shift) & 0xF)]) }
                ascii += Array(": ".utf8)
                for k in 0..<16 {
                    if k < row.count {
                        let b = row[row.startIndex + k]
                        ascii += [hexDigits[Int(b >> 4)], hexDigits[Int(b & 0xF)]]
                    } else {
                        ascii += [0x20, 0x20]
                    }
                    if k % 2 == 1 { ascii.append(0x20) }
                }
                ascii.append(0x20)
                for b in row { ascii.append((0x20...0x7E).contains(b) ? b : 0x2E) }
                output.write(String(decoding: ascii, as: UTF8.self) + "\n")
            } else {
                var line = NumberBase.hexadecimal.format(at, minDigits: 8) + "  "
                for (k, b) in row.enumerated() {
                    if k > 0 { ascii.append(0x20) }
                    ascii += [hexDigits[Int(b >> 4)], hexDigits[Int(b & 0xF)]]
                }
                line += String(decoding: ascii, as: UTF8.self) + String(repeating: "   ", count: 16 - row.count) + "  "
                for b in row { line += text[Int(b)] }
                output.write(line + "\n")
            }
            i += 16
        }
        offset += UInt64(block.count)
    }
    output.close()
}
