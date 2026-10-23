import Foundation

/// Byte-value frequencies for HxD's Statistics window.
public enum ByteStatistics {
    /// Counts each byte value (256 entries) in `range`, clamped to the snapshot. Undefined bytes
    /// (gaps) are not counted, so the total can be less than the range length. nil if cancelled.
    public static func histogram(snapshot: ByteSnapshot, range: Range<UInt64>, chunkSize: Int = 4 << 20,
                                 isCancelled: () -> Bool = { false },
                                 progress: (Double) -> Void = { _ in }) -> [UInt64]? {
        let range = min(range.lowerBound, snapshot.length)..<min(range.upperBound, snapshot.length)
        let total = Double(range.upperBound - range.lowerBound)
        var counts = [UInt64](repeating: 0, count: 256)
        var cancelled = isCancelled()
        if cancelled { return nil }
        progress(0)
        snapshot.forEachChunk(in: range, chunkSize: chunkSize) { offset, chunk in
            if isCancelled() {
                cancelled = true
                return false
            }
            accumulate(chunk, into: &counts)
            progress(Double(offset + UInt64(chunk.count) - range.lowerBound) / total)
            return true
        }
        if cancelled { return nil }
        // Undefined bytes were read as zeros.
        counts[0] -= min(counts[0], snapshot.undefinedByteCount(in: range))
        progress(1)
        return counts
    }

    /// Adds the byte-value counts of `data` to `counts` (256 entries).
    ///
    /// Four interleaved tables avoid the store-to-load stalls of repeatedly incrementing the
    /// same counter on uniform data.
    public static func accumulate(_ data: UnsafeRawBufferPointer, into counts: inout [UInt64]) {
        precondition(counts.count == 256)
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 1024) { t in
            t.initialize(repeating: 0)
            let n = data.count
            var i = 0
            while i + 8 <= n {
                let w = data.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                t[Int(w & 0xFF)] &+= 1
                t[256 + Int(w >> 8 & 0xFF)] &+= 1
                t[512 + Int(w >> 16 & 0xFF)] &+= 1
                t[768 + Int(w >> 24 & 0xFF)] &+= 1
                t[Int(w >> 32 & 0xFF)] &+= 1
                t[256 + Int(w >> 40 & 0xFF)] &+= 1
                t[512 + Int(w >> 48 & 0xFF)] &+= 1
                t[768 + Int(w >> 56)] &+= 1
                i += 8
            }
            while i < n {
                t[Int(data[i])] &+= 1
                i += 1
            }
            for b in 0..<256 { counts[b] &+= t[b] &+ t[256 + b] &+ t[512 + b] &+ t[768 + b] }
        }
    }

    public static func histogram(of bytes: [UInt8]) -> [UInt64] {
        var counts = [UInt64](repeating: 0, count: 256)
        bytes.withUnsafeBytes { accumulate($0, into: &counts) }
        return counts
    }

    public static func total(_ histogram: [UInt64]) -> UInt64 {
        histogram.reduce(0, +)
    }

    /// The most frequent byte value (the lowest on ties), or nil for an empty histogram.
    public static func mostFrequent(_ histogram: [UInt64]) -> (value: UInt8, count: UInt64)? {
        guard let i = histogram.indices.max(by: { histogram[$0] < histogram[$1] || histogram[$0] == histogram[$1] && $0 > $1 }),
              histogram[i] > 0 else { return nil }
        return (UInt8(i), histogram[i])
    }

    /// Shannon entropy in bits per byte, 0...8.
    public static func entropy(_ histogram: [UInt64]) -> Double {
        let total = Double(total(histogram))
        guard total > 0 else { return 0 }
        return histogram.reduce(0) { h, count in
            guard count > 0 else { return h }
            let p = Double(count) / total
            return h - p * log2(p)
        }
    }
}

extension ByteSnapshot {
    /// The number of undefined bytes (gaps) in `range`; bulk reads return them as zeros.
    public func undefinedByteCount(in range: Range<UInt64>) -> UInt64 {
        guard tree.undefinedLength > 0 else { return 0 }
        var n: UInt64 = 0
        tree.forEachRun(of: .undefined) { run in
            let lo = max(run.lowerBound, range.lowerBound), hi = min(run.upperBound, range.upperBound)
            if lo < hi { n += hi - lo }
        }
        return n
    }
}
