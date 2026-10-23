/// Builds the result of Replace all as a new `PieceTree` in one pass.
///
/// Typical flow: compile the search and `SearchEngine.compileReplacement`; on fixed-size buffers call
/// `CompiledReplacement.validateFixedSize()`; when `changesLength`, ask (HxD: "This replace operation
/// changes the file size. Do you want to proceed?"); collect `findMatches` on a background task; then, on
/// the buffer's actor, add each distinct replacement once with `EditableBuffer.addPieces`, build the tree
/// with `replacingAll`, and commit it with `EditableBuffer.apply(_:tree:selectionBefore:selectionAfter:)`.
/// For "Prompt on replace", replace each confirmed hit with `apply(_:replacing:with:...)` and continue the
/// search after the inserted bytes.
public enum ReplaceEngine {
    /// The non-overlapping matches Replace all would replace (all of them, no limit).
    public static func findMatches(in snapshot: ByteSnapshot, search: CompiledSearch, range: Range<UInt64>? = nil,
                                   chunkSize: Int = SearchEngine.defaultChunkSize, isCancelled: () -> Bool = { false },
                                   progress: (Double) -> Void = { _ in }) throws -> [Range<UInt64>] {
        try SearchEngine.findAll(in: snapshot, query: search, range: range, chunkSize: chunkSize,
                                 isCancelled: isCancelled, progress: progress).matches
    }

    /// Sorts `matches` and drops each one overlapping an earlier kept one (and empty ones).
    public static func nonOverlapping(_ matches: [Range<UInt64>]) -> [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        for m in matches.sorted(by: { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }) where !m.isEmpty {
            if let last = out.last, m.lowerBound < last.upperBound { continue }
            out.append(m)
        }
        return out
    }

    /// The tree of `snapshot` with every match replaced by `replacement`.
    public static func replacingAll(in snapshot: ByteSnapshot, matches: [Range<UInt64>], with replacement: [Piece]) -> PieceTree {
        replacingAll(in: snapshot.tree, matches: matches) { _ in replacement }
    }

    /// `tree` with each match replaced by the pieces `replacement` returns for it (e.g. chosen by match
    /// length for integer "(any)" searches). `matches` must be sorted, non-empty, non-overlapping and
    /// inside the tree. Runs in O(pieces + matches): the untouched pieces are sliced once and the result is
    /// rebuilt balanced, instead of one O(log n) edit per match.
    public static func replacingAll(in tree: PieceTree, matches: [Range<UInt64>],
                                    replacement: (Range<UInt64>) -> [Piece]) -> PieceTree {
        guard !matches.isEmpty else { return tree }
        var previousEnd: UInt64 = 0
        for m in matches {
            precondition(!m.isEmpty && m.lowerBound >= previousEnd, "matches must be sorted, non-empty and non-overlapping")
            previousEnd = m.upperBound
        }
        precondition(previousEnd <= tree.length, "match beyond the end of the tree")
        var out: [Piece] = []
        out.reserveCapacity(tree.pieceCount + 2 * matches.count)
        var index = 0
        tree.forEachPiece(in: 0..<tree.length) { piece, offset in
            let end = offset + piece.length
            var at = offset
            while at < end {
                guard index < matches.count else {
                    out.append(piece.slice(from: at - offset, length: end - at))
                    break
                }
                let m = matches[index]
                if at < m.lowerBound {
                    let stop = min(end, m.lowerBound)
                    out.append(piece.slice(from: at - offset, length: stop - at))
                    at = stop
                } else {
                    if at == m.lowerBound { out += replacement(m) }
                    at = min(end, m.upperBound)
                    if at == m.upperBound { index += 1 }
                }
            }
            return true
        }
        return PieceTree(pieces: out)
    }
}
