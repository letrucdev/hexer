import Foundation
import HexerCore
import Testing
@testable import HexerPlatform

/// End-to-end tests on real `/dev/rdiskN` devices backed by 8 MiB disk images attached (without
/// mounting) in the scratch directory. Writes happen only after `isOurWritableImage()` confirmed
/// that the device is the image just attached and that the user owns it.
@Suite(.serialized, .enabled(if: AttachedImage.isSupported, "hdiutil cannot attach images here"))
struct AttachedImageTests {
    private static let size = 8 << 20

    @Test func enumerationDescribesTheImage() throws {
        let image = try #require(AttachedImage.make())
        defer { image.detach() }
        let disk = try #require(DiskEnumerator.disk(bsdName: image.bsdName))
        #expect(disk.size == UInt64(Self.size))
        #expect(disk.blockSize == 512)
        #expect(disk.isWhole && disk.isWritable && disk.parentBSDName == nil)
        #expect(disk.isDiskImage)
        #expect(!disk.isInternal)
        #expect(!disk.isOnBootDisk && !disk.holdsBootVolume)
        #expect(disk.mountPoint == nil)
    }

    @Test func readWriteAndCloneOnARawDevice() async throws {
        let image = try #require(AttachedImage.make())
        defer { image.detach() }
        try #require(image.isOurWritableImage())

        // Fill the device with a known pattern through a writable descriptor (no authorization).
        let pattern = randomBytes(Self.size, seed: 31)
        let rw = try await RawDeviceOpener.open(bsdName: image.bsdName, writable: true, allowAuthorization: false)
        defer { close(rw) }
        #expect(pattern.withUnsafeBytes { PosixIO.write(rw, $0.baseAddress!, count: Self.size, at: 0) } == 0)
        #expect(try DeviceGeometry.of(descriptor: rw)
            == DeviceGeometry(sectorSize: 512, physicalSectorSize: 512, length: UInt64(Self.size), isDevice: true))

        // The raw device rejects unaligned I/O, which is why DiskByteSource reads whole sectors.
        var odd = [UInt8](repeating: 0, count: 10)
        #expect(pread(rw, &odd, 10, 3) == -1)

        let readFD = try await RawDeviceOpener.open(bsdName: image.bsdName, writable: false, allowAuthorization: false)
        let source = try DiskByteSource(descriptor: readFD, path: image.rawPath)
        #expect(source.isDevice && source.isFixedSize)
        #expect(source.length == UInt64(Self.size))
        #expect(source.sectorSize == 512)
        func read(_ offset: Int, _ count: Int) throws -> [UInt8] {
            var out = [UInt8](repeating: 0, count: count)
            let n = try out.withUnsafeMutableBytes { try source.read(into: $0, at: UInt64(offset)) }
            return Array(out.prefix(n))
        }
        for (offset, count) in [(0, 1), (3, 10), (511, 2), (512, 512), (1000, 100_000), (Self.size - 7, 100), (777, 65536)] {
            #expect(try read(offset, count) == Array(pattern[offset..<min(offset + count, Self.size)]), "\(offset)+\(count)")
        }
        // dd and an aligned pread of the same device agree.
        let dd = run("/bin/dd", ["if=\(image.rawPath)", "bs=512", "skip=3", "count=5"]).output
        #expect([UInt8](dd) == (try read(1536, 2560)))
        #expect(preadAll(image.rawPath, count: 4096, at: 8192) == (try read(8192, 4096)))

        // Save edits in place with read-modify-write of whole sectors.
        let expected = try editAndSave(source: source, original: pattern, writeDescriptor: rw)
        let onDisk = try #require(preadAll(image.rawPath, count: Self.size))
        #expect(onDisk == expected)
        let changed = zip(onDisk, pattern).filter { $0 != $1 }.count
        let intended = zip(expected, pattern).filter { $0 != $1 }.count
        #expect(changed == intended)

        // Clone the device into an image file.
        let clone = Scratch.url("clone.img")
        defer { try? FileManager.default.removeItem(at: clone) }
        let report = try DiskCloner.copy(from: source, to: clone)
        #expect(report == DiskCloner.Report(bytesCopied: UInt64(Self.size), unreadableRanges: []))
        #expect(try [UInt8](Data(contentsOf: clone)) == expected)

        // Restore a shorter image: the partial last sector keeps the device's bytes after it.
        let restored = randomBytes(Self.size - 4096 - 100, seed: 32)
        try DiskCloner.copy(from: MemoryByteSource(restored), to: rw)
        let after = try #require(preadAll(image.rawPath, count: Self.size))
        #expect(Array(after[0..<restored.count]) == restored)
        #expect(Array(after[restored.count...]) == Array(expected[restored.count...]))

        // An image larger than the device is refused before anything is written.
        #expect(throws: DiskIOError.tooLarge(required: UInt64(Self.size + 512), available: UInt64(Self.size))) {
            try DiskCloner.copy(from: MemoryByteSource([UInt8](repeating: 0, count: Self.size + 512)), to: rw)
        }
    }

    @Test(.timeLimit(.minutes(1))) func reportsAppearingAndDisappearingDisks() async throws {
        let events = DiskEnumerator.events()
        var iterator = events.makeAsyncIterator()
        // Existing disks are announced first; once those arrive, the watcher is live.
        let first = await iterator.next()
        #expect(first != nil)
        let image = try #require(AttachedImage.make())
        var detached = false
        defer { if !detached { image.detach() } }
        var sawAppear = false, sawDisappear = false
        while let event = await iterator.next() {
            if event == .appeared(bsdName: image.bsdName) && !sawAppear {
                sawAppear = true
                image.detach()
                detached = true
            }
            if event == .disappeared(bsdName: image.bsdName) {
                sawDisappear = true
                break
            }
        }
        #expect(sawAppear && sawDisappear)
    }

    @Test func unmountsAndMountsAVolume() async throws {
        let image = try #require(AttachedImage.make(fat: true))
        defer { image.detach() }
        try #require(image.isOurWritableImage())
        let partition = try #require(image.entities.first { $0 != image.bsdName })
        let session = DiskArbitrationSession.shared

        try await session.mount(bsdName: image.bsdName)
        let mounted = try #require(DiskEnumerator.disk(bsdName: partition))
        #expect(mounted.isMounted)
        #expect(mounted.volumeKind == "msdos")
        #expect(mounted.volumeName == "HEXERTEST")
        #expect(mounted.mountPoint?.hasPrefix("/Volumes/") == true)
        // The kernel refuses to write to a disk whose volumes are mounted.
        await #expect(throws: RawDeviceError.openFailed(path: image.rawPath, code: EBUSY)) {
            try await RawDeviceOpener.open(bsdName: image.bsdName, writable: true, allowAuthorization: false)
        }

        try await session.unmount(bsdName: image.bsdName)
        #expect(DiskEnumerator.disk(bsdName: partition)?.isMounted == false)
        // With nothing mounted the whole disk opens for writing.
        let fd = try await RawDeviceOpener.open(bsdName: image.bsdName, writable: true, allowAuthorization: false)
        close(fd)
        // Unmounting again is harmless.
        try await session.unmount(bsdName: partition)
        try await session.unmount(bsdName: image.bsdName)
    }
}
