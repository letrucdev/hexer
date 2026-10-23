/// Produces bytes on demand, so inserting or filling gigabytes costs no memory.
///
/// A generator piece's `start` is a position in the generator's infinite stream; the byte at
/// stream position `i` is always the same, which keeps re-reads and undo stable.
public enum Generator: Hashable, Sendable {
    /// Repeats `bytes` (at least one byte).
    case pattern([UInt8])
    /// Pseudo-random bytes in `min...max`, reproducible from `seed`.
    case random(seed: UInt64, min: UInt8, max: UInt8)

    public func fill(_ dest: UnsafeMutableRawBufferPointer, streamOffset: UInt64) {
        guard let base = dest.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        switch self {
        case .pattern(let bytes):
            precondition(!bytes.isEmpty)
            let n = UInt64(bytes.count)
            if n == 1 {
                base.update(repeating: bytes[0], count: dest.count)
                return
            }
            var phase = Int(streamOffset % n)
            for i in 0..<dest.count {
                base[i] = bytes[phase]
                phase += 1
                if phase == bytes.count { phase = 0 }
            }
        case .random(let seed, let lo, let hi):
            let span = UInt64(hi) - UInt64(lo) + 1
            for i in 0..<dest.count {
                let v = Self.splitMix(seed &+ (streamOffset &+ UInt64(i)) &* 0x9E37_79B9_7F4A_7C15)
                base[i] = UInt8(UInt64(lo) + v % span)
            }
        }
    }

    private static func splitMix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
