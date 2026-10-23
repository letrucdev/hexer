/// An immutable node of the persistent AVL rope behind `PieceTree`.
///
/// Every node caches subtree totals, so offset lookups, splits and joins run in O(log n) and the
/// "is anything in this range modified/undefined?" questions can skip whole subtrees.
public final class PieceNode: Sendable {
    let left: PieceNode?
    let right: PieceNode?
    let piece: Piece
    let height: Int8
    let length: UInt64
    let count: Int
    let modifiedLength: UInt64
    let undefinedLength: UInt64

    init(_ left: PieceNode?, _ piece: Piece, _ right: PieceNode?) {
        self.left = left
        self.right = right
        self.piece = piece
        height = max(left?.height ?? 0, right?.height ?? 0) + 1
        length = (left?.length ?? 0) + piece.length + (right?.length ?? 0)
        count = (left?.count ?? 0) + 1 + (right?.count ?? 0)
        modifiedLength = (left?.modifiedLength ?? 0) + (piece.ref.isModified ? piece.length : 0) + (right?.modifiedLength ?? 0)
        undefinedLength = (left?.undefinedLength ?? 0) + (piece.ref == .undefined ? piece.length : 0) + (right?.undefinedLength ?? 0)
    }
}

/// The document's byte sequence as an ordered list of pieces.
///
/// The tree is a persistent value: every edit returns a new tree that shares all untouched nodes
/// with the old one, which makes undo snapshots cost O(log n) memory and lets background jobs read
/// a snapshot while the user keeps editing.
public struct PieceTree: Sendable {
    public let root: PieceNode?

    public init() { root = nil }

    init(root: PieceNode?) { self.root = root }

    /// Builds a balanced tree from `pieces` in O(n), merging adjacent mergeable pieces.
    public init<S: Sequence>(pieces: S) where S.Element == Piece {
        root = Self.build(Self.normalized(pieces))
    }

    public var length: UInt64 { root?.length ?? 0 }
    public var pieceCount: Int { root?.count ?? 0 }
    public var modifiedLength: UInt64 { root?.modifiedLength ?? 0 }
    public var undefinedLength: UInt64 { root?.undefinedLength ?? 0 }
    public var isEmpty: Bool { root == nil }

    /// Returns a tree whose bytes in `range` are replaced by `pieces`.
    public func replacing(_ range: Range<UInt64>, with pieces: [Piece]) -> PieceTree {
        precondition(range.upperBound <= length, "range \(range) beyond length \(length)")
        let (a, rest) = Self.split(root, range.lowerBound)
        let (_, c) = Self.split(rest, range.upperBound - range.lowerBound)
        let middle = Self.build(Self.normalized(pieces))
        return PieceTree(root: Self.concat(Self.concat(a, middle), c))
    }

    public func inserting(_ pieces: [Piece], at offset: UInt64) -> PieceTree {
        replacing(offset..<offset, with: pieces)
    }

    public func removing(_ range: Range<UInt64>) -> PieceTree {
        replacing(range, with: [])
    }

    /// Calls `body` for each piece overlapping `range`, clipped to it, with its document offset.
    /// Returning `false` from `body` stops the iteration.
    public func forEachPiece(in range: Range<UInt64>, _ body: (Piece, UInt64) throws -> Bool) rethrows {
        guard !range.isEmpty else { return }
        _ = try Self.visit(root, base: 0, range: range, body)
    }

    public func pieces(in range: Range<UInt64>) -> [(piece: Piece, offset: UInt64)] {
        var out: [(Piece, UInt64)] = []
        forEachPiece(in: range) { out.append(($0, $1)); return true }
        return out
    }

    public var allPieces: [Piece] {
        var out: [Piece] = []
        out.reserveCapacity(pieceCount)
        Self.inorder(root) { out.append($0) }
        return out
    }

    /// Calls `body` with each maximal run of modified or undefined bytes, using the subtree
    /// totals to skip parts of the tree that contain none (e.g. to list undefined gaps).
    public func forEachRun(of kind: RunKind, _ body: (Range<UInt64>) -> Void) {
        var pending: Range<UInt64>?
        Self.visitRuns(root, base: 0, kind: kind) { range in
            if let p = pending, p.upperBound == range.lowerBound {
                pending = p.lowerBound..<range.upperBound
            } else {
                if let p = pending { body(p) }
                pending = range
            }
        }
        if let p = pending { body(p) }
    }

    public enum RunKind: Sendable { case modified, undefined }

    /// Checks AVL balance and cached totals; used by tests.
    public func validate() -> Bool { Self.check(root) != nil }

    // MARK: - Rope algorithms

    private static func normalized<S: Sequence>(_ pieces: S) -> [Piece] where S.Element == Piece {
        var out: [Piece] = []
        for p in pieces where p.length > 0 {
            if let last = out.last, last.canMerge(with: p) {
                out[out.count - 1].length += p.length
            } else {
                out.append(p)
            }
        }
        return out
    }

    private static func build(_ pieces: [Piece]) -> PieceNode? {
        pieces.withUnsafeBufferPointer { build($0, 0, $0.count) }
    }

    private static func build(_ p: UnsafeBufferPointer<Piece>, _ lo: Int, _ hi: Int) -> PieceNode? {
        guard lo < hi else { return nil }
        let mid = (lo + hi) / 2
        return PieceNode(build(p, lo, mid), p[mid], build(p, mid + 1, hi))
    }

    @inline(__always) private static func h(_ n: PieceNode?) -> Int { Int(n?.height ?? 0) }

    private static func rotateLeft(_ n: PieceNode) -> PieceNode {
        let r = n.right!
        return PieceNode(PieceNode(n.left, n.piece, r.left), r.piece, r.right)
    }

    private static func rotateRight(_ n: PieceNode) -> PieceNode {
        let l = n.left!
        return PieceNode(l.left, l.piece, PieceNode(l.right, n.piece, n.right))
    }

    static func join(_ l: PieceNode?, _ p: Piece, _ r: PieceNode?) -> PieceNode {
        let hl = h(l), hr = h(r)
        if hl > hr + 1 { return joinRight(l!, p, r) }
        if hr > hl + 1 { return joinLeft(l, p, r!) }
        return PieceNode(l, p, r)
    }

    private static func joinRight(_ l: PieceNode, _ p: Piece, _ r: PieceNode?) -> PieceNode {
        if h(l.right) <= h(r) + 1 {
            let t = PieceNode(l.right, p, r)
            if h(t) <= h(l.left) + 1 { return PieceNode(l.left, l.piece, t) }
            return rotateLeft(PieceNode(l.left, l.piece, rotateRight(t)))
        }
        let t = joinRight(l.right!, p, r)
        let n = PieceNode(l.left, l.piece, t)
        return h(t) <= h(l.left) + 1 ? n : rotateLeft(n)
    }

    private static func joinLeft(_ l: PieceNode?, _ p: Piece, _ r: PieceNode) -> PieceNode {
        if h(r.left) <= h(l) + 1 {
            let t = PieceNode(l, p, r.left)
            if h(t) <= h(r.right) + 1 { return PieceNode(t, r.piece, r.right) }
            return rotateRight(PieceNode(rotateLeft(t), r.piece, r.right))
        }
        let t = joinLeft(l, p, r.left!)
        let n = PieceNode(t, r.piece, r.right)
        return h(t) <= h(r.right) + 1 ? n : rotateRight(n)
    }

    /// Splits so that the left tree holds exactly the first `k` bytes.
    static func split(_ n: PieceNode?, _ k: UInt64) -> (PieceNode?, PieceNode?) {
        guard let n else { return (nil, nil) }
        let ll = n.left?.length ?? 0
        if k < ll {
            let (a, b) = split(n.left, k)
            return (a, join(b, n.piece, n.right))
        }
        if k == ll { return (n.left, join(nil, n.piece, n.right)) }
        let pieceEnd = ll + n.piece.length
        if k < pieceEnd {
            let cut = k - ll
            let first = n.piece.slice(from: 0, length: cut)
            let second = n.piece.slice(from: cut, length: n.piece.length - cut)
            return (join(n.left, first, nil), join(nil, second, n.right))
        }
        if k == pieceEnd { return (join(n.left, n.piece, nil), n.right) }
        let (a, b) = split(n.right, k - pieceEnd)
        return (join(n.left, n.piece, a), b)
    }

    private static func splitLast(_ n: PieceNode) -> (PieceNode?, Piece) {
        guard let r = n.right else { return (n.left, n.piece) }
        let (rest, last) = splitLast(r)
        return (join(n.left, n.piece, rest), last)
    }

    private static func splitFirst(_ n: PieceNode) -> (Piece, PieceNode?) {
        guard let l = n.left else { return (n.piece, n.right) }
        let (first, rest) = splitFirst(l)
        return (first, join(rest, n.piece, n.right))
    }

    /// Concatenates two trees, merging the boundary pieces when they are contiguous.
    static func concat(_ l: PieceNode?, _ r: PieceNode?) -> PieceNode? {
        guard let l else { return r }
        guard let r else { return l }
        let (lRest, last) = splitLast(l)
        let (first, rRest) = splitFirst(r)
        if last.canMerge(with: first) {
            var merged = last
            merged.length += first.length
            return join(lRest, merged, rRest)
        }
        return join(lRest, last, join(nil, first, rRest))
    }

    private static func visit(_ n: PieceNode?, base: UInt64, range: Range<UInt64>,
                              _ body: (Piece, UInt64) throws -> Bool) rethrows -> Bool {
        guard let n else { return true }
        let pieceStart = base + (n.left?.length ?? 0)
        let pieceEnd = pieceStart + n.piece.length
        if range.lowerBound < pieceStart {
            guard try visit(n.left, base: base, range: range, body) else { return false }
        }
        if pieceStart < range.upperBound && pieceEnd > range.lowerBound {
            let lo = max(pieceStart, range.lowerBound), hi = min(pieceEnd, range.upperBound)
            guard try body(n.piece.slice(from: lo - pieceStart, length: hi - lo), lo) else { return false }
        }
        if range.upperBound > pieceEnd {
            guard try visit(n.right, base: pieceEnd, range: range, body) else { return false }
        }
        return true
    }

    private static func visitRuns(_ n: PieceNode?, base: UInt64, kind: RunKind, _ body: (Range<UInt64>) -> Void) {
        guard let n else { return }
        let relevant = kind == .modified ? n.modifiedLength : n.undefinedLength
        guard relevant > 0 else { return }
        let pieceStart = base + (n.left?.length ?? 0)
        visitRuns(n.left, base: base, kind: kind, body)
        let matches = kind == .modified ? n.piece.ref.isModified : n.piece.ref == .undefined
        if matches { body(pieceStart..<pieceStart + n.piece.length) }
        visitRuns(n.right, base: pieceStart + n.piece.length, kind: kind, body)
    }

    private static func inorder(_ n: PieceNode?, _ body: (Piece) -> Void) {
        guard let n else { return }
        inorder(n.left, body)
        body(n.piece)
        inorder(n.right, body)
    }

    private static func check(_ n: PieceNode?) -> (height: Int, length: UInt64)? {
        guard let n else { return (0, 0) }
        guard let l = check(n.left), let r = check(n.right), abs(l.height - r.height) <= 1,
              n.piece.length > 0,
              Int(n.height) == max(l.height, r.height) + 1,
              n.length == l.length + n.piece.length + r.length else { return nil }
        return (Int(n.height), n.length)
    }
}
