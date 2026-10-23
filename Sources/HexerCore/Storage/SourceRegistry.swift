import Synchronization

/// Maps the ids stored in pieces to byte sources and generators.
///
/// Pieces in every undo state refer to sources by id, so remapping an id (e.g. to an overlay that
/// preserves the old bytes after an in-place save) updates all of history at once.
public final class SourceRegistry: Sendable {
    private struct State {
        var sources: [UInt32: any ByteSource] = [:]
        var generators: [UInt32: Generator] = [:]
        var generatorIDs: [Generator: UInt32] = [:]
        var nextSource: UInt32 = 1
        var nextGenerator: UInt32 = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func register(_ source: any ByteSource) -> UInt32 {
        state.withLock { s in
            let id = s.nextSource
            s.nextSource += 1
            s.sources[id] = source
            return id
        }
    }

    /// Points `id` at a different source with the same content for existing pieces.
    public func remap(_ id: UInt32, to source: any ByteSource) {
        state.withLock { $0.sources[id] = source }
    }

    public func source(_ id: UInt32) -> (any ByteSource)? {
        state.withLock { $0.sources[id] }
    }

    /// Returns the id of `generator`, registering it the first time it is seen.
    public func register(_ generator: Generator) -> UInt32 {
        state.withLock { s in
            if let id = s.generatorIDs[generator] { return id }
            let id = s.nextGenerator
            s.nextGenerator += 1
            s.generators[id] = generator
            s.generatorIDs[generator] = id
            return id
        }
    }

    public func generator(_ id: UInt32) -> Generator? {
        state.withLock { $0.generators[id] }
    }
}
