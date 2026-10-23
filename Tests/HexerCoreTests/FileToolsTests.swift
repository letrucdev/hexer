import Foundation
import Testing
@testable import HexerCore

@Suite struct FileToolsTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hexer-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func partNamesCountFromOne() {
        let base = URL(fileURLWithPath: "/tmp/data.bin")
        #expect(FileTools.partURLs(base: base, count: 3).map(\.lastPathComponent) == ["data.bin.001", "data.bin.002", "data.bin.003"])
        #expect(FileTools.partURLs(base: base, count: 1200).last?.lastPathComponent == "data.bin.1200")
        #expect(FileTools.partCount(length: 10, partSize: 4) == 3)
        #expect(FileTools.partCount(length: 0, partSize: 4) == 0)
    }

    @Test func splitThenConcatenateRestoresTheFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<100_003).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let source = dir.appendingPathComponent("source.bin")
        try Data(bytes).write(to: source)

        let parts = FileTools.partURLs(base: dir.appendingPathComponent("part"), count: FileTools.partCount(length: 100_003, partSize: 30_000))
        try FileTools.split(source, partSize: 30_000, to: parts)
        #expect(parts.count == 4)
        #expect(try Data(contentsOf: parts[3]).count == 10_003)

        let joined = dir.appendingPathComponent("joined.bin")
        var last = 0.0
        try FileTools.concatenate(parts, to: joined, progress: { last = $0 })
        #expect(try [UInt8](Data(contentsOf: joined)) == bytes)
        #expect(last == 1)
    }

    @Test func overwritePassesAndWipe() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.bin")
        try Data(repeating: 0x41, count: 5000).write(to: url)

        let fd = open(url.path, O_RDWR)
        try FileTools.overwrite(fd: fd, path: url.path, range: 100..<200, passes: [.pattern([0x00]), .pattern([0xFF, 0xEE])])
        close(fd)
        let data = try [UInt8](Data(contentsOf: url))
        #expect(data[99] == 0x41 && data[100] == 0xFF && data[101] == 0xEE && data[199] == 0xEE && data[200] == 0x41)

        try FileTools.wipe(url, passes: [.pattern([0])])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func cancelledSplitLeavesNoParts() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.bin")
        try Data(repeating: 1, count: 1000).write(to: source)
        let parts = FileTools.partURLs(base: dir.appendingPathComponent("p"), count: 10)
        #expect(throws: CancellationError.self) {
            try FileTools.split(source, partSize: 100, to: parts, isCancelled: { true })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["source.bin"])
    }
}
