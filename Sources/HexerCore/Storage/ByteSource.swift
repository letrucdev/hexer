import Foundation

/// A random-access, read-only provider of bytes: a file, a disk, or an in-memory buffer.
///
/// Sources are never written through this protocol; edits live in a `PieceTree` that refers to
/// ranges of its sources, and saving writes a new file (or patches the old one in place).
public protocol ByteSource: AnyObject, Sendable {
    var length: UInt64 { get }
    /// Disks and other fixed-size media reject edits that would change the length.
    var isFixedSize: Bool { get }
    /// Reads up to `buffer.count` bytes starting at `offset` and returns how many were read.
    /// A short count only happens at the end of the source; unreadable ranges throw.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int
}

public enum ByteSourceError: Error, Equatable {
    case unreadable(offset: UInt64, code: Int32)
    case openFailed(path: String, code: Int32)
}

/// Identifies one version of a file so external modifications can be detected.
public struct FileIdentity: Equatable, Sendable {
    public var device: Int32
    public var inode: UInt64
    public var size: Int64
    public var modificationSeconds: Int
    public var modificationNanoseconds: Int

    init(_ st: stat) {
        device = st.st_dev
        inode = st.st_ino
        size = st.st_size
        modificationSeconds = st.st_mtimespec.tv_sec
        modificationNanoseconds = st.st_mtimespec.tv_nsec
    }

    public static func of(path: String) -> FileIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileIdentity(st)
    }
}

/// Reads a regular file with `pread`, keeping only a read-only descriptor open.
///
/// `pread` is used instead of `mmap` because another process truncating a mapped file raises
/// SIGBUS, whereas `pread` simply returns fewer bytes.
public final class FileByteSource: ByteSource, @unchecked Sendable {
    public let url: URL
    public let length: UInt64
    public let isFixedSize: Bool
    public let identity: FileIdentity
    private let fd: Int32

    public init(url: URL, fixedSize: Bool = false) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ByteSourceError.openFailed(path: url.path, code: errno) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let code = errno
            close(fd)
            throw ByteSourceError.openFailed(path: url.path, code: code)
        }
        self.fd = fd
        self.url = url
        self.length = UInt64(max(st.st_size, 0))
        self.identity = FileIdentity(st)
        self.isFixedSize = fixedSize
    }

    deinit { close(fd) }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard let base = buffer.baseAddress, offset < length else { return 0 }
        let wanted = Int(min(UInt64(buffer.count), length - offset))
        var total = 0
        while total < wanted {
            let n = pread(fd, base + total, wanted - total, off_t(offset) + off_t(total))
            if n < 0 {
                if errno == EINTR { continue }
                throw ByteSourceError.unreadable(offset: offset + UInt64(total), code: errno)
            }
            if n == 0 { break }
            total += n
        }
        return total
    }
}

/// An immutable in-memory source, used for new documents, imports and tests.
public final class MemoryByteSource: ByteSource {
    public let bytes: [UInt8]
    public let isFixedSize: Bool
    public var length: UInt64 { UInt64(bytes.count) }

    public init(_ bytes: [UInt8], fixedSize: Bool = false) {
        self.bytes = bytes
        self.isFixedSize = fixedSize
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length else { return 0 }
        let start = Int(offset)
        let count = min(buffer.count, bytes.count - start)
        bytes.withUnsafeBytes { src in
            buffer.baseAddress!.copyMemory(from: src.baseAddress! + start, byteCount: count)
        }
        return count
    }
}
