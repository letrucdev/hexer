import Synchronization

/// A small LRU cache of fixed-size blocks read from byte sources, for the UI's many small reads.
///
/// Bulk jobs (search, checksums, save) bypass it so they don't evict what is on screen.
public final class ChunkCache: Sendable {
    public static let blockSize = 64 * 1024

    struct Key: Hashable {
        let source: UInt32
        let block: UInt64
    }

    final class Entry: Sendable {
        let bytes: [UInt8]
        /// Set when the read failed; the block is then treated as unreadable.
        let failed: Bool
        init(bytes: [UInt8], failed: Bool) {
            self.bytes = bytes
            self.failed = failed
        }
    }

    private struct State {
        var entries: [Key: (entry: Entry, stamp: UInt64)] = [:]
        var clock: UInt64 = 0
    }

    private let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int = 512) { self.capacity = capacity }

    func block(_ index: UInt64, of sourceID: UInt32, source: any ByteSource) -> Entry {
        let key = Key(source: sourceID, block: index)
        if let hit = state.withLock({ s -> Entry? in
            guard let e = s.entries[key] else { return nil }
            s.clock += 1
            s.entries[key] = (e.entry, s.clock)
            return e.entry
        }) {
            return hit
        }
        let offset = index * UInt64(Self.blockSize)
        let size = Int(min(UInt64(Self.blockSize), source.length > offset ? source.length - offset : 0))
        var bytes = [UInt8](repeating: 0, count: size)
        var failed = false
        do {
            let n = try bytes.withUnsafeMutableBytes { try source.read(into: $0, at: offset) }
            if n < size { bytes.removeSubrange(n...) }
        } catch {
            failed = true
        }
        let entry = Entry(bytes: bytes, failed: failed)
        state.withLock { s in
            s.clock += 1
            s.entries[key] = (entry, s.clock)
            if s.entries.count > capacity, let oldest = s.entries.min(by: { $0.value.stamp < $1.value.stamp }) {
                s.entries.removeValue(forKey: oldest.key)
            }
        }
        return entry
    }

    /// Drops cached blocks of `sourceID` (after the file changed on disk or was saved).
    public func invalidate(source sourceID: UInt32) {
        state.withLock { s in s.entries = s.entries.filter { $0.key.source != sourceID } }
    }

    public func removeAll() {
        state.withLock { $0.entries.removeAll() }
    }
}
