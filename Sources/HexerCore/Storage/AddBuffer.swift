import Synchronization

/// Append-only storage for bytes added while editing.
///
/// Memory is allocated in fixed blocks that never move or shrink, so a snapshot taken at any
/// time can keep reading its prefix from a background thread while new bytes are appended, and
/// undo/redo can always refer back to earlier appends.
public final class AddBuffer: Sendable {
    static let blockSize = 1 << 20

    final class Block: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        init() { pointer = .allocate(byteCount: AddBuffer.blockSize, alignment: 16) }
        deinit { pointer.deallocate() }
    }

    private struct State {
        var blocks: [Block] = []
        var count: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    public var count: UInt64 { state.withLock { $0.count } }

    /// Appends `bytes` and returns the offset of the first one.
    @discardableResult
    public func append(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        state.withLock { s in
            let start = s.count
            var written = 0
            while written < bytes.count {
                let inBlock = Int(s.count % UInt64(Self.blockSize))
                if inBlock == 0 && Int(s.count / UInt64(Self.blockSize)) == s.blocks.count {
                    s.blocks.append(Block())
                }
                let block = s.blocks[Int(s.count / UInt64(Self.blockSize))]
                let n = min(Self.blockSize - inBlock, bytes.count - written)
                (block.pointer + inBlock).copyMemory(from: bytes.baseAddress! + written, byteCount: n)
                written += n
                s.count += UInt64(n)
            }
            return start
        }
    }

    @discardableResult
    public func append(_ bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBytes { append($0) }
    }

    public func snapshot() -> AddBufferSnapshot {
        state.withLock { AddBufferSnapshot(blocks: $0.blocks, count: $0.count) }
    }
}

/// A read-only view of the first `count` bytes of an `AddBuffer`.
public struct AddBufferSnapshot: Sendable {
    let blocks: [AddBuffer.Block]
    public let count: UInt64

    public func copy(_ range: Range<UInt64>, into dest: UnsafeMutableRawPointer) {
        precondition(range.upperBound <= count)
        var offset = range.lowerBound
        var out = dest
        while offset < range.upperBound {
            let blockIndex = Int(offset / UInt64(AddBuffer.blockSize))
            let inBlock = Int(offset % UInt64(AddBuffer.blockSize))
            let n = Int(min(UInt64(AddBuffer.blockSize - inBlock), range.upperBound - offset))
            out.copyMemory(from: blocks[blockIndex].pointer + inBlock, byteCount: n)
            out += n
            offset += UInt64(n)
        }
    }
}
