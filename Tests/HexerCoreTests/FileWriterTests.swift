import Foundation
import Testing
@testable import HexerCore

@Suite struct FileWriterTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hexer-\(UUID().uuidString)-\(name)")
    }

    private func makeFile(_ bytes: [UInt8]) throws -> URL {
        let url = tempURL("original.bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func changedRangesSkipOnlyUnmovedBaseBytes() throws {
        let source = MemoryByteSource(Array(repeating: 7, count: 100))
        let buffer = EditableBuffer(source: source)
        let id = try #require(buffer.initialSourceID)
        let sel = Selection(caret: 0)
        try buffer.overwrite([1, 2], at: 10, selectionBefore: sel)
        try buffer.overwrite([3], at: 12, selectionBefore: sel)
        #expect(FileWriter.changedRanges(in: buffer.tree, base: id) == [10..<13])
        try buffer.insert([9], at: 50, selectionBefore: sel)
        // Everything after the insertion moved, so all of it counts as changed.
        #expect(FileWriter.changedRanges(in: buffer.tree, base: id) == [10..<13, 50..<101])
    }

    @Test func patchedCloneEqualsStreamedFile() throws {
        var rng = SystemRandomNumberGenerator()
        let original = (0..<(3 << 20)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let url = try makeFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try FileByteSource(url: url)
        let buffer = EditableBuffer(source: source)
        let id = try #require(buffer.initialSourceID)
        var expected = original
        let sel = Selection(caret: 0)
        for (offset, bytes) in [(5, [0xAA, 0xBB]), (1 << 20, [1, 2, 3, 4]), (original.count - 1, [0x55])] as [(Int, [UInt8])] {
            try buffer.overwrite(bytes, at: UInt64(offset), selectionBefore: sel)
            expected.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        try buffer.insert([0xEE, 0xFF], at: UInt64(original.count), selectionBefore: sel)
        expected += [0xEE, 0xFF]

        let patched = tempURL("patched.bin")
        defer { try? FileManager.default.removeItem(at: patched) }
        let usedClone = try FileWriter.writePatchingClone(of: url, snapshot: buffer.snapshot(), base: id, to: patched)
        #expect(usedClone)
        #expect(try [UInt8](Data(contentsOf: patched)) == expected)
        // The original file and the history that reads it are untouched.
        #expect(try [UInt8](Data(contentsOf: url)) == original)
        while buffer.canUndo { buffer.undo() }
        #expect(buffer.snapshot().bytes(0..<UInt64(original.count)) == original)

        let streamed = tempURL("streamed.bin")
        defer { try? FileManager.default.removeItem(at: streamed) }
        while buffer.canRedo { buffer.redo() }
        try FileWriter.write(buffer.snapshot(), to: streamed)
        #expect(try Data(contentsOf: streamed) == Data(contentsOf: patched))
    }

    @Test func mostlyChangedFilesAreNotPatched() throws {
        let url = try makeFile(Array(repeating: 1, count: 1000))
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = EditableBuffer(source: try FileByteSource(url: url))
        try buffer.insert([0], at: 0, selectionBefore: Selection(caret: 0))
        let out = tempURL("out.bin")
        let used = try FileWriter.writePatchingClone(of: url, snapshot: buffer.snapshot(), base: buffer.initialSourceID!, to: out)
        #expect(!used)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func writesSelectedRange() throws {
        let buffer = EditableBuffer(source: MemoryByteSource(Array(0...255)))
        let out = tempURL("range.bin")
        defer { try? FileManager.default.removeItem(at: out) }
        try FileWriter.write(buffer.snapshot(), range: 16..<32, to: out)
        #expect(try [UInt8](Data(contentsOf: out)) == Array(16..<32))
    }

    @Test func snapshotSliceStartsAtZero() throws {
        let buffer = EditableBuffer(source: MemoryByteSource(Array(0...255)))
        try buffer.overwrite([0xEE], at: 20, selectionBefore: Selection(caret: 0))
        let slice = buffer.snapshot().slice(16..<40)
        #expect(slice.length == 24)
        #expect(slice.bytes(0..<24) == Array(16..<20) + [0xEE] + Array(21..<40))
        #expect(buffer.snapshot().slice(250..<300).length == 6)
    }
}
