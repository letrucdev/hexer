import Foundation
import Synchronization
@testable import HexerPlatform

/// Where tests put files and disk images: `$HEXER_TEST_SCRATCH`, else the temporary directory.
enum Scratch {
    static let directory: URL = {
        let base = ProcessInfo.processInfo.environment["HEXER_TEST_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("hexer-platform-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    static func file(_ bytes: [UInt8], name: String = "disk.bin") throws -> URL {
        let url = url(name)
        try Data(bytes).write(to: url)
        return url
    }
}

func randomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    return (0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return UInt8(truncatingIfNeeded: state)
    }
}

/// Runs a tool and returns its exit status and stdout (stderr is discarded).
@discardableResult
func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, Data()) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

func preadAll(_ path: String, count: Int, at offset: UInt64 = 0) -> [UInt8]? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 4096)
    defer { buffer.deallocate() }
    let r = PosixIO.read(fd, buffer.baseAddress!, count: count, at: offset)
    guard r.error == 0 else { return nil }
    return Array(buffer.prefix(r.count))
}

/// A disk image attached with `hdiutil attach -nomount`. Always call `detach()` (in a `defer`).
final class AttachedImage: Sendable {
    let imageURL: URL
    /// The whole disk, e.g. "disk5".
    let bsdName: String
    /// Every device node hdiutil reported for the image ("disk5", "disk5s1").
    let entities: [String]

    var rawPath: String { "/dev/r" + bsdName }

    private init(imageURL: URL, bsdName: String, entities: [String]) {
        self.imageURL = imageURL
        self.bsdName = bsdName
        self.entities = entities
    }

    /// Creates an 8 MiB image — raw (`-layout NONE`, no file system) or FAT-formatted with a
    /// partition map — and attaches it without mounting. `nil` if hdiutil refuses.
    static func make(fat: Bool = false) -> AttachedImage? {
        let url = Scratch.url(fat ? "fat.dmg" : "raw.dmg")
        let create = fat
            ? ["create", "-size", "8m", "-fs", "MS-DOS", "-volname", "HEXERTEST", "-ov", url.path]
            : ["create", "-size", "8m", "-layout", "NONE", "-ov", url.path]
        guard run("/usr/bin/hdiutil", create).status == 0 else { return nil }
        let attach = run("/usr/bin/hdiutil", ["attach", "-nomount", "-noverify", "-noautofsck", "-plist", url.path])
        guard let plist = try? PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let devices = entities.compactMap { ($0["dev-entry"] as? String)?.replacingOccurrences(of: "/dev/", with: "") }
        guard let whole = devices.min(by: { $0.count < $1.count }), attach.status == 0 else {
            devices.forEach { run("/usr/bin/hdiutil", ["detach", "/dev/" + $0, "-force"]) }
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return AttachedImage(imageURL: url, bsdName: whole, entities: devices)
    }

    /// Whether `hdiutil info` attributes this device to our image file, and the user may write it
    /// without privileges: the only condition under which tests write to a raw device.
    func isOurWritableImage() -> Bool {
        let info = run("/usr/bin/hdiutil", ["info", "-plist"])
        guard let plist = try? PropertyListSerialization.propertyList(from: info.output, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return false }
        let ours = imageURL.resolvingSymlinksInPath().path
        let match = images.contains { image in
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == ours,
                  let entities = image["system-entities"] as? [[String: Any]] else { return false }
            return entities.contains { $0["dev-entry"] as? String == "/dev/" + bsdName }
        }
        guard match, let disk = DiskEnumerator.disk(bsdName: bsdName) else { return false }
        return disk.isDiskImage && !disk.isOnBootDisk && access(rawPath, R_OK | W_OK) == 0
    }

    /// Opens the raw device without authorization. On a CI runner the open once failed with EACCES
    /// right after `isOurWritableImage()` saw the node writable, so permission errors are retried
    /// for a few seconds; one that lasts is reported with the node's owner and mode.
    func openRaw(writable: Bool) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(5)
        var retries = 0
        while true {
            do {
                let fd = try await RawDeviceOpener.open(bsdName: bsdName, writable: writable, allowAuthorization: false)
                if retries > 0 { print("AttachedImage: \(rawPath) opened after \(retries) permission retries") }
                return fd
            } catch RawDeviceError.openFailed(_, let code) where code == EACCES || code == EPERM {
                guard ContinuousClock.now < deadline else { throw PermissionDenied(path: rawPath, code: code) }
                retries += 1
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Describes the node when thrown: by the time the error is printed, the image is detached.
    struct PermissionDenied: Error, CustomStringConvertible {
        let description: String

        init(path: String, code: Int32) {
            var node = stat(), console = stat()
            let owner = stat(path, &node) == 0
                ? "uid \(node.st_uid), gid \(node.st_gid), mode \(String(node.st_mode & 0o777, radix: 8))" : "missing"
            let consoleUID = stat("/dev/console", &console) == 0 ? "\(console.st_uid)" : "?"
            description = "open(\(path)) kept failing with errno \(code) for 5 s; node: \(owner); "
                + "tests run as uid \(getuid()), console user uid \(consoleUID)"
        }
    }

    func detach() {
        if run("/usr/bin/hdiutil", ["detach", "/dev/" + bsdName]).status != 0 {
            run("/usr/bin/hdiutil", ["detach", "/dev/" + bsdName, "-force"])
        }
        try? FileManager.default.removeItem(at: imageURL)
    }

    /// Probed once: can this user create and attach images (no sandbox, hdiutil present)?
    static let isSupported: Bool = {
        guard let probe = make() else { return false }
        defer { probe.detach() }
        return probe.isOurWritableImage()
    }()
}

/// Collects values from concurrent closures.
final class Collector<T: Sendable>: Sendable {
    private let values = Mutex<[T]>([])
    func append(_ value: T) { values.withLock { $0.append(value) } }
    var all: [T] { values.withLock { $0 } }
}
