import Foundation

/// Writes snapshots to files: either by streaming every byte, or — when most of the file is
/// unchanged — by cloning the original file (APFS) and patching only the changed ranges.
public enum FileWriter {
    public enum WriteError: Error, Equatable {
        case cannotCreate(path: String, code: Int32)
        case writeFailed(path: String, code: Int32)
        case cancelled
    }

    /// Ranges of `tree` whose bytes may differ from the source `baseID` at the same offsets:
    /// everything except pieces that refer to `baseID` at their own offset. Adjacent ranges merge.
    public static func changedRanges(in tree: PieceTree, base baseID: UInt32) -> [Range<UInt64>] {
        var ranges: [Range<UInt64>] = []
        tree.forEachPiece(in: 0..<tree.length) { piece, offset in
            if piece.ref == .source(baseID) && piece.start == offset { return true }
            let r = offset..<offset + piece.length
            if let last = ranges.last, last.upperBound == r.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<r.upperBound
            } else {
                ranges.append(r)
            }
            return true
        }
        return ranges
    }

    /// Streams `range` (default: everything) of `snapshot` into a new file at `url`.
    public static func write(_ snapshot: ByteSnapshot, range: Range<UInt64>? = nil, to url: URL,
                             isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw WriteError.cannotCreate(path: url.path, code: errno) }
        defer { close(fd) }
        let range = range ?? 0..<snapshot.length
        try writeRange(snapshot, range, fd: fd, at: 0, path: url.path, total: range.upperBound - range.lowerBound, done: 0,
                       isCancelled: isCancelled, progress: progress)
    }

    /// Clones `original` to `url` and writes only the ranges of `snapshot` that differ from
    /// source `baseID` (which must hold the current contents of `original`).
    ///
    /// Returns `false`, leaving nothing at `url`, when patching would not pay off (most bytes
    /// changed) or the volume cannot clone; the caller then streams the whole file instead.
    public static func writePatchingClone(of original: URL, snapshot: ByteSnapshot, base baseID: UInt32,
                                          to url: URL, isCancelled: () -> Bool = { false },
                                          progress: (Double) -> Void = { _ in }) throws -> Bool {
        let changed = changedRanges(in: snapshot.tree, base: baseID)
        let changedBytes = changed.reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
        guard changedBytes <= snapshot.length / 2 else { return false }
        guard clonefile(original.path, url.path, 0) == 0 else { return false }
        do {
            let fd = open(url.path, O_WRONLY | O_CLOEXEC)
            guard fd >= 0 else { throw WriteError.cannotCreate(path: url.path, code: errno) }
            defer { close(fd) }
            guard ftruncate(fd, off_t(snapshot.length)) == 0 else { throw WriteError.writeFailed(path: url.path, code: errno) }
            var done: UInt64 = 0
            for r in changed {
                try writeRange(snapshot, r, fd: fd, at: r.lowerBound, path: url.path, total: changedBytes, done: done,
                               isCancelled: isCancelled, progress: progress)
                done += r.upperBound - r.lowerBound
            }
            return true
        } catch {
            unlink(url.path)
            throw error
        }
    }

    private static func writeRange(_ snapshot: ByteSnapshot, _ range: Range<UInt64>, fd: Int32, at fileOffset: UInt64,
                                   path: String, total: UInt64, done: UInt64,
                                   isCancelled: () -> Bool, progress: (Double) -> Void) throws {
        try snapshot.forEachChunk(in: range, chunkSize: 8 << 20) { offset, chunk in
            guard !isCancelled() else { throw WriteError.cancelled }
            var written = 0
            let position = off_t(fileOffset + (offset - range.lowerBound))
            while written < chunk.count {
                let n = pwrite(fd, chunk.baseAddress! + written, chunk.count - written, position + off_t(written))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WriteError.writeFailed(path: path, code: errno)
                }
                written += n
            }
            if total > 0 { progress(Double(done + offset - range.lowerBound + UInt64(chunk.count)) / Double(total)) }
            return true
        }
    }
}
