import Foundation
import HexerCore
import Testing
@testable import HexerPlatform

@Suite struct DiskClonerTests {
    @Test func copiesByteIdentically() throws {
        let content = randomBytes(3 * (1 << 20) + 777, seed: 21)
        let src = try Scratch.file(content)
        let dst = Scratch.url("clone.img")
        defer { [src, dst].forEach { try? FileManager.default.removeItem(at: $0) } }
        let progress = Collector<Double>()
        let report = try DiskCloner.copy(from: try DiskByteSource(path: src.path), to: dst, chunkSize: 1 << 20,
                                         progress: { progress.append($0) })
        #expect(report == DiskCloner.Report(bytesCopied: UInt64(content.count), unreadableRanges: []))
        #expect(try [UInt8](Data(contentsOf: dst)) == content)
        #expect(progress.all.count == 4)
        #expect(progress.all.last == 1)
    }

    @Test func unreadableSectorsBecomeZerosAndAreReported() throws {
        let content = randomBytes(200 * 512, seed: 22)
        let src = try Scratch.file(content)
        let dst = Scratch.url("clone.img")
        defer { [src, dst].forEach { try? FileManager.default.removeItem(at: $0) } }
        let source = try DiskByteSource(descriptor: open(src.path, O_RDONLY), path: src.path, sectorSize: 512,
                                        faultySectors: [20, 21, 100, 199])
        let report = try DiskCloner.copy(from: source, to: dst, chunkSize: 16 * 512)
        #expect(report.bytesCopied == UInt64(content.count))
        let bad: [Range<UInt64>] = [10240..<11264, 51200..<51712, 101_888..<102_400]  // sectors 20–21, 100, 199
        #expect(report.unreadableRanges == bad)
        var expected = content
        for r in report.unreadableRanges {
            expected.replaceSubrange(Int(r.lowerBound)..<Int(r.upperBound), with: repeatElement(0, count: r.count))
        }
        #expect(try [UInt8](Data(contentsOf: dst)) == expected)
    }

    @Test func cancellationRemovesThePartialImage() throws {
        let src = try Scratch.file(randomBytes(4096, seed: 2))
        let dst = Scratch.url("clone.img")
        defer { [src, dst].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(throws: DiskIOError.cancelled) {
            try DiskCloner.copy(from: try FileByteSource(url: src), to: dst, isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: dst.path))
    }

    @Test func copiesIntoAnOpenFileDescriptor() throws {
        let content = randomBytes(5000, seed: 4)
        let dst = try Scratch.file([UInt8](repeating: 0xFF, count: 8192))
        defer { try? FileManager.default.removeItem(at: dst) }
        let fd = open(dst.path, O_RDWR)
        defer { close(fd) }
        try DiskCloner.copy(from: MemoryByteSource(content), to: fd)
        // A regular file is written as is: no padding of the last partial sector.
        let written = try [UInt8](Data(contentsOf: dst))
        #expect(Array(written[0..<5000]) == content)
        #expect(written[5000...].allSatisfy { $0 == 0xFF })
    }
}
