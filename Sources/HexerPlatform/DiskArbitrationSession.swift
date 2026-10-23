import DiskArbitration
import Foundation

/// Why DiskArbitration could not unmount or mount a disk.
public enum DiskArbitrationError: Error, Equatable, Sendable, LocalizedError {
    case notFound(bsdName: String)
    /// The disk holds, or shares a physical disk with, the boot volume.
    case bootDisk(bsdName: String)
    /// DiskArbitration (or an app holding files open) refused; `status` is the `DAReturn` code.
    case dissented(bsdName: String, status: Int32, message: String?)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name): "The disk \(name) was not found. It may have been ejected."
        case .bootDisk(let name): "\(name) is on the startup disk, which cannot be unmounted for writing."
        case .dissented(let name, let status, let message):
            if let message, !message.isEmpty {
                "\(name) could not be unmounted or mounted: \(message)"
            } else if status == Int32(bitPattern: UInt32(kDAReturnBusy)) {
                "\(name) is in use by another application."
            } else {
                "\(name) could not be unmounted or mounted (error 0x\(String(UInt32(bitPattern: status), radix: 16)))."
            }
        }
    }
}

/// Unmounts a disk's volumes before raw writes and mounts them again afterwards.
public final class DiskArbitrationSession: @unchecked Sendable {
    public static let shared = DiskArbitrationSession()

    private let session: DASession?
    private let queue = DispatchQueue(label: "Hexer.DiskArbitrationSession")

    public init() {
        session = DASessionCreate(kCFAllocatorDefault)
        if let session { DASessionSetDispatchQueue(session, queue) }
    }

    deinit {
        if let session { DASessionSetDispatchQueue(session, nil) }
    }

    /// Unmounts every volume on `bsdName`: all volumes of a whole disk (`kDADiskUnmountOptionWhole`)
    /// or the partition's volume, plus the volumes of APFS containers built on it. Throws
    /// `bootDisk` without touching anything for media on the boot disk.
    public func unmount(bsdName: String, force: Bool = false) async throws {
        let all = DiskEnumerator.disks()
        guard let disk = all.first(where: { $0.bsdName == bsdName }) else { throw DiskArbitrationError.notFound(bsdName: bsdName) }
        let containers = Self.synthesizedDescendants(of: bsdName, in: all)
        for target in [disk] + containers { try Self.checkUnmountAllowed(target) }
        var options = DADiskUnmountOptions(force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault)
        // Deepest first: container volumes, then the disk itself.
        for container in containers.reversed() {
            try await perform(container.bsdName) { disk, context in
                DADiskUnmount(disk, options | DADiskUnmountOptions(kDADiskUnmountOptionWhole), Self.completion, context)
            }
        }
        if disk.isWhole { options |= DADiskUnmountOptions(kDADiskUnmountOptionWhole) }
        guard disk.isWhole || disk.isMounted else { return }
        try await perform(bsdName) { disk, context in
            DADiskUnmount(disk, options, Self.completion, context)
        }
    }

    /// Mounts the volumes of `bsdName` (all of them for a whole disk) and of APFS containers built
    /// on it. Every target is attempted; the first failure is thrown afterwards.
    public func mount(bsdName: String) async throws {
        let all = DiskEnumerator.disks()
        guard let disk = all.first(where: { $0.bsdName == bsdName }) else { throw DiskArbitrationError.notFound(bsdName: bsdName) }
        var firstError: Error?
        for target in [disk] + Self.synthesizedDescendants(of: bsdName, in: all) {
            let options = DADiskMountOptions(target.isWhole ? kDADiskMountOptionWhole : kDADiskMountOptionDefault)
            do {
                try await perform(target.bsdName) { disk, context in
                    DADiskMount(disk, nil, options, Self.completion, context)
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Refuses media that hold or share a physical disk with the boot volume.
    static func checkUnmountAllowed(_ disk: DiskInfo) throws {
        if disk.isOnBootDisk || disk.holdsBootVolume { throw DiskArbitrationError.bootDisk(bsdName: disk.bsdName) }
    }

    /// Synthesized whole disks (APFS containers) whose ancestry includes `bsdName`, shallowest first.
    static func synthesizedDescendants(of bsdName: String, in all: [DiskInfo]) -> [DiskInfo] {
        let byName = Dictionary(all.map { ($0.bsdName, $0) }, uniquingKeysWith: { a, _ in a })
        func depth(_ disk: DiskInfo) -> Int? {
            var current = disk, steps = 0
            while let parent = current.parentBSDName, let next = byName[parent], steps < 64 {
                steps += 1
                if parent == bsdName { return steps }
                current = next
            }
            return nil
        }
        return all.compactMap { d in d.isSynthesized ? depth(d).map { (d, $0) } : nil }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private final class Pending: Sendable {
        let bsdName: String
        let continuation: CheckedContinuation<Void, Error>
        init(_ bsdName: String, _ continuation: CheckedContinuation<Void, Error>) {
            self.bsdName = bsdName
            self.continuation = continuation
        }
    }

    /// Starts a DiskArbitration request and waits for its callback.
    private func perform(_ bsdName: String, _ start: (DADisk, UnsafeMutableRawPointer) -> Void) async throws {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw DiskArbitrationError.notFound(bsdName: bsdName)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            start(disk, Unmanaged.passRetained(Pending(bsdName, continuation)).toOpaque())
        }
    }

    /// Shared by mount and unmount, whose callbacks have the same shape.
    private static let completion: DADiskUnmountCallback = { _, dissenter, context in
        let pending = Unmanaged<Pending>.fromOpaque(context!).takeRetainedValue()
        guard let dissenter else { return pending.continuation.resume() }
        let status = DADissenterGetStatus(dissenter)
        // Already in the requested state.
        if status == Int32(bitPattern: UInt32(kDAReturnNotMounted)) { return pending.continuation.resume() }
        let message = DADissenterGetStatusString(dissenter) as String?
        pending.continuation.resume(throwing: DiskArbitrationError.dissented(bsdName: pending.bsdName, status: status,
                                                                             message: message))
    }
}
