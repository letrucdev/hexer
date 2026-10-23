import Foundation

/// Finds compiled patterns in a `ByteSnapshot` of any size; call it from a background task.
///
/// Semantics:
/// - A match lies entirely inside `range` and never includes undefined (gap) or unreadable bytes.
/// - Where patterns of different lengths match at one offset (integer "(any)" width), the longest wins.
/// - `findNext` allows overlapping matches: `from` is the first allowed start, so after a hit at `p` the
///   UI continues at `p + 1` (forward) or `from: p` (backward). `findAll`, and therefore replace-all, is
///   non-overlapping: after a hit the scan resumes at its end.
/// - `SearchDirection.all` is HxD's "All": forward from `from` to the end, then wrapping to the start.
/// - Cancellation (`isCancelled` returning true, polled once per chunk) throws `CancellationError`.
/// - `progress` receives the scanned fraction (0...1) after each chunk.
public enum SearchEngine {
    public static let defaultChunkSize = 4 << 20

    /// Forward: the first match starting at or after `from`. Backward: the last match starting before
    /// `from`. With `wrap` (implied by `.all`) the rest of `range` is searched afterwards, so a hit before
    /// `from` (forward) or at/after it (backward) means the search wrapped.
    public static func findNext(in snapshot: ByteSnapshot, query: CompiledSearch, from: UInt64,
                                direction: SearchDirection, range: Range<UInt64>? = nil, wrap: Bool = false,
                                chunkSize: Int = defaultChunkSize, isCancelled: () -> Bool = { false },
                                progress: (Double) -> Void = { _ in }) throws -> Range<UInt64>? {
        let range = clamped(range, snapshot.length)
        guard !range.isEmpty else { return nil }
        let from = min(max(from, range.lowerBound), range.upperBound)
        let backward = direction == .backward
        let wraps = wrap || direction == .all
        var domains = backward ? [range.lowerBound..<from] : [from..<range.upperBound]
        if wraps { domains.append(backward ? from..<range.upperBound : range.lowerBound..<from) }
        let segments = definedSegments(of: snapshot, in: range)
        return try withScanner(snapshot, query, chunkSize, isCancelled, progress) { scanner in
            scanner.progressTotal = max(1, domains.reduce(0) { $0 + $1.upperBound - $1.lowerBound })
            for domain in domains where !domain.isEmpty {
                if backward {
                    if let hit = try scanner.last(segments, domain: domain) { return hit }
                } else {
                    var hit: Range<UInt64>?
                    _ = try scanner.forward(segments, domain: domain) { match in
                        hit = match
                        return nil
                    }
                    if let hit { return hit }
                }
                scanner.progressBase += domain.upperBound - domain.lowerBound
            }
            return nil
        }
    }

    /// All non-overlapping matches in `range`, ascending. `truncated` is true when more than `limit` exist
    /// (only the first `limit` are returned).
    public static func findAll(in snapshot: ByteSnapshot, query: CompiledSearch, range: Range<UInt64>? = nil,
                               limit: Int = .max, chunkSize: Int = defaultChunkSize, isCancelled: () -> Bool = { false },
                               progress: (Double) -> Void = { _ in }) throws -> (matches: [Range<UInt64>], truncated: Bool) {
        let range = clamped(range, snapshot.length)
        var matches: [Range<UInt64>] = []
        var truncated = false
        guard !range.isEmpty else { return (matches, truncated) }
        let segments = definedSegments(of: snapshot, in: range)
        try withScanner(snapshot, query, chunkSize, isCancelled, progress) { scanner in
            scanner.progressTotal = max(1, range.upperBound - range.lowerBound)
            _ = try scanner.forward(segments, domain: range) { match in
                guard matches.count < limit else {
                    truncated = true
                    return nil
                }
                matches.append(match)
                return match.upperBound
            }
        }
        progress(1)
        return (matches, truncated)
    }

    /// The parts of `range` not covered by undefined gaps, ascending.
    public static func definedSegments(of snapshot: ByteSnapshot, in range: Range<UInt64>) -> [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        var pos = range.lowerBound
        snapshot.tree.forEachRun(of: .undefined) { gap in
            guard gap.upperBound > pos, gap.lowerBound < range.upperBound else { return }
            if gap.lowerBound > pos { out.append(pos..<gap.lowerBound) }
            pos = gap.upperBound
        }
        if pos < range.upperBound { out.append(pos..<range.upperBound) }
        return out
    }

    private static func clamped(_ range: Range<UInt64>?, _ length: UInt64) -> Range<UInt64> {
        guard let range else { return 0..<length }
        return min(range.lowerBound, length)..<min(range.upperBound, length)
    }

    private static func withScanner<T>(_ snapshot: ByteSnapshot, _ query: CompiledSearch, _ chunkSize: Int,
                                       _ isCancelled: () -> Bool, _ progress: (Double) -> Void,
                                       _ body: (MatchScanner) throws -> T) throws -> T {
        try withoutActuallyEscaping(isCancelled) { isCancelled in
            try withoutActuallyEscaping(progress) { progress in
                let scanner = MatchScanner(snapshot: snapshot, search: query, chunkSize: chunkSize,
                                           isCancelled: isCancelled, report: progress)
                return try body(scanner)
            }
        }
    }
}
