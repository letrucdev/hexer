/// A caret position with an optional selection, as byte boundaries (0...length).
///
/// The selected bytes are `range`; `caret` is the end the user is moving.
public struct Selection: Equatable, Sendable {
    public var anchor: UInt64
    public var caret: UInt64

    public init(anchor: UInt64, caret: UInt64) {
        self.anchor = anchor
        self.caret = caret
    }

    public init(caret: UInt64) { self.init(anchor: caret, caret: caret) }

    public init(range: Range<UInt64>) { self.init(anchor: range.lowerBound, caret: range.upperBound) }

    public var range: Range<UInt64> { min(anchor, caret)..<max(anchor, caret) }
    public var isEmpty: Bool { anchor == caret }
    public var length: UInt64 { range.upperBound - range.lowerBound }

    public func clamped(to length: UInt64) -> Selection {
        Selection(anchor: min(anchor, length), caret: min(caret, length))
    }
}

public enum EditError: Error, Equatable {
    case readOnly
    case sizeChangeNotAllowed
    case outOfRange
}

/// One undoable change: the trees before and after it, plus the selections to restore.
public struct EditStep: Sendable {
    public var name: String
    public var before: PieceTree
    public var after: PieceTree
    public var beforeGeneration: Int
    public var afterGeneration: Int
    public var selectionBefore: Selection
    public var selectionAfter: Selection
    /// Consecutive steps with the same key (e.g. typing at the advancing caret) merge into one.
    public var coalesceKey: String?
}

/// The editable byte sequence of a document, with unlimited undo.
///
/// Not thread-safe: use it from one actor (the main actor in the app) and hand `snapshot()`s to
/// background work.
public final class EditableBuffer {
    public let registry: SourceRegistry
    public let addBuffer: AddBuffer
    public let cache: ChunkCache
    public private(set) var tree: PieceTree
    public private(set) var undoStack: [EditStep] = []
    public private(set) var redoStack: [EditStep] = []
    /// Fixed-size media (disks) only allow overwriting.
    public let isFixedSize: Bool
    public var isReadOnly = false
    /// The id under which `init(source:)` registered its source.
    public let initialSourceID: UInt32?

    private var generation = 0
    private var generationCounter = 0
    private var savedGeneration: Int? = 0

    /// Called after every change of `tree` (edit, undo, redo, revert) with the affected range of
    /// the new tree, or nil when everything may have changed.
    public var onChange: ((Range<UInt64>?) -> Void)?

    public init(source: (any ByteSource)?, registry: SourceRegistry = SourceRegistry(), cache: ChunkCache = ChunkCache()) {
        self.registry = registry
        self.addBuffer = AddBuffer()
        self.cache = cache
        initialSourceID = source.map { registry.register($0) }
        if let source, let id = initialSourceID, source.length > 0 {
            tree = PieceTree(pieces: [Piece(.source(id), start: 0, length: source.length)])
        } else {
            tree = PieceTree()
        }
        isFixedSize = source?.isFixedSize ?? false
    }

    public init(pieces: [Piece], registry: SourceRegistry, isFixedSize: Bool = false, cache: ChunkCache = ChunkCache()) {
        self.registry = registry
        self.addBuffer = AddBuffer()
        self.cache = cache
        self.tree = PieceTree(pieces: pieces)
        self.isFixedSize = isFixedSize
        self.initialSourceID = nil
    }

    public var length: UInt64 { tree.length }
    public var isModified: Bool { savedGeneration != generation }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    public func snapshot() -> ByteSnapshot {
        ByteSnapshot(tree: tree, registry: registry, added: addBuffer.snapshot(), cache: cache)
    }

    // MARK: Edits

    /// Replaces `range` with `pieces` as one undoable step named `name`.
    public func apply(_ name: String, replacing range: Range<UInt64>, with pieces: [Piece],
                      selectionBefore: Selection, selectionAfter: Selection, coalesceKey: String? = nil) throws {
        guard !isReadOnly else { throw EditError.readOnly }
        guard range.upperBound <= length else { throw EditError.outOfRange }
        let newLength = pieces.reduce(UInt64(0)) { $0 + $1.length }
        if isFixedSize && newLength != range.upperBound - range.lowerBound { throw EditError.sizeChangeNotAllowed }
        let newTree = tree.replacing(range, with: pieces)
        commit(name, newTree, selectionBefore: selectionBefore, selectionAfter: selectionAfter, coalesceKey: coalesceKey)
        onChange?(newLength == range.upperBound - range.lowerBound ? range : nil)
    }

    /// Replaces the whole tree in one step (used by replace-all and imports).
    public func apply(_ name: String, tree newTree: PieceTree, selectionBefore: Selection, selectionAfter: Selection) throws {
        guard !isReadOnly else { throw EditError.readOnly }
        if isFixedSize && newTree.length != length { throw EditError.sizeChangeNotAllowed }
        commit(name, newTree, selectionBefore: selectionBefore, selectionAfter: selectionAfter, coalesceKey: nil)
        onChange?(nil)
    }

    /// Pieces holding `bytes`, which are appended to the add buffer.
    public func addPieces(_ bytes: [UInt8]) -> [Piece] {
        guard !bytes.isEmpty else { return [] }
        let start = addBuffer.append(bytes)
        return [Piece(.add, start: start, length: UInt64(bytes.count))]
    }

    public func generatedPieces(_ generator: Generator, count: UInt64) -> [Piece] {
        guard count > 0 else { return [] }
        return [Piece(.generator(registry.register(generator)), start: 0, length: count)]
    }

    public func insert(_ bytes: [UInt8], at offset: UInt64, name: String = "Insert",
                       selectionBefore: Selection, coalesceKey: String? = nil) throws {
        try apply(name, replacing: offset..<offset, with: addPieces(bytes), selectionBefore: selectionBefore,
                  selectionAfter: Selection(caret: offset + UInt64(bytes.count)), coalesceKey: coalesceKey)
    }

    /// Overwrites bytes starting at `offset`; writing past the end appends (unless fixed-size).
    public func overwrite(_ bytes: [UInt8], at offset: UInt64, name: String = "Overwrite",
                          selectionBefore: Selection, selectionAfter: Selection? = nil, coalesceKey: String? = nil) throws {
        var bytes = bytes
        if isFixedSize { bytes = Array(bytes.prefix(Int(min(UInt64(bytes.count), length - min(offset, length))))) }
        let end = min(offset + UInt64(bytes.count), length)
        try apply(name, replacing: offset..<end, with: addPieces(bytes), selectionBefore: selectionBefore,
                  selectionAfter: selectionAfter ?? Selection(caret: offset + UInt64(bytes.count)), coalesceKey: coalesceKey)
    }

    public func delete(_ range: Range<UInt64>, name: String = "Delete", selectionBefore: Selection) throws {
        try apply(name, replacing: range, with: [], selectionBefore: selectionBefore,
                  selectionAfter: Selection(caret: range.lowerBound))
    }

    // MARK: Undo

    @discardableResult
    public func undo() -> Selection? {
        guard let step = undoStack.popLast() else { return nil }
        tree = step.before
        generation = step.beforeGeneration
        redoStack.append(step)
        onChange?(nil)
        return step.selectionBefore
    }

    @discardableResult
    public func redo() -> Selection? {
        guard let step = redoStack.popLast() else { return nil }
        tree = step.after
        generation = step.afterGeneration
        undoStack.append(step)
        onChange?(nil)
        return step.selectionAfter
    }

    /// Stops the current typing group, so the next keystroke starts a new undo step.
    public func breakCoalescing() {
        if !undoStack.isEmpty { undoStack[undoStack.count - 1].coalesceKey = nil }
    }

    /// Marks the current state as saved; `tree` may be replaced by an equivalent one (e.g. a
    /// single piece referring to the newly written file).
    public func markSaved(replacingTreeWith equivalent: PieceTree? = nil) {
        if let equivalent {
            precondition(equivalent.length == tree.length)
            // Every step that produced the current tree now refers to the equivalent one.
            if let i = undoStack.indices.last, undoStack[i].afterGeneration == generation { undoStack[i].after = equivalent }
            if let i = redoStack.indices.last, redoStack[i].beforeGeneration == generation { redoStack[i].before = equivalent }
            tree = equivalent
        }
        savedGeneration = generation
        breakCoalescing()
    }

    /// Forgets all history (after an irreversible direct write).
    public func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func commit(_ name: String, _ newTree: PieceTree, selectionBefore: Selection, selectionAfter: Selection, coalesceKey: String?) {
        generationCounter += 1
        let newGeneration = generationCounter
        if let key = coalesceKey, var top = undoStack.last, top.coalesceKey == key, redoStack.isEmpty,
           top.afterGeneration == generation, savedGeneration != generation {
            top.after = newTree
            top.afterGeneration = newGeneration
            top.selectionAfter = selectionAfter
            undoStack[undoStack.count - 1] = top
        } else {
            undoStack.append(EditStep(name: name, before: tree, after: newTree, beforeGeneration: generation,
                                      afterGeneration: newGeneration, selectionBefore: selectionBefore,
                                      selectionAfter: selectionAfter, coalesceKey: coalesceKey))
        }
        redoStack.removeAll()
        tree = newTree
        generation = newGeneration
    }
}
