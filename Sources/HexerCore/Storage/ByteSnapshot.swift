/// How a byte on screen came to be.
public enum ByteState: UInt8, Sendable {
    case original, modified, undefined, unreadable
}

/// An immutable, thread-safe view of the document's bytes at one point in its history.
public struct ByteSnapshot: Sendable {
    public let tree: PieceTree
    public let registry: SourceRegistry
    public let added: AddBufferSnapshot
    let cache: ChunkCache?

    public init(tree: PieceTree, registry: SourceRegistry, added: AddBufferSnapshot, cache: ChunkCache? = nil) {
        self.tree = tree
        self.registry = registry
        self.added = added
        self.cache = cache
    }

    public var length: UInt64 { tree.length }

    /// The bytes of `range` as a snapshot of their own, starting at offset 0 (e.g. to compare
    /// two selections that start at different offsets).
    public func slice(_ range: Range<UInt64>) -> ByteSnapshot {
        let range = clamp(range)
        let pieces = tree.pieces(in: range).map(\.piece)
        return ByteSnapshot(tree: PieceTree(pieces: pieces), registry: registry, added: added, cache: cache)
    }

    /// Reads a small range for display, with the state of every byte.
    public func read(_ range: Range<UInt64>) -> (bytes: [UInt8], states: [ByteState]) {
        let range = clamp(range)
        let count = Int(range.upperBound - range.lowerBound)
        var bytes = [UInt8](repeating: 0, count: count)
        var states = [ByteState](repeating: .original, count: count)
        bytes.withUnsafeMutableBytes { dest in
            states.withUnsafeMutableBufferPointer { st in
                tree.forEachPiece(in: range) { piece, offset in
                    let at = Int(offset - range.lowerBound)
                    let slot = UnsafeMutableRawBufferPointer(rebasing: dest[at..<at + Int(piece.length)])
                    fill(piece, into: slot, states: UnsafeMutableBufferPointer(rebasing: st[at..<at + Int(piece.length)]), cached: true)
                    return true
                }
            }
        }
        return (bytes, states)
    }

    /// Copies a range for bulk processing; undefined and unreadable bytes read as zero.
    /// Returns `false` if any byte in the range was undefined or unreadable.
    @discardableResult
    public func copyBytes(_ range: Range<UInt64>, into dest: UnsafeMutableRawBufferPointer) -> Bool {
        precondition(Int(range.upperBound - range.lowerBound) <= dest.count)
        var complete = true
        tree.forEachPiece(in: clamp(range)) { piece, offset in
            let at = Int(offset - range.lowerBound)
            let slot = UnsafeMutableRawBufferPointer(rebasing: dest[at..<at + Int(piece.length)])
            if !fill(piece, into: slot, states: nil, cached: false) { complete = false }
            return true
        }
        return complete
    }

    public func bytes(_ range: Range<UInt64>) -> [UInt8] {
        let range = clamp(range)
        var out = [UInt8](repeating: 0, count: Int(range.upperBound - range.lowerBound))
        out.withUnsafeMutableBytes { _ = copyBytes(range, into: $0) }
        return out
    }

    /// Feeds `range` to `body` in chunks of at most `chunkSize` bytes. Returning `false` stops.
    public func forEachChunk(in range: Range<UInt64>, chunkSize: Int = 4 << 20,
                             _ body: (UInt64, UnsafeRawBufferPointer) throws -> Bool) rethrows {
        let range = clamp(range)
        guard !range.isEmpty else { return }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var offset = range.lowerBound
        while offset < range.upperBound {
            let n = Int(min(UInt64(chunkSize), range.upperBound - offset))
            copyBytes(offset..<offset + UInt64(n), into: buffer)
            guard try body(offset, UnsafeRawBufferPointer(rebasing: buffer[0..<n])) else { return }
            offset += UInt64(n)
        }
    }

    private func clamp(_ range: Range<UInt64>) -> Range<UInt64> {
        min(range.lowerBound, length)..<min(range.upperBound, length)
    }

    /// Fills `dest` with the bytes of `piece`; returns `false` for undefined or unreadable data.
    @discardableResult
    private func fill(_ piece: Piece, into dest: UnsafeMutableRawBufferPointer,
                      states: UnsafeMutableBufferPointer<ByteState>?, cached: Bool) -> Bool {
        func mark(_ s: ByteState, _ r: Range<Int>? = nil) {
            guard let states else { return }
            let r = r ?? 0..<states.count
            for i in r { states[i] = s }
        }
        switch piece.ref.kind {
        case .add:
            added.copy(piece.start..<piece.start + piece.length, into: dest.baseAddress!)
            mark(.modified)
            return true
        case .generator(let id):
            guard let g = registry.generator(id) else {
                dest.initializeMemory(as: UInt8.self, repeating: 0)
                mark(.unreadable)
                return false
            }
            g.fill(dest, streamOffset: piece.start)
            mark(.modified)
            return true
        case .undefined:
            dest.initializeMemory(as: UInt8.self, repeating: 0)
            mark(.undefined)
            return false
        case .source(let id):
            guard let source = registry.source(id) else {
                dest.initializeMemory(as: UInt8.self, repeating: 0)
                mark(.unreadable)
                return false
            }
            if cached, let cache {
                return fillCached(piece, sourceID: id, source: source, cache: cache, into: dest, mark: mark)
            }
            var ok = true
            do {
                let n = try source.read(into: dest, at: piece.start)
                if n < dest.count {
                    (dest.baseAddress! + n).initializeMemory(as: UInt8.self, repeating: 0, count: dest.count - n)
                    mark(.unreadable, n..<dest.count)
                    ok = false
                }
            } catch {
                dest.initializeMemory(as: UInt8.self, repeating: 0)
                mark(.unreadable)
                ok = false
            }
            return ok
        }
    }

    private func fillCached(_ piece: Piece, sourceID: UInt32, source: any ByteSource, cache: ChunkCache,
                            into dest: UnsafeMutableRawBufferPointer,
                            mark: (ByteState, Range<Int>?) -> Void) -> Bool {
        let blockSize = UInt64(ChunkCache.blockSize)
        var pos = piece.start
        let end = piece.start + piece.length
        var ok = true
        while pos < end {
            let block = pos / blockSize
            let inBlock = Int(pos % blockSize)
            let n = Int(min(blockSize - UInt64(inBlock), end - pos))
            let out = Int(pos - piece.start)
            let entry = cache.block(block, of: sourceID, source: source)
            let available = max(0, min(n, entry.bytes.count - inBlock))
            if entry.failed || available < n {
                ok = false
                (dest.baseAddress! + out).initializeMemory(as: UInt8.self, repeating: 0, count: n)
                mark(.unreadable, out + (entry.failed ? 0 : available)..<out + n)
            }
            if !entry.failed && available > 0 {
                entry.bytes.withUnsafeBytes { src in
                    (dest.baseAddress! + out).copyMemory(from: src.baseAddress! + inBlock, byteCount: available)
                }
            }
            pos += UInt64(n)
        }
        return ok
    }
}
