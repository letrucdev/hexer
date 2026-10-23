import CryptoKit
import Foundation

/// An incremental checksum or digest computation.
public protocol ChecksumHasher {
    mutating func update(_ data: UnsafeRawBufferPointer)
    /// The result, most significant byte first. Call once, after the last `update`.
    mutating func finalize() -> [UInt8]
}

extension ChecksumHasher {
    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }
}

/// The algorithms of HxD's "Generate checksums" dialog.
public enum ChecksumAlgorithm: Hashable, Codable, Sendable, CustomStringConvertible {
    case checksum8, checksum16, checksum32, checksum64
    /// CRC-16/ARC.
    case crc16
    case crc16CCITTFalse, crc32, crc32C
    case md2, md4, md5, sha1, sha256, sha384, sha512
    case customChecksum(CustomChecksumParameters)
    case customCRC(CRCParameters)

    /// The parameterless algorithms, in HxD's order.
    public static var standard: [ChecksumAlgorithm] {
        [.checksum8, .checksum16, .checksum32, .checksum64, .crc16, .crc16CCITTFalse, .crc32, .crc32C,
         .md2, .md4, .md5, .sha1, .sha256, .sha384, .sha512]
    }

    public var displayName: String {
        switch self {
        case .checksum8: "Checksum-8"
        case .checksum16: "Checksum-16"
        case .checksum32: "Checksum-32"
        case .checksum64: "Checksum-64"
        case .crc16: "CRC-16"
        case .crc16CCITTFalse: "CRC-16/CCITT-FALSE"
        case .crc32: "CRC-32"
        case .crc32C: "CRC-32C"
        case .md2: "MD2"
        case .md4: "MD4"
        case .md5: "MD5"
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        case .sha384: "SHA-384"
        case .sha512: "SHA-512"
        case .customChecksum: "Custom checksum"
        case .customCRC(let p): "Custom CRC (\(p.effectiveWidth)-bit)"
        }
    }

    public var description: String { displayName }

    /// The CRC model of CRC algorithms.
    public var crcParameters: CRCParameters? {
        switch self {
        case .crc16: .crc16ARC
        case .crc16CCITTFalse: .crc16CCITTFalse
        case .crc32: .crc32
        case .crc32C: .crc32C
        case .customCRC(let p): p
        default: nil
        }
    }

    /// The addend/result model of sum checksums.
    public var sumParameters: CustomChecksumParameters? {
        switch self {
        case .checksum8: CustomChecksumParameters(resultWidth: 8)
        case .checksum16: CustomChecksumParameters(resultWidth: 16)
        case .checksum32: CustomChecksumParameters(resultWidth: 32)
        case .checksum64: CustomChecksumParameters(resultWidth: 64)
        case .customChecksum(let p): p
        default: nil
        }
    }

    /// Bits in the result; `ChecksumResult.hexString` has `(bitWidth + 3) / 4` digits.
    public var bitWidth: Int {
        if let p = crcParameters { return p.effectiveWidth }
        if let p = sumParameters { return p.effectiveResultWidth }
        switch self {
        case .md2, .md4, .md5: return 128
        case .sha1: return 160
        case .sha256: return 256
        case .sha384: return 384
        default: return 512
        }
    }

    public func makeHasher() -> any ChecksumHasher {
        if let p = crcParameters { return CRCHasher(p) }
        if let p = sumParameters { return SumHasher(p) }
        switch self {
        case .md2: return MD2Hasher()
        case .md4: return MD4Hasher()
        case .md5: return CryptoKitHasher<Insecure.MD5>()
        case .sha1: return CryptoKitHasher<Insecure.SHA1>()
        case .sha256: return CryptoKitHasher<SHA256>()
        case .sha384: return CryptoKitHasher<SHA384>()
        default: return CryptoKitHasher<SHA512>()
        }
    }

    /// Computes the checksum of in-memory bytes in one go.
    public func checksum(of bytes: [UInt8]) -> ChecksumResult {
        var h = makeHasher()
        h.update(bytes)
        return ChecksumResult(algorithm: self, bytes: h.finalize())
    }
}

struct CryptoKitHasher<H: HashFunction>: ChecksumHasher {
    private var hash = H()

    mutating func update(_ data: UnsafeRawBufferPointer) { hash.update(bufferPointer: data) }
    mutating func finalize() -> [UInt8] { Array(hash.finalize()) }
}

/// One computed checksum.
public struct ChecksumResult: Hashable, Sendable {
    public let algorithm: ChecksumAlgorithm
    /// Most significant byte first; CRCs and sums take `(bitWidth + 7) / 8` bytes.
    public let bytes: [UInt8]

    public init(algorithm: ChecksumAlgorithm, bytes: [UInt8]) {
        self.algorithm = algorithm
        self.bytes = bytes
    }

    /// Uppercase hex without separators, zero-padded to the algorithm's width (`CBF43926`).
    public var hexString: String {
        let digits = Array("0123456789ABCDEF")
        let full = String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xF)]] })
        return String(full.suffix((algorithm.bitWidth + 3) / 4))
    }

    /// Whether `expected`, as typed by the user, denotes this result. Whitespace, case, a `0x`
    /// prefix and leading zeros are ignored; anything else that isn't a hex digit never matches.
    public func matches(_ expected: String) -> Bool {
        guard let e = Self.normalizedHex(expected), !e.isEmpty else { return false }
        return e.drop { $0 == "0" } == hexString.drop { $0 == "0" }
    }

    /// `text` without whitespace and `0x` prefix, uppercased; nil if other non-hex characters remain.
    public static func normalizedHex(_ text: String) -> String? {
        var s = text.filter { !$0.isWhitespace }.uppercased()
        if s.hasPrefix("0X") { s.removeFirst(2) }
        return s.allSatisfy(\.isHexDigit) ? s : nil
    }
}

/// Runs checksum algorithms over a document range.
public enum ChecksumCalculator {
    /// Computes `algorithms` over `range` (clamped to the snapshot), reading the data once and
    /// feeding each chunk to all hashers in parallel. Undefined and unreadable bytes are hashed as
    /// zeros (`ByteSnapshot.undefinedByteCount(in:)` tells whether to warn). Returns the results in
    /// the order of `algorithms`, or nil if cancelled.
    public static func compute(_ algorithms: [ChecksumAlgorithm], snapshot: ByteSnapshot, range: Range<UInt64>,
                               chunkSize: Int = 4 << 20,
                               isCancelled: () -> Bool = { false },
                               progress: (Double) -> Void = { _ in }) -> [ChecksumResult]? {
        var hashers = algorithms.map { $0.makeHasher() }
        let start = min(range.lowerBound, snapshot.length)
        let total = Double(min(range.upperBound, snapshot.length) - start)
        var cancelled = isCancelled()
        if cancelled { return nil }
        progress(0)
        snapshot.forEachChunk(in: range, chunkSize: chunkSize) { offset, chunk in
            if isCancelled() {
                cancelled = true
                return false
            }
            if hashers.count == 1 {
                hashers[0].update(chunk)
            } else {
                hashers.withUnsafeMutableBufferPointer { hs in
                    // Each iteration touches only its own hasher; the chunk is read-only.
                    nonisolated(unsafe) let hs = hs
                    nonisolated(unsafe) let chunk = chunk
                    DispatchQueue.concurrentPerform(iterations: hs.count) { hs[$0].update(chunk) }
                }
            }
            progress(Double(offset + UInt64(chunk.count) - start) / total)
            return true
        }
        if cancelled { return nil }
        progress(1)
        return algorithms.indices.map { ChecksumResult(algorithm: algorithms[$0], bytes: hashers[$0].finalize()) }
    }
}
