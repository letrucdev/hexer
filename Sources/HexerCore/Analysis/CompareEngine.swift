import Foundation

/// Finds differences between two byte sequences (HxD's Compare, F6 / Shift+F6).
///
/// Bytes are compared by value at equal offsets. Where one snapshot is longer, its extra bytes
/// count as different. Undefined and unreadable bytes compare as zeros.
public enum CompareEngine {
    /// The run of differing bytes that starts at the first difference at or after `offset` and
    /// extends to the next equal byte, or nil if there is none (or the search was cancelled).
    public static func nextDifference(_ a: ByteSnapshot, _ b: ByteSnapshot, from offset: UInt64,
                                      chunkSize: Int = 1 << 20,
                                      isCancelled: () -> Bool = { false },
                                      progress: (Double) -> Void = { _ in }) -> Range<UInt64>? {
        let common = min(a.length, b.length), total = max(a.length, b.length)
        guard offset < total else { return nil }
        func report(_ position: UInt64) { progress(Double(position - offset) / Double(total - offset)) }
        var start = offset
        if offset < common {
            switch scan(a, b, offset..<common, forward: true, differing: true, chunkSize, isCancelled, report) {
            case .found(let i): start = i
            case .notFound: start = common
            case .cancelled: return nil
            }
        }
        guard start < total else { return nil }
        var end = total
        if start < common {
            switch scan(a, b, start + 1..<common, forward: true, differing: false, chunkSize, isCancelled, report) {
            case .found(let i): end = i
            case .notFound: break
            case .cancelled: return nil
            }
        }
        progress(1)
        return start..<end
    }

    /// The run of differing bytes that ends with the last difference before `offset`, back to
    /// the previous equal byte, or nil if there is none (or the search was cancelled).
    public static func previousDifference(_ a: ByteSnapshot, _ b: ByteSnapshot, before offset: UInt64,
                                          chunkSize: Int = 1 << 20,
                                          isCancelled: () -> Bool = { false },
                                          progress: (Double) -> Void = { _ in }) -> Range<UInt64>? {
        let common = min(a.length, b.length), total = max(a.length, b.length)
        let limit = min(offset, total)
        guard limit > 0 else { return nil }
        func report(_ position: UInt64) { progress(Double(limit - position) / Double(limit)) }
        var end = limit
        if limit <= common {
            switch scan(a, b, 0..<limit, forward: false, differing: true, chunkSize, isCancelled, report) {
            case .found(let i): end = i + 1
            case .notFound, .cancelled: return nil
            }
        }
        var start: UInt64 = 0
        switch scan(a, b, 0..<min(end - 1, common), forward: false, differing: false, chunkSize, isCancelled, report) {
        case .found(let i): start = i + 1
        case .notFound: break
        case .cancelled: return nil
        }
        progress(1)
        return start..<end
    }

    /// The maximal runs of differing bytes within `range`, for highlighting a visible window.
    /// Reads the whole range at once, so keep it small.
    public static func differingOffsets(in range: Range<UInt64>, _ a: ByteSnapshot, _ b: ByteSnapshot) -> [Range<UInt64>] {
        let total = max(a.length, b.length)
        let range = min(range.lowerBound, total)..<min(range.upperBound, total)
        let x = a.bytes(range), y = b.bytes(range)
        var runs: [Range<UInt64>] = []
        var runStart: UInt64?
        for i in 0..<Int(range.upperBound - range.lowerBound) {
            let offset = range.lowerBound + UInt64(i)
            if i >= x.count || i >= y.count || x[i] != y[i] {
                if runStart == nil { runStart = offset }
            } else if let s = runStart {
                runs.append(s..<offset)
                runStart = nil
            }
        }
        if let s = runStart { runs.append(s..<range.upperBound) }
        return runs
    }

    private enum Scan { case found(UInt64), notFound, cancelled }

    /// Finds the first (or last) offset in `range` where `a` and `b` differ (or agree). `range`
    /// must lie within both snapshots. Windows start small and double, so nearby hits return fast.
    private static func scan(_ a: ByteSnapshot, _ b: ByteSnapshot, _ range: Range<UInt64>, forward: Bool, differing: Bool,
                             _ chunkSize: Int, _ isCancelled: () -> Bool, _ report: (UInt64) -> Void) -> Scan {
        guard !range.isEmpty else { return .notFound }
        let capacity = max(chunkSize, 64)
        let bufA = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        let bufB = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        defer {
            bufA.deallocate()
            bufB.deallocate()
        }
        var size = min(capacity, 64 << 10)
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi {
            if isCancelled() { return .cancelled }
            let n = Int(min(UInt64(size), hi - lo))
            let window = forward ? lo..<lo + UInt64(n) : hi - UInt64(n)..<hi
            a.copyBytes(window, into: bufA)
            b.copyBytes(window, into: bufB)
            let p = UnsafeRawBufferPointer(rebasing: bufA[0..<n]), q = UnsafeRawBufferPointer(rebasing: bufB[0..<n])
            let hit = forward ? firstIndex(p, q, differing: differing) : lastIndex(p, q, differing: differing)
            if let hit { return .found(window.lowerBound + UInt64(hit)) }
            if forward { lo += UInt64(n); report(lo) } else { hi -= UInt64(n); report(hi) }
            size = min(size * 2, capacity)
        }
        return .notFound
    }

    private static func word(_ p: UnsafeRawBufferPointer, _ q: UnsafeRawBufferPointer, _ i: Int) -> UInt64 {
        // Little-endian so the byte at the lowest address is the least significant.
        UInt64(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt64.self) ^ q.loadUnaligned(fromByteOffset: i, as: UInt64.self))
    }

    private static func firstIndex(_ p: UnsafeRawBufferPointer, _ q: UnsafeRawBufferPointer, differing: Bool) -> Int? {
        let n = p.count
        guard differing else { return (0..<n).first { p[$0] == q[$0] } }
        guard memcmp(p.baseAddress!, q.baseAddress!, n) != 0 else { return nil }
        var i = 0
        while i + 8 <= n {
            let x = word(p, q, i)
            if x != 0 { return i + x.trailingZeroBitCount / 8 }
            i += 8
        }
        return (i..<n).first { p[$0] != q[$0] }
    }

    private static func lastIndex(_ p: UnsafeRawBufferPointer, _ q: UnsafeRawBufferPointer, differing: Bool) -> Int? {
        let n = p.count
        guard differing else { return (0..<n).last { p[$0] == q[$0] } }
        guard memcmp(p.baseAddress!, q.baseAddress!, n) != 0 else { return nil }
        var i = n
        while i >= 8 {
            let x = word(p, q, i - 8)
            if x != 0 { return i - 1 - x.leadingZeroBitCount / 8 }
            i -= 8
        }
        return (0..<i).last { p[$0] != q[$0] }
    }
}
