import Foundation
import HexerCore

/// Reads a raw disk device (`/dev/rdiskN`) — or a regular file such as a disk image opened
/// "as a disk" — in whole sectors.
///
/// Raw devices reject reads that are not sector-aligned, so unaligned requests read the covering
/// sectors into a scratch buffer and copy out the middle. When a read fails the range is retried
/// sector by sector and the first bad sector is reported as `ByteSourceError.unreadable`; the bytes
/// before it have already been stored in the caller's buffer. Concurrent reads are safe (`pread`).
public final class DiskByteSource: ByteSource, @unchecked Sendable {
    public let path: String
    public let length: UInt64
    public var isFixedSize: Bool { true }
    /// Logical sector size: from the device, or as given for regular files.
    public let sectorSize: Int
    public let physicalSectorSize: Int
    public let isDevice: Bool
    /// The descriptor reads go through; owned (and closed) by the source.
    public let descriptor: Int32
    /// Sector indexes that fail with EIO, to exercise the bad-sector paths in tests.
    let faultySectors: Set<UInt64>

    /// Wraps `descriptor`, taking ownership (it is closed on deinit, or right away if this throws).
    /// Devices report their own sector size; regular files use `sectorSize`.
    public convenience init(descriptor: Int32, path: String, sectorSize: Int = 512) throws {
        try self.init(descriptor: descriptor, path: path, sectorSize: sectorSize, faultySectors: [])
    }

    /// Opens `path` read-only: a device the user may already read (for example an attached disk
    /// image's `/dev/rdiskN`), or a regular file. Use `RawDeviceOpener` for devices that need
    /// administrator authorization.
    public convenience init(path: String, sectorSize: Int = 512) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ByteSourceError.openFailed(path: path, code: errno) }
        try self.init(descriptor: fd, path: path, sectorSize: sectorSize)
    }

    init(descriptor: Int32, path: String, sectorSize: Int, faultySectors: Set<UInt64>) throws {
        let geometry: DeviceGeometry
        do {
            geometry = try DeviceGeometry.of(descriptor: descriptor, fileSectorSize: sectorSize)
        } catch {
            close(descriptor)
            let code: Int32 = if case DiskIOError.queryFailed(let c) = error { c } else { EINVAL }
            throw ByteSourceError.openFailed(path: path, code: code)
        }
        self.descriptor = descriptor
        self.path = path
        self.length = geometry.length
        self.sectorSize = geometry.sectorSize
        self.physicalSectorSize = geometry.physicalSectorSize
        self.isDevice = geometry.isDevice
        self.faultySectors = faultySectors
    }

    deinit { close(descriptor) }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard let base = buffer.baseAddress, !buffer.isEmpty, offset < length else { return 0 }
        let wanted = Int(min(UInt64(buffer.count), length - offset))
        let end = offset + UInt64(wanted)
        let start = offset.roundedDown(to: sectorSize)
        let alignedEnd = end.roundedUp(to: sectorSize)

        if start == offset, alignedEnd == end || end == length, Int(bitPattern: base) & 15 == 0 {
            return try readSectors(into: base, count: wanted, at: offset, requested: offset)
        }
        let span = Int(alignedEnd - start)
        let scratch = PosixIO.allocate(span)
        defer { scratch.deallocate() }
        let skip = Int(offset - start)
        do {
            let n = try readSectors(into: scratch.baseAddress!, count: span, at: start, requested: offset)
            let copied = max(0, min(wanted, n - skip))
            base.copyMemory(from: scratch.baseAddress! + skip, byteCount: copied)
            return copied
        } catch let ReadFailure.badSector(at, code, good) {
            // Hand over the readable prefix before reporting the bad sector.
            let copied = max(0, min(wanted, good - skip))
            base.copyMemory(from: scratch.baseAddress! + skip, byteCount: copied)
            throw ByteSourceError.unreadable(offset: max(at, offset), code: code)
        }
    }

    private enum ReadFailure: Error {
        /// The sector at `at` failed with `code`; the `good` bytes before it were read.
        case badSector(at: UInt64, code: Int32, good: Int)
    }

    /// Reads `count` bytes of whole sectors at the aligned `offset`, retrying sector by sector
    /// after a failure. Throws `ByteSourceError.unreadable` directly when the caller's buffer is
    /// the destination (`requested == offset`), `ReadFailure` otherwise.
    private func readSectors(into dest: UnsafeMutableRawPointer, count: Int, at offset: UInt64,
                             requested: UInt64) throws -> Int {
        let bulk = rawRead(dest, count: count, at: offset)
        if bulk.error == 0 { return bulk.count }
        var done = bulk.count / sectorSize * sectorSize
        while done < count {
            let n = min(sectorSize, count - done)
            let r = rawRead(dest + done, count: n, at: offset + UInt64(done))
            if r.error != 0 {
                let at = offset + UInt64(done)
                if requested == offset { throw ByteSourceError.unreadable(offset: at, code: r.error) }
                throw ReadFailure.badSector(at: at, code: r.error, good: done)
            }
            done += r.count
            if r.count < n { break }
        }
        return done
    }

    private func rawRead(_ dest: UnsafeMutableRawPointer, count: Int, at offset: UInt64) -> (count: Int, error: Int32) {
        if !faultySectors.isEmpty {
            let first = offset / UInt64(sectorSize)
            let last = (offset + UInt64(count) - 1) / UInt64(sectorSize)
            // Behave like a device: a request touching a bad sector fails as a whole.
            if faultySectors.contains(where: { $0 >= first && $0 <= last }) { return (0, EIO) }
        }
        return PosixIO.read(descriptor, dest, count: count, at: offset)
    }
}
