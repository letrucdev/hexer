import Foundation
import HexerCore
import Testing
@testable import HexerPlatform

/// Shared by the file-backed tests here and the attached-image tests: edits a disk document,
/// saves it with `DiskWriter`, and returns the bytes the disk should now hold.
func editAndSave(source: DiskByteSource, original: [UInt8], writeDescriptor fd: Int32,
                 progress: Collector<Double>? = nil) throws -> [UInt8] {
    let buffer = EditableBuffer(source: source)
    let id = try #require(buffer.initialSourceID)
    let sel = Selection(caret: 0)
    var expected = original
    let n = original.count
    let edits: [(Int, [UInt8])] = [
        (3, [0xA1, 0xA2]),                                    // inside the first sector
        (511, [0xB1, 0xB2]),                                  // straddles a sector boundary
        (4096, [0xC1]),                                       // one byte at an aligned offset
        (10_000, Array(repeating: 0xD1, count: 9_000)),       // spans many sectors, unaligned ends
        (n - 1, [0xE1]),                                      // the last byte
    ]
    for (offset, bytes) in edits {
        try buffer.overwrite(bytes, at: UInt64(offset), selectionBefore: sel)
        expected.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
    // Swap two 4 KiB blocks by referring to the disk itself at other offsets: saving must not
    // read bytes it has already overwritten.
    let a = 65536, b = 69632 + 100
    try buffer.apply("Swap", replacing: UInt64(a)..<UInt64(a + 4096),
                     with: [Piece(.source(id), start: UInt64(b), length: 4096)], selectionBefore: sel, selectionAfter: sel)
    try buffer.apply("Swap", replacing: UInt64(b)..<UInt64(b + 4096),
                     with: [Piece(.source(id), start: UInt64(a), length: 4096)], selectionBefore: sel, selectionAfter: sel)
    expected.replaceSubrange(a..<a + 4096, with: original[b..<b + 4096])
    expected.replaceSubrange(b..<b + 4096, with: original[a..<a + 4096])

    let snapshot = buffer.snapshot()
    let ranges = FileWriter.changedRanges(in: snapshot.tree, base: id)
    #expect(DiskWriter.readsOwnChanges(snapshot, ranges: ranges, base: id))
    try DiskWriter.write(snapshot, changedRanges: ranges, to: fd, sectorSize: source.sectorSize, baseSourceID: id,
                         progress: { progress?.append($0) })
    return expected
}

@Suite struct DiskWriterTests {
    @Test func readModifyWriteChangesExactlyTheEditedBytes() throws {
        let original = randomBytes(256 * 1024, seed: 11)
        let url = try Scratch.file(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DiskByteSource(path: url.path, sectorSize: 512)
        let fd = open(url.path, O_RDWR)
        defer { close(fd) }
        let progress = Collector<Double>()
        let expected = try editAndSave(source: source, original: original, writeDescriptor: fd, progress: progress)
        let written = try [UInt8](Data(contentsOf: url))
        #expect(written.count == original.count)
        #expect(written == expected)
        #expect(progress.all.last == 1)
        #expect(progress.all == progress.all.sorted())
    }

    @Test func plainOverwritesAreNotStaged() throws {
        let buffer = EditableBuffer(source: MemoryByteSource(randomBytes(8192, seed: 3), fixedSize: true))
        let id = try #require(buffer.initialSourceID)
        try buffer.overwrite([1, 2, 3], at: 100, selectionBefore: Selection(caret: 0))
        // A copy from an unchanged part of the disk is safe too.
        try buffer.apply("Copy", replacing: 4096..<4196, with: [Piece(.source(id), start: 0, length: 100)],
                         selectionBefore: Selection(caret: 0), selectionAfter: Selection(caret: 0))
        let snapshot = buffer.snapshot()
        #expect(!DiskWriter.readsOwnChanges(snapshot, ranges: FileWriter.changedRanges(in: snapshot.tree, base: id), base: id))
    }

    @Test func groupsCoverWholeSectorsOnce() {
        let groups = DiskWriter.groups([3..<5, 10..<12, 511..<513, 2000..<2001], unit: 512, length: 4096)
        #expect(groups.map(\.extent) == [0..<1024, 1536..<2048])
        #expect(groups.map(\.ranges) == [[3..<5, 10..<12, 511..<513], [2000..<2001]])
        #expect(DiskWriter.normalized([10..<20, 0..<5, 15..<30, 40..<40, 90..<200], length: 100) == [0..<5, 10..<30, 90..<100])
    }

    @Test func cancellationLeavesTheDiskUntouched() throws {
        let original = randomBytes(8192, seed: 5)
        let url = try Scratch.file(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = EditableBuffer(source: try DiskByteSource(path: url.path))
        try buffer.overwrite([0], at: 10, selectionBefore: Selection(caret: 0))
        let fd = open(url.path, O_RDWR)
        defer { close(fd) }
        #expect(throws: DiskIOError.cancelled) {
            try DiskWriter.write(buffer.snapshot(), changedRanges: [10..<11], to: fd, sectorSize: 512,
                                 baseSourceID: buffer.initialSourceID, isCancelled: { true })
        }
        #expect(try [UInt8](Data(contentsOf: url)) == original)
    }

    @Test func changesBeyondTheDiskAreRejected() throws {
        let url = try Scratch.file([UInt8](repeating: 0, count: 1024))
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = EditableBuffer(source: MemoryByteSource(randomBytes(2048, seed: 1)))
        let fd = open(url.path, O_RDWR)
        defer { close(fd) }
        #expect(throws: DiskIOError.tooLarge(required: 2048, available: 1024)) {
            try DiskWriter.write(buffer.snapshot(), changedRanges: [1000..<1100], to: fd, sectorSize: 512, baseSourceID: nil)
        }
        #expect(throws: DiskIOError.invalidSectorSize(0)) {
            try DiskWriter.write(buffer.snapshot(), changedRanges: [0..<1], to: fd, sectorSize: 0, baseSourceID: nil)
        }
    }
}
