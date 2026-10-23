import Foundation
import HexerCore
import Testing
@testable import HexerPlatform

@Suite struct DiskByteSourceTests {
    /// 1 MiB plus a partial last sector.
    private let content = randomBytes((1 << 20) + 300, seed: 7)

    private func read(_ source: DiskByteSource, _ offset: UInt64, _ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0xEE, count: count)
        let n = try out.withUnsafeMutableBytes { try source.read(into: $0, at: offset) }
        return Array(out.prefix(n))
    }

    private func expected(_ offset: Int, _ count: Int) -> [UInt8] {
        guard offset < content.count else { return [] }
        return Array(content[offset..<min(offset + count, content.count)])
    }

    @Test func unalignedReadsOfAFileMatchItsBytes() throws {
        let url = try Scratch.file(content)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DiskByteSource(path: url.path, sectorSize: 512)
        #expect(source.length == UInt64(content.count))
        #expect(source.isFixedSize)
        #expect(!source.isDevice)
        #expect(source.sectorSize == 512)

        let cases: [(Int, Int)] = [(0, 512), (0, 1), (1, 1), (511, 2), (512, 512), (100, 70_000), (4096, 65536),
                                   (content.count - 1, 10), (content.count - 300, 300), (content.count - 1000, 5000),
                                   (content.count, 10), (content.count + 5, 10)]
        for (offset, count) in cases {
            #expect(try read(source, UInt64(offset), count) == expected(offset, count), "offset \(offset) count \(count)")
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let offset = Int.random(in: 0..<content.count, using: &rng)
            let count = Int.random(in: 1...100_000, using: &rng)
            #expect(try read(source, UInt64(offset), count) == expected(offset, count))
        }
    }

    @Test func concurrentReadsAreConsistent() throws {
        let url = try Scratch.file(content)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DiskByteSource(path: url.path, sectorSize: 4096)
        let failures = Collector<Int>()
        let content = content
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<50 {
                let offset = Int.random(in: 0..<content.count, using: &rng)
                let count = Int.random(in: 1...20_000, using: &rng)
                var out = [UInt8](repeating: 0, count: count)
                let n = (try? out.withUnsafeMutableBytes { try source.read(into: $0, at: UInt64(offset)) }) ?? -1
                if n != min(count, content.count - offset) || out[0..<max(n, 0)] != content[offset..<offset + max(n, 0)] {
                    failures.append(i)
                }
            }
        }
        #expect(failures.all.isEmpty)
    }

    @Test func badSectorsAreReportedAfterTheGoodPrefix() throws {
        let url = try Scratch.file(content)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        let source = try DiskByteSource(descriptor: fd, path: url.path, sectorSize: 512, faultySectors: [20, 21, 100])

        // Unaligned request through the scratch buffer.
        var out = [UInt8](repeating: 0, count: 65536)
        #expect(throws: ByteSourceError.unreadable(offset: 20 * 512, code: EIO)) {
            try out.withUnsafeMutableBytes { _ = try source.read(into: $0, at: 300) }
        }
        #expect(out[0..<(20 * 512 - 300)] == content[300..<20 * 512])

        // Aligned request straight into the caller's buffer.
        out = [UInt8](repeating: 0, count: 65536)
        #expect(throws: ByteSourceError.unreadable(offset: 20 * 512, code: EIO)) {
            try out.withUnsafeMutableBytes { _ = try source.read(into: $0, at: 0) }
        }
        #expect(out[0..<20 * 512] == content[0..<20 * 512])

        // A request starting inside a bad sector reports its own offset.
        #expect(throws: ByteSourceError.unreadable(offset: 21 * 512 + 7, code: EIO)) {
            _ = try read(source, 21 * 512 + 7, 10)
        }
        // Good ranges between bad sectors still read.
        #expect(try read(source, 22 * 512, 78 * 512) == expected(22 * 512, 78 * 512))
        #expect(try read(source, 101 * 512 + 3, 1000) == expected(101 * 512 + 3, 1000))
    }

    @Test func openingAMissingPathFails() {
        #expect(throws: ByteSourceError.openFailed(path: "/nonexistent/hexer", code: ENOENT)) {
            try DiskByteSource(path: "/nonexistent/hexer")
        }
    }
}
