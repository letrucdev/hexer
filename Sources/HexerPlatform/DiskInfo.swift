/// One IOKit `IOMedia` object — a whole disk, a partition, an APFS container or volume, a
/// snapshot — with its DiskArbitration description, as of `DiskEnumerator.disks()`.
public struct DiskInfo: Sendable, Hashable, Identifiable {
    /// BSD name: "disk4", "disk4s1", "disk3s1s1".
    public var bsdName: String
    public var size: UInt64
    /// Logical sector size ("Preferred Block Size"); raw I/O must be aligned to it.
    public var blockSize: Int
    /// Physical sector size from the storage driver, or `blockSize` when not reported.
    public var physicalBlockSize: Int
    public var isWhole: Bool
    /// Has no child media (no partition scheme, container or volumes carved from it).
    public var isLeaf: Bool
    /// The whole disk this media belongs to: "disk4" for "disk4s1", itself when whole.
    public var wholeDiskBSDName: String
    /// The media this one is carved from: the whole disk of a partition, the physical store of a
    /// synthesized APFS container, the volume of a snapshot. `nil` for physical whole disks.
    public var parentBSDName: String?
    public var isWritable: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    /// Bus or protocol: "USB", "SATA", "PCI-Express", "Apple Fabric", "Disk Image", …
    public var busProtocol: String?
    /// IOKit media name: "APPLE SSD AP0512Z Media", "Disk Image", "Macintosh HD", …
    public var mediaName: String?
    public var vendor: String?
    public var model: String?
    /// Partition scheme ("GUID_partition_scheme") or partition type (often a GPT type GUID);
    /// see `contentDescription`.
    public var content: String?
    /// File system of the volume on this media ("apfs", "msdos", "hfs", "exfat"), if recognised.
    public var volumeKind: String?
    public var volumeName: String?
    /// Where the volume is mounted, if it is.
    public var mountPoint: String?
    /// This media or one of its descendants is mounted at "/".
    public var holdsBootVolume: Bool
    /// Shares a physical disk with the boot volume: the boot disk, all of its partitions, and the
    /// APFS containers and volumes built on them. The UI should refuse to write to these, and
    /// `DiskArbitrationSession.unmount` refuses them.
    public var isOnBootDisk: Bool

    public init(bsdName: String, size: UInt64, blockSize: Int, physicalBlockSize: Int, isWhole: Bool, isLeaf: Bool,
                wholeDiskBSDName: String, parentBSDName: String?, isWritable: Bool, isRemovable: Bool,
                isEjectable: Bool, isInternal: Bool, busProtocol: String?, mediaName: String?, vendor: String?,
                model: String?, content: String?, volumeKind: String?, volumeName: String?, mountPoint: String?,
                holdsBootVolume: Bool = false, isOnBootDisk: Bool = false) {
        self.bsdName = bsdName
        self.size = size
        self.blockSize = blockSize
        self.physicalBlockSize = physicalBlockSize
        self.isWhole = isWhole
        self.isLeaf = isLeaf
        self.wholeDiskBSDName = wholeDiskBSDName
        self.parentBSDName = parentBSDName
        self.isWritable = isWritable
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.busProtocol = busProtocol
        self.mediaName = mediaName
        self.vendor = vendor
        self.model = model
        self.content = content
        self.volumeKind = volumeKind
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.holdsBootVolume = holdsBootVolume
        self.isOnBootDisk = isOnBootDisk
    }

    public var id: String { bsdName }
    /// The raw (unbuffered) character device used for all I/O: "/dev/rdisk4".
    public var devicePath: String { "/dev/r" + bsdName }
    /// The buffered block device: "/dev/disk4".
    public var blockDevicePath: String { "/dev/" + bsdName }
    public var isMounted: Bool { mountPoint != nil }
    /// A whole disk carved from other media, such as an APFS container ("synthesized" in diskutil).
    public var isSynthesized: Bool { isWhole && parentBSDName != nil }
    public var isDiskImage: Bool { busProtocol == "Disk Image" }

    /// `content` with well-known GPT partition type GUIDs replaced by their usual names.
    public var contentDescription: String? {
        guard let content else { return nil }
        return Self.partitionTypeNames[content.uppercased()] ?? content
    }

    static let partitionTypeNames: [String: String] = [
        "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": "EFI",
        "48465300-0000-11AA-AA11-00306543ECAC": "Apple_HFS",
        "7C3457EF-0000-11AA-AA11-00306543ECAC": "Apple_APFS",
        "69646961-6700-11AA-AA11-00306543ECAC": "Apple_APFS_ISC",
        "52637672-7900-11AA-AA11-00306543ECAC": "Apple_APFS_Recovery",
        "EF57347C-0000-11AA-AA11-00306543ECAC": "APFS Container",
        "41504653-0000-11AA-AA11-00306543ECAC": "APFS Volume",
        "426F6F74-0000-11AA-AA11-00306543ECAC": "Apple_Boot",
        "55465300-0000-11AA-AA11-00306543ECAC": "Apple_UFS",
        "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7": "Microsoft Basic Data",
        "E3C9E316-0B5C-4DB8-817D-F92DF00215AE": "Microsoft Reserved",
        "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC": "Windows Recovery",
        "0FC63DAF-8483-4772-8E79-3D69D8477DE4": "Linux Filesystem",
        "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F": "Linux Swap",
        "E6D6D379-F507-44C2-A23C-238F2A3DF928": "Linux LVM",
        "A19D880F-05FC-4D3B-A006-743F0F84911E": "Linux RAID",
        "21686148-6449-6E6F-744E-656564454649": "BIOS Boot",
    ]
}

/// A change reported by `DiskEnumerator.events()`.
public enum DiskEvent: Sendable, Hashable {
    case appeared(bsdName: String)
    case disappeared(bsdName: String)
    /// The description changed: mounted, unmounted, renamed, …
    case changed(bsdName: String)

    public var bsdName: String {
        switch self {
        case .appeared(let name), .disappeared(let name), .changed(let name): name
        }
    }
}
