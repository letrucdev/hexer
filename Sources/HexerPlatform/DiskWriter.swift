import Foundation
import HexerCore

/// Saves a disk document in place: writes the changed ranges of a snapshot back to the disk in
/// whole sectors, reading the untouched bytes of partially changed sectors first
/// (read-modify-write).
public enum DiskWriter {
    /// Bytes written per `pwrite`; a multiple of every sector size.
    public static let chunkSize = 8 << 20

    /// Writes `changedRanges` of `snapshot` (from `FileWriter.changedRanges(in:base:)`) to `fd`,
    /// a device or regular file opened read-write that currently holds the document's original
    /// bytes.
    ///
    /// - Parameters:
    ///   - sectorSize: The write unit; raised to the device's logical sector size when larger.
    ///   - baseSourceID: The registry ID of the source that reads this same disk. Changed bytes
    ///     that were copied from elsewhere on the disk (pieces of that source at another offset)
    ///     could be overwritten before they are read; when any of them overlaps a changed range,
    ///     all changed bytes are first staged in an unlinked temporary file. Pass `nil` only when
    ///     the snapshot cannot refer to the destination.
    /// - Throws: `DiskIOError`. A failure or cancellation part way leaves earlier ranges written.
    public static func write(_ snapshot: ByteSnapshot, changedRanges: [Range<UInt64>], to fd: Int32,
                             sectorSize: Int, baseSourceID: UInt32?,
                             isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws {
        guard sectorSize > 0 else { throw DiskIOError.invalidSectorSize(sectorSize) }
        let geometry = try DeviceGeometry.of(descriptor: fd, fileSectorSize: sectorSize)
        let unit = max(sectorSize, geometry.sectorSize)
        guard chunkSize % unit == 0 else { throw DiskIOError.invalidSectorSize(unit) }

        let ranges = normalized(changedRanges, length: snapshot.length)
        guard let last = ranges.last else { return }
        guard last.upperBound <= geometry.length else {
            throw DiskIOError.tooLarge(required: snapshot.length, available: geometry.length)
        }
        let total = ranges.reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound) }

        var stage: Staging?
        defer { stage?.close() }
        var phase = (start: 0.0, scale: 1.0)
        if let baseSourceID, readsOwnChanges(snapshot, ranges: ranges, base: baseSourceID) {
            stage = try Staging(snapshot, ranges: ranges, total: total, isCancelled: isCancelled) { progress($0 / 2) }
            phase = (0.5, 0.5)
        }

        let buffer = PosixIO.allocate(chunkSize)
        defer { buffer.deallocate() }
        var done: UInt64 = 0
        for group in groups(ranges, unit: unit, length: geometry.length) {
            var chunkStart = group.extent.lowerBound
            while chunkStart < group.extent.upperBound {
                guard !isCancelled() else { throw DiskIOError.cancelled }
                let chunk = chunkStart..<min(chunkStart + UInt64(chunkSize), group.extent.upperBound)
                let count = Int(chunk.upperBound - chunk.lowerBound)
                let parts = group.ranges.compactMap { r -> Range<UInt64>? in
                    let part = max(r.lowerBound, chunk.lowerBound)..<min(r.upperBound, chunk.upperBound)
                    return part.isEmpty ? nil : part
                }
                let covered = parts.reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
                if covered < UInt64(count) {
                    try readUnchanged(fd, into: buffer.baseAddress!, chunk: chunk, parts: parts, unit: unit)
                }
                for part in parts {
                    let slot = UnsafeMutableRawBufferPointer(
                        rebasing: buffer[Int(part.lowerBound - chunk.lowerBound)..<Int(part.upperBound - chunk.lowerBound)])
                    if let stage {
                        try stage.copy(part, into: slot)
                    } else {
                        snapshot.copyBytes(part, into: slot)
                    }
                }
                let code = PosixIO.write(fd, buffer.baseAddress!, count: count, at: chunk.lowerBound)
                guard code == 0 else { throw DiskIOError.writeFailed(offset: chunk.lowerBound, code: code) }
                done += covered
                progress(phase.start + phase.scale * Double(done) / Double(max(total, 1)))
                chunkStart = chunk.upperBound
            }
        }
        PosixIO.synchronize(fd, isDevice: geometry.isDevice)
    }

    /// Sorted, clamped, non-empty, merged ranges.
    static func normalized(_ ranges: [Range<UInt64>], length: UInt64) -> [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let r = min(r.lowerBound, length)..<min(r.upperBound, length)
            guard !r.isEmpty else { continue }
            if let prev = out.last, r.lowerBound <= prev.upperBound {
                out[out.count - 1] = prev.lowerBound..<max(prev.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Changed ranges whose sector-aligned extents touch, so each sector is written once.
    static func groups(_ ranges: [Range<UInt64>], unit: Int,
                       length: UInt64) -> [(extent: Range<UInt64>, ranges: [Range<UInt64>])] {
        var out: [(extent: Range<UInt64>, ranges: [Range<UInt64>])] = []
        for r in ranges {
            let extent = r.lowerBound.roundedDown(to: unit)..<min(r.upperBound.roundedUp(to: unit), length)
            if let prev = out.last, extent.lowerBound <= prev.extent.upperBound {
                out[out.count - 1].extent = prev.extent.lowerBound..<max(prev.extent.upperBound, extent.upperBound)
                out[out.count - 1].ranges.append(r)
            } else {
                out.append((extent, [r]))
            }
        }
        return out
    }

    /// Whether some changed byte is a copy of disk bytes that a changed range overwrites.
    static func readsOwnChanges(_ snapshot: ByteSnapshot, ranges: [Range<UInt64>], base: UInt32) -> Bool {
        var sources: [Range<UInt64>] = []
        for r in ranges {
            snapshot.tree.forEachPiece(in: r) { piece, offset in
                if piece.ref == .source(base) && piece.start != offset {
                    sources.append(piece.start..<piece.start + piece.length)
                }
                return true
            }
        }
        return sources.contains { s in ranges.contains { $0.overlaps(s) } }
    }

    /// Fills the bytes of `chunk` outside `parts` from the disk: in one read, or sector by
    /// sector (skipping fully changed sectors) when that fails.
    private static func readUnchanged(_ fd: Int32, into dest: UnsafeMutableRawPointer, chunk: Range<UInt64>,
                                      parts: [Range<UInt64>], unit: Int) throws {
        let count = Int(chunk.upperBound - chunk.lowerBound)
        if PosixIO.read(fd, dest, count: count, at: chunk.lowerBound).error == 0 { return }
        var sector = chunk.lowerBound
        while sector < chunk.upperBound {
            let s = sector..<min(sector + UInt64(unit), chunk.upperBound)
            if !parts.contains(where: { $0.lowerBound <= s.lowerBound && $0.upperBound >= s.upperBound }) {
                let r = PosixIO.read(fd, dest + Int(s.lowerBound - chunk.lowerBound), count: s.count, at: s.lowerBound)
                guard r.error == 0 else { throw DiskIOError.readFailed(offset: s.lowerBound, code: r.error) }
            }
            sector = s.upperBound
        }
    }

    /// Changed bytes copied into an unlinked temporary file before the disk is touched.
    private final class Staging {
        private let fd: Int32
        /// Offset of each changed range in the file, keyed by the range's start.
        private var offsets: [UInt64: (range: Range<UInt64>, at: UInt64)] = [:]
        private let starts: [UInt64]

        init(_ snapshot: ByteSnapshot, ranges: [Range<UInt64>], total: UInt64,
             isCancelled: () -> Bool, progress: (Double) -> Void) throws {
            let template = FileManager.default.temporaryDirectory.appendingPathComponent("hexer-disk-XXXXXX").path
            var path = Array(template.utf8CString)
            fd = mkstemp(&path)
            guard fd >= 0 else { throw DiskIOError.cannotCreate(path: template, code: errno) }
            unlink(path)
            starts = ranges.map(\.lowerBound)
            var at: UInt64 = 0
            do {
                for r in ranges {
                    offsets[r.lowerBound] = (r, at)
                    try snapshot.forEachChunk(in: r, chunkSize: DiskWriter.chunkSize) { offset, chunk in
                        guard !isCancelled() else { throw DiskIOError.cancelled }
                        let position = at + (offset - r.lowerBound)
                        let code = PosixIO.write(fd, chunk.baseAddress!, count: chunk.count, at: position)
                        guard code == 0 else { throw DiskIOError.writeFailed(offset: position, code: code) }
                        progress(Double(position + UInt64(chunk.count)) / Double(max(total, 1)))
                        return true
                    }
                    at += r.upperBound - r.lowerBound
                }
            } catch {
                Darwin.close(fd)
                throw error
            }
        }

        /// Copies `part`, which lies inside one changed range, from the staged bytes.
        func copy(_ part: Range<UInt64>, into dest: UnsafeMutableRawBufferPointer) throws {
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= part.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            let entry = offsets[starts[lo - 1]]!
            let position = entry.at + (part.lowerBound - entry.range.lowerBound)
            let r = PosixIO.read(fd, dest.baseAddress!, count: dest.count, at: position)
            guard r.error == 0, r.count == dest.count else {
                throw DiskIOError.readFailed(offset: part.lowerBound, code: r.error == 0 ? EIO : r.error)
            }
        }

        func close() { Darwin.close(fd) }
    }
}
