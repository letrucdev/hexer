import Testing
@testable import HexerCore

/// A deterministic random generator so failures reproduce.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct PieceTreeTests {
    /// Reads the whole tree through a snapshot.
    func contents(_ buffer: EditableBuffer) -> [UInt8] {
        buffer.snapshot().bytes(0..<buffer.length)
    }

    @Test func emptyTree() {
        let t = PieceTree()
        #expect(t.length == 0)
        #expect(t.pieceCount == 0)
        #expect(t.validate())
    }

    @Test func buildMergesContiguousPieces() {
        let t = PieceTree(pieces: [Piece(.add, start: 0, length: 4), Piece(.add, start: 4, length: 4),
                                   Piece(.source(1), start: 0, length: 2)])
        #expect(t.pieceCount == 2)
        #expect(t.length == 10)
    }

    @Test func splitInsideAPiece() {
        let base = PieceTree(pieces: [Piece(.source(1), start: 100, length: 50)])
        let t = base.inserting([Piece(.add, start: 0, length: 3)], at: 20)
        #expect(t.allPieces == [Piece(.source(1), start: 100, length: 20), Piece(.add, start: 0, length: 3),
                                Piece(.source(1), start: 120, length: 30)])
        // The original is untouched (persistence).
        #expect(base.allPieces == [Piece(.source(1), start: 100, length: 50)])
        // Deleting the insertion merges the source pieces back into one.
        #expect(t.removing(20..<23).allPieces == [Piece(.source(1), start: 100, length: 50)])
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func randomEditsMatchArrayModel(seed: UInt64) throws {
        var rng = SeededRandom(state: seed)
        let original = (0..<5000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let buffer = EditableBuffer(source: MemoryByteSource(original))
        var model = original
        for step in 0..<1500 {
            let len = UInt64(model.count)
            let a = len == 0 ? 0 : UInt64.random(in: 0...len, using: &rng)
            let b = min(len, a + UInt64.random(in: 0...64, using: &rng))
            let insert = (0..<Int.random(in: 0...40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let sel = Selection(caret: a)
            switch step % 4 {
            case 0:
                try buffer.insert(insert, at: a, selectionBefore: sel)
                model.insert(contentsOf: insert, at: Int(a))
            case 1:
                try buffer.delete(a..<b, selectionBefore: sel)
                model.removeSubrange(Int(a)..<Int(b))
            case 2:
                try buffer.overwrite(insert, at: a, selectionBefore: sel)
                let end = min(Int(a) + insert.count, model.count)
                model.replaceSubrange(Int(a)..<end, with: insert)
            default:
                let fill = UInt64.random(in: 0...100, using: &rng)
                let pattern: [UInt8] = [0xAB, 0xCD, 0xEF]
                try buffer.apply("Fill", replacing: a..<b, with: buffer.generatedPieces(.pattern(pattern), count: fill),
                                 selectionBefore: sel, selectionAfter: sel)
                model.replaceSubrange(Int(a)..<Int(b), with: (0..<Int(fill)).map { pattern[$0 % 3] })
            }
            #expect(buffer.length == UInt64(model.count))
        }
        #expect(buffer.tree.validate())
        #expect(contents(buffer) == model)

        // Undo everything, then redo everything.
        while buffer.canUndo { buffer.undo() }
        #expect(contents(buffer) == original)
        #expect(!buffer.isModified)
        while buffer.canRedo { buffer.redo() }
        #expect(contents(buffer) == model)
    }

    @Test func readReportsStates() throws {
        let buffer = EditableBuffer(source: MemoryByteSource([1, 2, 3, 4, 5, 6]))
        try buffer.overwrite([9], at: 2, selectionBefore: Selection(caret: 2))
        try buffer.apply("Gap", replacing: 4..<4, with: [Piece.undefined(length: 2)],
                         selectionBefore: Selection(caret: 4), selectionAfter: Selection(caret: 4))
        let r = buffer.snapshot().read(0..<8)
        #expect(r.bytes == [1, 2, 9, 4, 0, 0, 5, 6])
        #expect(r.states == [.original, .original, .modified, .original, .undefined, .undefined, .original, .original])
        var gaps: [Range<UInt64>] = []
        buffer.tree.forEachRun(of: .undefined) { gaps.append($0) }
        #expect(gaps == [4..<6])
    }

    @Test func typingCoalescesIntoOneUndoStep() throws {
        let buffer = EditableBuffer(source: MemoryByteSource([0, 0, 0, 0]))
        for i in 0..<4 {
            try buffer.overwrite([UInt8(i + 1)], at: UInt64(i), selectionBefore: Selection(caret: UInt64(i)), coalesceKey: "typing")
        }
        #expect(buffer.undoStack.count == 1)
        buffer.undo()
        #expect(contents(buffer) == [0, 0, 0, 0])
    }

    @Test func fixedSizeRejectsLengthChanges() {
        let buffer = EditableBuffer(source: MemoryByteSource([0, 0, 0, 0], fixedSize: true))
        #expect(throws: EditError.sizeChangeNotAllowed) {
            try buffer.insert([1], at: 0, selectionBefore: Selection(caret: 0))
        }
        // Overwriting past the end is clipped instead of growing the disk.
        #expect(throws: Never.self) { try buffer.overwrite([1, 2, 3], at: 2, selectionBefore: Selection(caret: 2)) }
        #expect(contents(buffer) == [0, 0, 1, 2])
    }

    @Test func largeAppendSpansAddBufferBlocks() throws {
        let buffer = EditableBuffer(source: nil)
        let big = (0..<(AddBuffer.blockSize + 1000)).map { UInt8(truncatingIfNeeded: $0 * 7) }
        try buffer.insert(big, at: 0, selectionBefore: Selection(caret: 0))
        #expect(contents(buffer) == big)
    }
}
