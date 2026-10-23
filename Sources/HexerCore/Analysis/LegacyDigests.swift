/// Splits a byte stream into whole blocks for the block-based digests below.
struct BlockBuffer {
    let size: Int
    private(set) var pending: [UInt8] = []
    /// Total bytes fed so far.
    private(set) var byteCount: UInt64 = 0

    init(size: Int) {
        self.size = size
        pending.reserveCapacity(size)
    }

    /// Calls `body` with each complete block, keeping an incomplete tail for the next call.
    mutating func feed(_ data: UnsafeRawBufferPointer, _ body: (UnsafeRawPointer) -> Void) {
        guard var p = data.baseAddress, !data.isEmpty else { return }
        var n = data.count
        byteCount &+= UInt64(n)
        if !pending.isEmpty {
            let take = min(size - pending.count, n)
            pending.append(contentsOf: UnsafeRawBufferPointer(start: p, count: take))
            p += take
            n -= take
            guard pending.count == size else { return }
            pending.withUnsafeBytes { body($0.baseAddress!) }
            pending.removeAll(keepingCapacity: true)
        }
        while n >= size {
            body(p)
            p += size
            n -= size
        }
        if n > 0 { pending.append(contentsOf: UnsafeRawBufferPointer(start: p, count: n)) }
    }

    mutating func feed(_ bytes: [UInt8], _ body: (UnsafeRawPointer) -> Void) {
        bytes.withUnsafeBytes { feed($0, body) }
    }
}

/// MD2 (RFC 1319, with the published erratum to the checksum step).
struct MD2Hasher: ChecksumHasher {
    private struct State {
        var x = [UInt8](repeating: 0, count: 48)
        var checksum = [UInt8](repeating: 0, count: 16)

        mutating func compress(_ block: UnsafeRawPointer) {
            x.withUnsafeMutableBufferPointer { x in
                checksum.withUnsafeMutableBufferPointer { c in
                    var l = c[15]
                    for j in 0..<16 {
                        let m = block.load(fromByteOffset: j, as: UInt8.self)
                        c[j] ^= MD2Hasher.piSubst[Int(m ^ l)]
                        l = c[j]
                        x[16 + j] = m
                        x[32 + j] = m ^ x[j]
                    }
                    var t: UInt8 = 0
                    for j in 0..<18 {
                        for k in 0..<48 {
                            x[k] ^= MD2Hasher.piSubst[Int(t)]
                            t = x[k]
                        }
                        t &+= UInt8(j)
                    }
                }
            }
        }
    }

    private var state = State()
    private var buffer = BlockBuffer(size: 16)

    mutating func update(_ data: UnsafeRawBufferPointer) {
        buffer.feed(data) { state.compress($0) }
    }

    mutating func finalize() -> [UInt8] {
        let pad = 16 - Int(buffer.byteCount % 16)
        buffer.feed([UInt8](repeating: UInt8(pad), count: pad)) { state.compress($0) }
        let checksum = state.checksum
        buffer.feed(checksum) { state.compress($0) }
        return Array(state.x[0..<16])
    }

    /// The permutation of 0...255 built from the digits of pi.
    static let piSubst: [UInt8] = [
        41, 46, 67, 201, 162, 216, 124, 1, 61, 54, 84, 161, 236, 240, 6, 19,
        98, 167, 5, 243, 192, 199, 115, 140, 152, 147, 43, 217, 188, 76, 130, 202,
        30, 155, 87, 60, 253, 212, 224, 22, 103, 66, 111, 24, 138, 23, 229, 18,
        190, 78, 196, 214, 218, 158, 222, 73, 160, 251, 245, 142, 187, 47, 238, 122,
        169, 104, 121, 145, 21, 178, 7, 63, 148, 194, 16, 137, 11, 34, 95, 33,
        128, 127, 93, 154, 90, 144, 50, 39, 53, 62, 204, 231, 191, 247, 151, 3,
        255, 25, 48, 179, 72, 165, 181, 209, 215, 94, 146, 42, 172, 86, 170, 198,
        79, 184, 56, 210, 150, 164, 125, 182, 118, 252, 107, 226, 156, 116, 4, 241,
        69, 157, 112, 89, 100, 113, 135, 32, 134, 91, 207, 101, 230, 45, 168, 2,
        27, 96, 37, 173, 174, 176, 185, 246, 28, 70, 97, 105, 52, 64, 126, 15,
        85, 71, 163, 35, 221, 81, 175, 58, 195, 92, 249, 206, 186, 197, 234, 38,
        44, 83, 13, 110, 133, 40, 132, 9, 211, 223, 205, 244, 65, 129, 77, 82,
        106, 220, 55, 200, 108, 193, 171, 250, 36, 225, 123, 8, 12, 189, 177, 74,
        120, 136, 149, 139, 227, 99, 232, 109, 233, 203, 213, 254, 59, 0, 29, 57,
        242, 239, 183, 14, 102, 88, 208, 228, 166, 119, 114, 248, 235, 117, 75, 10,
        49, 68, 80, 180, 143, 237, 31, 26, 219, 153, 141, 51, 159, 17, 131, 20,
    ]
}

/// MD4 (RFC 1320).
struct MD4Hasher: ChecksumHasher {
    private struct State {
        var a: UInt32 = 0x6745_2301, b: UInt32 = 0xEFCD_AB89, c: UInt32 = 0x98BA_DCFE, d: UInt32 = 0x1032_5476

        mutating func compress(_ p: UnsafeRawPointer) {
            @inline(__always) func x(_ i: Int) -> UInt32 {
                UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i << 2, as: UInt32.self))
            }
            @inline(__always) func rotl(_ v: UInt32, _ s: UInt32) -> UInt32 { v << s | v >> (32 - s) }
            @inline(__always) func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x & y | ~x & z }
            @inline(__always) func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x & y | x & z | y & z }
            var a = a, b = b, c = c, d = d
            for i in stride(from: 0, to: 16, by: 4) {
                a = rotl(a &+ f(b, c, d) &+ x(i), 3)
                d = rotl(d &+ f(a, b, c) &+ x(i + 1), 7)
                c = rotl(c &+ f(d, a, b) &+ x(i + 2), 11)
                b = rotl(b &+ f(c, d, a) &+ x(i + 3), 19)
            }
            for i in 0..<4 {
                a = rotl(a &+ g(b, c, d) &+ x(i) &+ 0x5A82_7999, 3)
                d = rotl(d &+ g(a, b, c) &+ x(i + 4) &+ 0x5A82_7999, 5)
                c = rotl(c &+ g(d, a, b) &+ x(i + 8) &+ 0x5A82_7999, 9)
                b = rotl(b &+ g(c, d, a) &+ x(i + 12) &+ 0x5A82_7999, 13)
            }
            for i in [0, 2, 1, 3] {
                a = rotl(a &+ (b ^ c ^ d) &+ x(i) &+ 0x6ED9_EBA1, 3)
                d = rotl(d &+ (a ^ b ^ c) &+ x(i + 8) &+ 0x6ED9_EBA1, 9)
                c = rotl(c &+ (d ^ a ^ b) &+ x(i + 4) &+ 0x6ED9_EBA1, 11)
                b = rotl(b &+ (c ^ d ^ a) &+ x(i + 12) &+ 0x6ED9_EBA1, 15)
            }
            self.a &+= a
            self.b &+= b
            self.c &+= c
            self.d &+= d
        }
    }

    private var state = State()
    private var buffer = BlockBuffer(size: 64)

    mutating func update(_ data: UnsafeRawBufferPointer) {
        buffer.feed(data) { state.compress($0) }
    }

    mutating func finalize() -> [UInt8] {
        let bits = buffer.byteCount &* 8
        let zeros = (55 - Int(buffer.byteCount % 64) + 64) % 64
        var tail: [UInt8] = [0x80] + repeatElement(0, count: zeros)
        for i in 0..<8 { tail.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
        buffer.feed(tail) { state.compress($0) }
        return [state.a, state.b, state.c, state.d].flatMap { w in
            (0..<4).map { UInt8(truncatingIfNeeded: w >> (8 * UInt32($0))) }
        }
    }
}
