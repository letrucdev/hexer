import Foundation

/// HxD's Tools menu on files: split, concatenate and securely wipe.
public enum FileTools {
    public enum ToolError: Error, Equatable, LocalizedError {
        case cannotOpen(path: String, code: Int32)
        case ioFailed(path: String, code: Int32)
        case invalidPartSize

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let path, let code): "Cannot open “\(path)”: \(String(cString: strerror(code)))."
            case .ioFailed(let path, let code): "Reading or writing “\(path)” failed: \(String(cString: strerror(code)))."
            case .invalidPartSize: "The part size must be at least one byte."
            }
        }
    }

    /// The part sizes offered by HxD's Split dialog.
    public static let splitPresets: [(name: String, size: UInt64)] = [
        ("5¼″ floppy (1,200 KiB)", 1200 << 10),
        ("3½″ floppy (1,440 KiB)", 1440 << 10),
        ("Zip 100 (100 MiB)", 100 << 20),
        ("Zip 200 (200 MiB)", 200 << 20),
        ("CD-ROM (650 MiB)", 650 << 20),
        ("CD-ROM (700 MiB)", 700 << 20),
    ]

    /// `base.001`, `base.002`, … (at least three digits, more when there are over 999 parts).
    public static func partURLs(base: URL, count: Int) -> [URL] {
        let digits = max(3, String(count).count)
        return (1...max(count, 1)).prefix(count).map { i in
            let n = String(i)
            return base.appendingPathExtension(String(repeating: "0", count: digits - n.count) + n)
        }
    }

    public static func partCount(length: UInt64, partSize: UInt64) -> Int {
        guard partSize > 0 else { return 0 }
        return Int((length + partSize - 1) / partSize)
    }

    /// Splits `source` into parts of `partSize` bytes written to `parts` (one URL per part,
    /// see `partURLs`). Removes what it wrote when cancelled or failing.
    public static func split(_ source: URL, partSize: UInt64, to parts: [URL],
                             isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws {
        guard partSize > 0 else { throw ToolError.invalidPartSize }
        let input = try openFile(source, flags: O_RDONLY)
        defer { close(input) }
        let length = try fileLength(input, source)
        precondition(parts.count == partCount(length: length, partSize: partSize), "one URL per part")
        var written: [URL] = []
        do {
            for (i, url) in parts.enumerated() {
                let output = try openFile(url, flags: O_WRONLY | O_CREAT | O_TRUNC)
                written.append(url)
                defer { close(output) }
                let start = UInt64(i) * partSize
                try copy(from: input, source, range: start..<min(start + partSize, length), to: output, url, at: 0,
                         isCancelled: isCancelled) { done in progress(Double(start + done) / Double(max(length, 1))) }
            }
        } catch {
            written.forEach { unlink($0.path) }
            throw error
        }
        progress(1)
    }

    /// Writes `sources` one after another into `destination` (HxD's Concatenate).
    public static func concatenate(_ sources: [URL], to destination: URL,
                                   isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws {
        let output = try openFile(destination, flags: O_WRONLY | O_CREAT | O_TRUNC)
        defer { close(output) }
        do {
            var lengths: [UInt64] = []
            for url in sources {
                let fd = try openFile(url, flags: O_RDONLY)
                defer { close(fd) }
                lengths.append(try fileLength(fd, url))
            }
            let total = Double(max(lengths.reduce(0, +), 1))
            var offset: UInt64 = 0
            for (url, length) in zip(sources, lengths) {
                let input = try openFile(url, flags: O_RDONLY)
                defer { close(input) }
                let base = offset
                try copy(from: input, url, range: 0..<length, to: output, destination, at: offset,
                         isCancelled: isCancelled) { done in progress(Double(base + done) / total) }
                offset += length
            }
        } catch {
            unlink(destination.path)
            throw error
        }
        progress(1)
    }

    /// Overwrites `range` of an open file pass after pass, flushing each pass to the storage
    /// device (F_FULLFSYNC) before the next one starts.
    public static func overwrite(fd: Int32, path: String, range: Range<UInt64>, passes: [Generator],
                                 isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws {
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        let total = Double(range.upperBound - range.lowerBound) * Double(passes.count)
        var done = 0.0
        for generator in passes {
            var offset = range.lowerBound
            while offset < range.upperBound {
                if isCancelled() { throw CancellationError() }
                let n = Int(min(UInt64(chunk), range.upperBound - offset))
                let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<n])
                generator.fill(slice, streamOffset: offset - range.lowerBound)
                try writeAll(fd, slice.baseAddress!, n, at: offset, path: path)
                offset += UInt64(n)
                done += Double(n)
                if total > 0 { progress(done / total) }
            }
            _ = fcntl(fd, F_FULLFSYNC)
        }
    }

    /// Overwrites the whole file with `passes`, then renames it to a random name and deletes
    /// it (HxD's Shredder). On SSDs and APFS, copies of the data may survive elsewhere.
    public static func wipe(_ url: URL, passes: [Generator],
                            isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws {
        let fd = try openFile(url, flags: O_WRONLY)
        do {
            let length = try fileLength(fd, url)
            try overwrite(fd: fd, path: url.path, range: 0..<length, passes: passes, isCancelled: isCancelled, progress: progress)
            _ = ftruncate(fd, 0)
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        } catch {
            close(fd)
            throw error
        }
        // A random name hides the original one in the directory listing before deletion.
        let scrambled = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let target = rename(url.path, scrambled.path) == 0 ? scrambled : url
        guard unlink(target.path) == 0 else { throw ToolError.ioFailed(path: url.path, code: errno) }
    }

    // MARK: I/O helpers

    private static func openFile(_ url: URL, flags: Int32) throws -> Int32 {
        let fd = open(url.path, flags | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ToolError.cannotOpen(path: url.path, code: errno) }
        return fd
    }

    private static func fileLength(_ fd: Int32, _ url: URL) throws -> UInt64 {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ToolError.ioFailed(path: url.path, code: errno) }
        return UInt64(max(st.st_size, 0))
    }

    private static func writeAll(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int, at offset: UInt64, path: String) throws {
        var written = 0
        while written < count {
            let n = pwrite(fd, base + written, count - written, off_t(offset) + off_t(written))
            if n < 0 {
                if errno == EINTR { continue }
                throw ToolError.ioFailed(path: path, code: errno)
            }
            written += n
        }
    }

    private static func copy(from input: Int32, _ inputURL: URL, range: Range<UInt64>, to output: Int32, _ outputURL: URL,
                             at outputOffset: UInt64, isCancelled: () -> Bool, progress: (UInt64) -> Void) throws {
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var offset = range.lowerBound
        while offset < range.upperBound {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(UInt64(chunk), range.upperBound - offset))
            let n = pread(input, buffer.baseAddress!, want, off_t(offset))
            if n < 0 {
                if errno == EINTR { continue }
                throw ToolError.ioFailed(path: inputURL.path, code: errno)
            }
            if n == 0 { break }
            try writeAll(output, buffer.baseAddress!, n, at: outputOffset + (offset - range.lowerBound), path: outputURL.path)
            offset += UInt64(n)
            progress(offset - range.lowerBound)
        }
    }
}
