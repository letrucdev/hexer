import DiskArbitration
import Foundation
import IOKit

/// Lists disks and partitions (IOKit `IOMedia` objects described by DiskArbitration) and reports
/// when they come and go.
public enum DiskEnumerator {
    /// Every media object, ordered by BSD name ("disk0", "disk0s1", "disk0s2", "disk1", …).
    public static func disks() -> [DiskInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        let session = DASessionCreate(kCFAllocatorDefault)
        var found: [DiskInfo] = []
        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }
            if let info = describe(media, session: session) { found.append(info) }
        }
        return markBootDisk(found, bootBSDName: bootVolumeBSDName())
    }

    /// The current description of one disk, or `nil` if it is gone.
    public static func disk(bsdName: String) -> DiskInfo? {
        disks().first { $0.bsdName == bsdName }
    }

    /// Disk appeared / disappeared / description-changed notifications from DiskArbitration.
    /// Disks present when the stream starts are reported as `appeared` first.
    public static func events() -> AsyncStream<DiskEvent> {
        AsyncStream { continuation in
            let watcher = DiskWatcher(continuation)
            continuation.onTermination = { _ in watcher.stop() }
        }
    }

    // MARK: Description

    private static func describe(_ media: io_object_t, session: DASession?) -> DiskInfo? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(media, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              let bsdName = properties["BSD Name"] as? String else { return nil }
        let disk = session.flatMap { DADiskCreateFromIOMedia(kCFAllocatorDefault, $0, media) }
        let description = disk.flatMap { DADiskCopyDescription($0) as? [String: Any] } ?? [:]
        func da<T>(_ key: CFString) -> T? { description[key as String] as? T }

        let isWhole = properties["Whole"] as? Bool ?? false
        let blockSize = (properties["Preferred Block Size"] as? NSNumber)?.intValue ?? 512
        let physical = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Physical Block Size" as CFString,
                                                       kCFAllocatorDefault,
                                                       IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        var whole = bsdName
        if !isWhole, let disk, let wholeDisk = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(wholeDisk) {
            whole = String(cString: name)
        } else if !isWhole, let match = bsdName.firstMatch(of: /^disk[0-9]+/) {
            whole = String(match.output)
        }
        let volumePath: URL? = da(kDADiskDescriptionVolumePathKey)
        return DiskInfo(
            bsdName: bsdName,
            size: (properties["Size"] as? NSNumber)?.uint64Value ?? 0,
            blockSize: blockSize,
            physicalBlockSize: max((physical as? NSNumber)?.intValue ?? blockSize, blockSize),
            isWhole: isWhole,
            isLeaf: properties["Leaf"] as? Bool ?? true,
            wholeDiskBSDName: whole,
            parentBSDName: parentMediaBSDName(of: media),
            isWritable: properties["Writable"] as? Bool ?? false,
            isRemovable: properties["Removable"] as? Bool ?? false,
            isEjectable: properties["Ejectable"] as? Bool ?? false,
            isInternal: da(kDADiskDescriptionDeviceInternalKey) ?? false,
            busProtocol: isBackedByDiskImage(media) ? "Disk Image" : da(kDADiskDescriptionDeviceProtocolKey),
            mediaName: da(kDADiskDescriptionMediaNameKey),
            vendor: (da(kDADiskDescriptionDeviceVendorKey) as String?)?.trimmed,
            model: (da(kDADiskDescriptionDeviceModelKey) as String?)?.trimmed,
            content: [properties["Content"] as? String, da(kDADiskDescriptionMediaContentKey)].compactMap { $0 }
                .first { !$0.isEmpty },
            volumeKind: da(kDADiskDescriptionVolumeKindKey),
            volumeName: da(kDADiskDescriptionVolumeNameKey),
            mountPoint: volumePath.map { $0.path(percentEncoded: false) }.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        )
    }

    /// BSD name of the nearest `IOMedia` above `media` in the service plane.
    private static func parentMediaBSDName(of media: io_object_t) -> String? {
        var current = media
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOMedia") != 0 {
                return IORegistryEntryCreateCFProperty(current, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            }
        }
    }

    /// Whether a disk image driver (IOHDIX…, AppleDiskImage…) is above `media`. DiskArbitration
    /// reports such disks as "Virtual Interface"; diskutil calls the protocol "Disk Image".
    private static func isBackedByDiskImage(_ media: io_object_t) -> Bool {
        var current = media
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            IOObjectRelease(current)
            current = parent
            if let name = IOObjectCopyClass(current)?.takeRetainedValue() as String?,
               name.hasPrefix("IOHDIX") || name.hasPrefix("AppleDiskImage") || name.hasPrefix("IODiskImage") {
                return true
            }
        }
    }

    /// BSD name of the device mounted at "/" (on current macOS, the sealed system snapshot).
    static func bootVolumeBSDName() -> String? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let from = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard from.hasPrefix("/dev/") else { return nil }
        return String(from.dropFirst(5))
    }

    /// Sets `holdsBootVolume` and `isOnBootDisk`, and sorts by BSD name.
    static func markBootDisk(_ disks: [DiskInfo], bootBSDName: String?) -> [DiskInfo] {
        let parents = Dictionary(disks.map { ($0.bsdName, $0.parentBSDName) }, uniquingKeysWith: { a, _ in a })
        func ancestry(_ name: String) -> [String] {
            var chain = [name]
            while let parent = parents[chain.last!] ?? nil, !chain.contains(parent), chain.count < 64 {
                chain.append(parent)
            }
            return chain
        }
        let bootChain = bootBSDName.map(ancestry) ?? []
        let bootRoot = bootChain.last
        return disks.map { disk in
            var disk = disk
            disk.holdsBootVolume = bootChain.contains(disk.bsdName)
            disk.isOnBootDisk = bootRoot != nil && ancestry(disk.bsdName).last == bootRoot
            return disk
        }.sorted { sortKey($0.bsdName).lexicographicallyPrecedes(sortKey($1.bsdName)) }
    }

    /// "disk3s1s2" → [3, 1, 2].
    static func sortKey(_ bsdName: String) -> [Int] {
        bsdName.dropFirst(4).split(separator: "s").map { Int($0) ?? Int.max }
    }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

/// Forwards DiskArbitration callbacks for one `events()` stream.
private final class DiskWatcher: @unchecked Sendable {
    private let continuation: AsyncStream<DiskEvent>.Continuation
    private let session: DASession?
    private let queue = DispatchQueue(label: "Hexer.DiskWatcher")

    init(_ continuation: AsyncStream<DiskEvent>.Continuation) {
        self.continuation = continuation
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else {
            continuation.finish()
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, Self.appeared, context)
        DARegisterDiskDisappearedCallback(session, nil, Self.disappeared, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, Self.changed, context)
        DASessionSetDispatchQueue(session, queue)
    }

    /// Unregisters on the callback queue; the closure keeps `self` alive until then.
    func stop() {
        queue.async { [self] in
            guard let session else { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            DAUnregisterCallback(session, unsafeBitCast(Self.appeared, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(Self.disappeared, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(Self.changed, to: UnsafeMutableRawPointer.self), context)
            DASessionSetDispatchQueue(session, nil)
        }
    }

    private func yield(_ disk: DADisk, _ event: (String) -> DiskEvent) {
        guard let name = DADiskGetBSDName(disk) else { return }
        continuation.yield(event(String(cString: name)))
    }

    private static func watcher(_ context: UnsafeMutableRawPointer?) -> DiskWatcher {
        Unmanaged<DiskWatcher>.fromOpaque(context!).takeUnretainedValue()
    }

    private static let appeared: DADiskAppearedCallback = { disk, context in
        watcher(context).yield(disk) { .appeared(bsdName: $0) }
    }
    private static let disappeared: DADiskDisappearedCallback = { disk, context in
        watcher(context).yield(disk) { .disappeared(bsdName: $0) }
    }
    private static let changed: DADiskDescriptionChangedCallback = { disk, _, context in
        watcher(context).yield(disk) { .changed(bsdName: $0) }
    }
}
