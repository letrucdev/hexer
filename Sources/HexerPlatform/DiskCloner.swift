import Foundation
import HexerCore

/// Tools ▸ Clone Disk / Restore Image: copies a whole source (a disk, an image file) to a device or
/// file in large sector-aligned chunks. Unreadable sectors are written as zeros and reported
/// instead of aborting the copy.
public enum DiskCloner {
    public static let defaultChunkSize = 8 << 20

    public struct Report: Sendable, Equatable {
        public var bytesCopied: UInt64
        /// Source byte ranges that could not be read (adjacent sectors merged); zeros were written.
        public var unreadableRanges: [Range<UInt64>]

        public init(bytesCopied: UInt64, unreadableRanges: [Range<UInt64>]) {
            self.bytesCopied = bytesCopied
            self.unreadableRanges = unreadableRanges
        }
    }

    /// Copies all of `source` to the start of `fd`, a device or regular file opened for writing.
    ///
    /// - Parameter sectorSize: The retry unit for read errors; defaults to the source's sector size
    ///   (`DiskByteSource`) or 512. Writes to a device also respect its own sector size, and a
    ///   final partial sector is merged with the device's existing bytes.
    /// - Throws: `DiskIOError` for write failures, a destination that is too small, or cancellation.
    @discardableResult
    public static func copy(from source: any ByteSource, to fd: Int32, sectorSize: Int? = nil,
                            chunkSize: Int = defaultChunkSize, isCancelled: () -> Bool = { false },
                            progress: (Double) -> Void = { _ in }) throws -> Report {
        let geometry = try DeviceGeometry.of(descriptor: fd)
        let readUnit = sectorSize ?? (source as? DiskByteSource)?.sectorSize ?? 512
        guard readUnit > 0 else { throw DiskIOError.invalidSectorSize(readUnit) }
        let unit = geometry.isDevice ? max(readUnit, geometry.sectorSize) : readUnit
        let chunk = max(unit, chunkSize / unit * unit)
        let length = source.length
        if geometry.isDevice && length > geometry.length {
            throw DiskIOError.tooLarge(required: length, available: geometry.length)
        }

        let buffer = PosixIO.allocate(chunk + geometry.sectorSize)
        defer { buffer.deallocate() }
        var report = Report(bytesCopied: 0, unreadableRanges: [])
        var offset: UInt64 = 0
        while offset < length {
            guard !isCancelled() else { throw DiskIOError.cancelled }
            let count = Int(min(UInt64(chunk), length - offset))
            let dest = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count])
            if (try? readFully(source, into: dest, at: offset)) != true {
                for bad in readSectorwise(source, into: dest, at: offset, unit: readUnit) {
                    if let last = report.unreadableRanges.last, last.upperBound == bad.lowerBound {
                        report.unreadableRanges[report.unreadableRanges.count - 1] = last.lowerBound..<bad.upperBound
                    } else {
                        report.unreadableRanges.append(bad)
                    }
                }
            }
            var writeCount = count
            if geometry.isDevice && count % geometry.sectorSize != 0 {
                writeCount = try padTail(fd, buffer: buffer, count: count, at: offset, sectorSize: geometry.sectorSize)
            }
            let code = PosixIO.write(fd, buffer.baseAddress!, count: writeCount, at: offset)
            guard code == 0 else { throw DiskIOError.writeFailed(offset: offset, code: code) }
            offset += UInt64(count)
            report.bytesCopied = offset
            progress(Double(offset) / Double(length))
        }
        PosixIO.synchronize(fd, isDevice: geometry.isDevice)
        return report
    }

    /// Copies `source` into a new file at `url` (replacing any file there). The partial file is
    /// removed if the copy fails or is cancelled.
    @discardableResult
    public static func copy(from source: any ByteSource, to url: URL, sectorSize: Int? = nil,
                            chunkSize: Int = defaultChunkSize, isCancelled: () -> Bool = { false },
                            progress: (Double) -> Void = { _ in }) throws -> Report {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw DiskIOError.cannotCreate(path: url.path, code: errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)  // a multi-gigabyte image should not flush the file cache
        do {
            return try copy(from: source, to: fd, sectorSize: sectorSize, chunkSize: chunkSize,
                            isCancelled: isCancelled, progress: progress)
        } catch {
            unlink(url.path)
            throw error
        }
    }

    /// Reads exactly `dest.count` bytes; `false` when the source ends early.
    private static func readFully(_ source: any ByteSource, into dest: UnsafeMutableRawBufferPointer,
                                  at offset: UInt64) throws -> Bool {
        var done = 0
        while done < dest.count {
            let n = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: dest[done...]), at: offset + UInt64(done))
            if n == 0 { return false }
            done += n
        }
        return true
    }

    /// Re-reads a failed chunk one sector at a time, zero-filling and returning the bad sectors.
    private static func readSectorwise(_ source: any ByteSource, into dest: UnsafeMutableRawBufferPointer,
                                       at offset: UInt64, unit: Int) -> [Range<UInt64>] {
        var bad: [Range<UInt64>] = []
        var at = 0
        while at < dest.count {
            let n = min(unit, dest.count - at)
            let slot = UnsafeMutableRawBufferPointer(rebasing: dest[at..<at + n])
            if (try? readFully(source, into: slot, at: offset + UInt64(at))) != true {
                slot.initializeMemory(as: UInt8.self, repeating: 0)
                let r = offset + UInt64(at)..<offset + UInt64(at + n)
                if let last = bad.last, last.upperBound == r.lowerBound {
                    bad[bad.count - 1] = last.lowerBound..<r.upperBound
                } else {
                    bad.append(r)
                }
            }
            at += n
        }
        return bad
    }

    /// Completes the last partial sector with the destination's current bytes; returns the
    /// sector-aligned length to write.
    private static func padTail(_ fd: Int32, buffer: UnsafeMutableRawBufferPointer, count: Int, at offset: UInt64,
                                sectorSize: Int) throws -> Int {
        let tailStart = count / sectorSize * sectorSize
        let sector = PosixIO.allocate(sectorSize)
        defer { sector.deallocate() }
        let position = offset + UInt64(tailStart)
        let r = PosixIO.read(fd, sector.baseAddress!, count: sectorSize, at: position)
        guard r.error == 0, r.count == sectorSize else {
            throw DiskIOError.readFailed(offset: position, code: r.error == 0 ? EIO : r.error)
        }
        let keep = count - tailStart
        (buffer.baseAddress! + count).copyMemory(from: sector.baseAddress! + keep, byteCount: sectorSize - keep)
        return tailStart + sectorSize
    }
}
