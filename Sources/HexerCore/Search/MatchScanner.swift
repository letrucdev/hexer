import Foundation

/// Streams a snapshot through overlapping windows and finds pattern occurrences (the engine behind
/// `SearchEngine`; one instance per search call, not thread-safe).
///
/// Consecutive windows overlap by `maxLength - 1` bytes, so each start position is examined exactly once
/// with full lookahead. Callers pass defined segments (undefined gaps removed); a window that fails to read
/// is narrowed to its unreadable bytes (at 64 KiB block granularity), which are then skipped like gaps.
/// Case-sensitive patterns are found with `memmem` on the window itself; case-insensitive ones on a folded
/// copy (UTF-16 needs two copies, one per code-unit alignment). Backward search uses reversed copies.
final class MatchScanner {
    private struct Stream {
        let pattern: UnsafeMutableBufferPointer<UInt8>
        let reversed: UnsafeMutableBufferPointer<UInt8>
        /// Index into `views` and `reversedViews`; -1 is the raw window.
        let view: Int
        /// For UTF-16 folding: matches must start at this absolute offset parity.
        let parity: UInt64?
        var length: Int { pattern.count }
    }

    private let snapshot: ByteSnapshot
    private let uncached: ByteSnapshot
    private let fold: CaseFold
    private let chunkSize: Int
    private let overlap: Int
    private let isCancelled: () -> Bool
    private let report: (Double) -> Void
    private var streams: [Stream] = []
    private let window: UnsafeMutableBufferPointer<UInt8>
    private var views: [UnsafeMutableBufferPointer<UInt8>] = []
    private var reversedViews: [UnsafeMutableBufferPointer<UInt8>] = []
    /// Positions finished in earlier domains and the total over all domains, for `report`.
    var progressBase: UInt64 = 0
    var progressTotal: UInt64 = 1

    init(snapshot: ByteSnapshot, search: CompiledSearch, chunkSize: Int,
         isCancelled: @escaping () -> Bool, report: @escaping (Double) -> Void) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        self.snapshot = snapshot
        uncached = ByteSnapshot(tree: snapshot.tree, registry: snapshot.registry, added: snapshot.added)
        fold = search.fold
        self.chunkSize = chunkSize
        overlap = search.maxLength - 1
        self.isCancelled = isCancelled
        self.report = report
        window = .allocate(capacity: chunkSize + overlap)
        let viewCount = switch search.fold {
        case .none: 0
        case .bytes: 1
        case .utf16LE: 2
        }
        views = (0..<viewCount).map { _ in .allocate(capacity: window.count) }
        let parities: [UInt64?] = search.fold == .utf16LE ? [0, 1] : [nil]
        for p in search.foldedPatterns {
            for (i, parity) in parities.enumerated() {
                let pattern = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: p.count)
                _ = pattern.initialize(from: p)
                let reversed = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: p.count)
                _ = reversed.initialize(from: p.reversed())
                streams.append(Stream(pattern: pattern, reversed: reversed, view: viewCount == 0 ? -1 : i, parity: parity))
            }
        }
    }

    deinit {
        window.deallocate()
        for v in views + reversedViews { v.deallocate() }
        for s in streams {
            s.pattern.deallocate()
            s.reversed.deallocate()
        }
    }

    // MARK: Forward

    /// Calls `body` with each match starting in `domain`, ascending, leftmost-longest. `body` returns the
    /// lowest start allowed for the next match, or nil to stop. Returns false if `body` stopped the scan.
    func forward(_ segments: [Range<UInt64>], domain: Range<UInt64>, _ body: (Range<UInt64>) -> UInt64?) throws -> Bool {
        var cursor = domain.lowerBound
        for segment in segments where segment.upperBound > domain.lowerBound && segment.lowerBound < domain.upperBound {
            var parts = [segment]
            var index = 0
            while index < parts.count {
                let part = parts[index]
                index += 1
                let startEnd = min(part.upperBound, domain.upperBound)
                var s = max(part.lowerBound, cursor)
                while s < startEnd {
                    if isCancelled() { throw CancellationError() }
                    let e = min(part.upperBound, s + UInt64(chunkSize + overlap))
                    // Starts in s..<t have all the lookahead a pattern can need.
                    let t = e == part.upperBound ? e : s + UInt64(chunkSize)
                    guard snapshot.copyBytes(s..<e, into: UnsafeMutableRawBufferPointer(window)) else {
                        parts.insert(contentsOf: readable(s..<part.upperBound, window: s..<e), at: index)
                        break
                    }
                    let n = Int(e - s)
                    let lo = Int(max(s, cursor) - s), hi = Int(min(t, startEnd) - s)
                    if lo < hi {
                        prepareViews(count: n, start: s)
                        var stopped = false
                        scanForward(count: n, start: s, from: lo, below: hi) { m, length in
                            guard let next = body(s + UInt64(m)..<s + UInt64(m + length)) else {
                                stopped = true
                                return nil
                            }
                            cursor = max(cursor, next)
                            return Int(clamping: cursor - s)
                        }
                        if stopped { return false }
                    }
                    s = max(t, cursor)
                    report(Double(progressBase + min(s, domain.upperBound) - domain.lowerBound) / Double(progressTotal))
                }
            }
        }
        return true
    }

    private func scanForward(count n: Int, start s: UInt64, from lo: Int, below hi: Int, _ body: (Int, Int) -> Int?) {
        var next = streams.map { find($0, from: lo, below: hi, count: n, start: s) }
        while true {
            var best = -1, bestLength = 0
            for (k, c) in next.enumerated() {
                guard let c else { continue }
                if best < 0 || c < best || (c == best && streams[k].length > bestLength) {
                    best = c
                    bestLength = streams[k].length
                }
            }
            guard best >= 0, let cursor = body(best, bestLength), cursor < hi else { return }
            for k in next.indices {
                if let c = next[k], c < cursor { next[k] = find(streams[k], from: cursor, below: hi, count: n, start: s) }
            }
        }
    }

    /// The first occurrence of `stream` starting in `p0..<hi` of the window.
    private func find(_ stream: Stream, from p0: Int, below hi: Int, count n: Int, start s: UInt64) -> Int? {
        let base = UnsafeRawPointer(stream.view < 0 ? window.baseAddress! : views[stream.view].baseAddress!)
        let length = stream.length
        let end = min(n, hi - 1 + length)
        var p = p0
        while p < hi && end - p >= length {
            guard let r = memmem(base + p, end - p, stream.pattern.baseAddress!, length) else { return nil }
            let c = base.distance(to: UnsafeRawPointer(r))
            if let parity = stream.parity, (s + UInt64(c)) & 1 != parity {
                p = c + 1
                continue
            }
            return c
        }
        return nil
    }

    // MARK: Backward

    /// The match with the greatest start in `domain` (the longest on ties), or nil.
    func last(_ segments: [Range<UInt64>], domain: Range<UInt64>) throws -> Range<UInt64>? {
        for segment in segments.reversed() where segment.upperBound > domain.lowerBound && segment.lowerBound < domain.upperBound {
            // Byte ranges with the bound below which their starts are still undecided.
            var stack = [(bytes: segment, below: min(segment.upperBound, domain.upperBound))]
            while let part = stack.popLast() {
                let first = max(part.bytes.lowerBound, domain.lowerBound)
                var t = part.below
                while t > first {
                    if isCancelled() { throw CancellationError() }
                    let s = t - min(t - first, UInt64(chunkSize))
                    let e = min(part.bytes.upperBound, t + UInt64(overlap))
                    guard snapshot.copyBytes(s..<e, into: UnsafeMutableRawBufferPointer(window)) else {
                        for r in readable(part.bytes.lowerBound..<e, window: s..<e) {
                            stack.append((r, min(r.upperBound, t)))
                        }
                        break
                    }
                    let n = Int(e - s)
                    prepareViews(count: n, start: s)
                    reverseViews(count: n)
                    if let (m, length) = lastInWindow(count: n, start: s, below: Int(t - s)) {
                        return s + UInt64(m)..<s + UInt64(m + length)
                    }
                    t = s
                    report(Double(progressBase + domain.upperBound - max(t, domain.lowerBound)) / Double(progressTotal))
                }
            }
        }
        return nil
    }

    private func lastInWindow(count n: Int, start s: UInt64, below hi: Int) -> (Int, Int)? {
        var best: (Int, Int)?
        for stream in streams {
            let length = stream.length
            guard n >= length else { continue }
            let base = UnsafeRawPointer(reversedViews[max(stream.view, 0)].baseAddress!)
            // Reversed offset r holds the match starting at n - r - length; starts below hi have r > n - hi - length.
            var r = max(0, n - hi - length + 1)
            while r <= n - length {
                guard let found = memmem(base + r, n - r, stream.reversed.baseAddress!, length) else { break }
                let rr = base.distance(to: UnsafeRawPointer(found))
                let p = n - rr - length
                if let parity = stream.parity, (s + UInt64(p)) & 1 != parity {
                    r = rr + 1
                    continue
                }
                if best == nil || p > best!.0 || (p == best!.0 && length > best!.1) { best = (p, length) }
                break
            }
        }
        return best
    }

    // MARK: Views

    /// Plain pointer loops (no ranges, no bounds-checked buffers) keep folding fast in debug builds too.
    private func prepareViews(count n: Int, start s: UInt64) {
        let src = window.baseAddress!
        switch fold {
        case .none:
            break
        case .bytes(let table):
            let dst = views[0].baseAddress!
            table.withUnsafeBufferPointer { buffer in
                let t = buffer.baseAddress!
                var i = 0
                while i < n {
                    dst[i] = t[Int(src[i])]
                    i += 1
                }
            }
        case .utf16LE:
            CaseFold.utf16Table.withUnsafeBufferPointer { buffer in
                let t = buffer.baseAddress!
                for parity in 0..<2 {
                    let dst = views[parity].baseAddress!
                    // First local index whose absolute offset has this parity.
                    let first = Int((UInt64(parity) &+ 2 &- (s & 1)) & 1)
                    if first == 1 && n > 0 { dst[0] = src[0] }
                    var i = first
                    while i + 1 < n {
                        let f = t[Int(src[i]) | Int(src[i + 1]) << 8]
                        dst[i] = UInt8(truncatingIfNeeded: f)
                        dst[i + 1] = UInt8(truncatingIfNeeded: f >> 8)
                        i += 2
                    }
                    if i < n { dst[i] = src[i] }
                }
            }
        }
    }

    private func reverseViews(count n: Int) {
        if reversedViews.isEmpty {
            reversedViews = (0..<max(1, views.count)).map { _ in .allocate(capacity: window.count) }
        }
        let sources = views.isEmpty ? [window] : views
        for (src, dst) in zip(sources, reversedViews) {
            let a = src.baseAddress!, b = dst.baseAddress!
            var i = 0, j = n - 1
            while i < n {
                b[i] = a[j]
                i += 1
                j -= 1
            }
        }
    }

    // MARK: Unreadable data

    /// The parts of `rest` outside the unreadable bytes of `window` (a range starting inside `rest`).
    private func readable(_ rest: Range<UInt64>, window range: Range<UInt64>) -> [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        var pos = rest.lowerBound
        for bad in unreadable(in: range) {
            if bad.lowerBound > pos { out.append(pos..<bad.lowerBound) }
            pos = max(pos, bad.upperBound)
        }
        if pos < rest.upperBound { out.append(pos..<rest.upperBound) }
        return out
    }

    /// Unreadable runs of `range`, located per 64 KiB block with the byte states of an uncached read.
    private func unreadable(in range: Range<UInt64>) -> [Range<UInt64>] {
        let block = UInt64(ChunkCache.blockSize)
        var bad: [Range<UInt64>] = []
        var a = range.lowerBound
        while a < range.upperBound {
            let b = min(range.upperBound, (a / block + 1) * block)
            if !snapshot.copyBytes(a..<b, into: UnsafeMutableRawBufferPointer(window)) {
                let states = uncached.read(a..<b).states
                var i = 0
                while i < states.count {
                    guard states[i] == .unreadable || states[i] == .undefined else {
                        i += 1
                        continue
                    }
                    var j = i + 1
                    while j < states.count && (states[j] == .unreadable || states[j] == .undefined) { j += 1 }
                    let r = a + UInt64(i)..<a + UInt64(j)
                    if let l = bad.last, l.upperBound == r.lowerBound {
                        bad[bad.count - 1] = l.lowerBound..<r.upperBound
                    } else {
                        bad.append(r)
                    }
                    i = j
                }
            }
            a = b
        }
        // A window that failed but now reads fine is skipped whole rather than retried forever.
        return bad.isEmpty ? [range] : bad
    }
}
