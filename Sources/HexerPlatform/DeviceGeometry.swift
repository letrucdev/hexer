import CHexerSys
import Foundation

/// Size and sector layout of an open descriptor: a disk device, or a regular file (such as a disk
/// image) treated as a disk with a chosen sector size.
public struct DeviceGeometry: Sendable, Equatable {
    /// Logical sector size: on a device every read and write must be a multiple of it, at an
    /// offset that is a multiple of it.
    public var sectorSize: Int
    /// Physical sector size (at least `sectorSize`); writes of whole physical sectors are fastest.
    public var physicalSectorSize: Int
    public var length: UInt64
    /// A character or block device rather than a regular file.
    public var isDevice: Bool

    public init(sectorSize: Int, physicalSectorSize: Int, length: UInt64, isDevice: Bool) {
        self.sectorSize = sectorSize
        self.physicalSectorSize = physicalSectorSize
        self.length = length
        self.isDevice = isDevice
    }

    /// Queries `fd`: the DKIOC ioctls for devices, `fstat` for regular files, which are given
    /// `fileSectorSize`. Throws `DiskIOError.queryFailed` when neither applies.
    public static func of(descriptor fd: Int32, fileSectorSize: Int = 512) throws -> DeviceGeometry {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw DiskIOError.queryFailed(code: errno) }
        let type = st.st_mode & S_IFMT
        if type == S_IFCHR || type == S_IFBLK {
            var size: UInt32 = 0
            var count: UInt64 = 0
            guard hexer_block_size(fd, &size) == 0, size > 0 else { throw DiskIOError.queryFailed(code: errno) }
            guard hexer_block_count(fd, &count) == 0 else { throw DiskIOError.queryFailed(code: errno) }
            var physical: UInt32 = 0
            if hexer_physical_block_size(fd, &physical) != 0 || physical < size { physical = size }
            return DeviceGeometry(sectorSize: Int(size), physicalSectorSize: Int(physical),
                                  length: count * UInt64(size), isDevice: true)
        }
        guard type == S_IFREG else { throw DiskIOError.queryFailed(code: ENODEV) }
        guard fileSectorSize > 0 else { throw DiskIOError.invalidSectorSize(fileSectorSize) }
        return DeviceGeometry(sectorSize: fileSectorSize, physicalSectorSize: fileSectorSize,
                              length: UInt64(max(st.st_size, 0)), isDevice: false)
    }
}

/// Failures of the sector-level writers (`DiskWriter`, `DiskCloner`).
public enum DiskIOError: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    /// Reading the destination (for read-modify-write) or source at `offset` failed with `code` (errno).
    case readFailed(offset: UInt64, code: Int32)
    case writeFailed(offset: UInt64, code: Int32)
    /// The data needs `required` bytes but the destination holds only `available`.
    case tooLarge(required: UInt64, available: UInt64)
    case invalidSectorSize(Int)
    case cannotCreate(path: String, code: Int32)
    /// The descriptor is neither a disk device nor a regular file, or a disk ioctl failed.
    case queryFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "The operation was cancelled."
        case .readFailed(let offset, let code): "Reading at offset \(hexOffset(offset)) failed: \(errorString(code))."
        case .writeFailed(let offset, let code): "Writing at offset \(hexOffset(offset)) failed: \(errorString(code))."
        case .tooLarge(let required, let available):
            "The data (\(required) bytes) does not fit on the destination (\(available) bytes)."
        case .invalidSectorSize(let size): "\(size) is not a valid sector size."
        case .cannotCreate(let path, let code): "Could not create \(path): \(errorString(code))."
        case .queryFailed(let code): "Could not determine the size of the disk: \(errorString(code))."
        }
    }
}

func errorString(_ code: Int32) -> String { String(cString: strerror(code)) }

func hexOffset(_ offset: UInt64) -> String { "0x" + String(offset, radix: 16, uppercase: true) }

/// Thin `pread`/`pwrite` loops that retry on EINTR.
enum PosixIO {
    /// Reads until `count` bytes arrived or end of file. On failure returns the bytes read so far
    /// and the errno value; `error` is 0 on success.
    static func read(_ fd: Int32, _ dest: UnsafeMutableRawPointer, count: Int, at offset: UInt64) -> (count: Int, error: Int32) {
        var total = 0
        while total < count {
            let n = pread(fd, dest + total, count - total, off_t(offset) + off_t(total))
            if n < 0 {
                if errno == EINTR { continue }
                return (total, errno)
            }
            if n == 0 { break }
            total += n
        }
        return (total, 0)
    }

    /// Writes all `count` bytes; returns 0 or the errno value.
    static func write(_ fd: Int32, _ src: UnsafeRawPointer, count: Int, at offset: UInt64) -> Int32 {
        var total = 0
        while total < count {
            let n = pwrite(fd, src + total, count - total, off_t(offset) + off_t(total))
            if n < 0 {
                if errno == EINTR { continue }
                return errno
            }
            if n == 0 { return EIO }
            total += n
        }
        return 0
    }

    /// Flushes written data to stable storage; failures are ignored (some media cannot flush).
    static func synchronize(_ fd: Int32, isDevice: Bool) {
        if isDevice {
            _ = hexer_synchronize(fd)
        } else if fcntl(fd, F_FULLFSYNC) != 0 {
            fsync(fd)
        }
    }

    /// A page-aligned scratch buffer, as raw devices like their DMA buffers.
    static func allocate(_ count: Int) -> UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer.allocate(byteCount: max(count, 1), alignment: Int(getpagesize()))
    }
}

extension UInt64 {
    func roundedDown(to unit: Int) -> UInt64 { self / UInt64(unit) * UInt64(unit) }
    func roundedUp(to unit: Int) -> UInt64 { (self + UInt64(unit) - 1) / UInt64(unit) * UInt64(unit) }
}
