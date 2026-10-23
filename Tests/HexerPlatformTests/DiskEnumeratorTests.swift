import Foundation
import Testing
@testable import HexerPlatform

@Suite struct DiskEnumeratorTests {
    @Test func listsTheBootDiskWithSaneFields() throws {
        let disks = DiskEnumerator.disks()
        #expect(!disks.isEmpty)
        let names = Set(disks.map(\.bsdName))
        for disk in disks {
            #expect(disk.size > 0, "\(disk.bsdName)")
            #expect(disk.blockSize >= 512 && disk.blockSize & (disk.blockSize - 1) == 0, "\(disk.bsdName)")
            #expect(disk.physicalBlockSize >= disk.blockSize)
            #expect(disk.devicePath == "/dev/r" + disk.bsdName)
            #expect(names.contains(disk.wholeDiskBSDName))
            if let parent = disk.parentBSDName { #expect(names.contains(parent), "\(disk.bsdName) → \(parent)") }
            if disk.isWhole { #expect(disk.wholeDiskBSDName == disk.bsdName) }
            if disk.holdsBootVolume { #expect(disk.isOnBootDisk) }
        }
        #expect(disks.map { DiskEnumerator.sortKey($0.bsdName) } == disks.map { DiskEnumerator.sortKey($0.bsdName) }.sorted {
            $0.lexicographicallyPrecedes($1)
        })

        let bootName = try #require(DiskEnumerator.bootVolumeBSDName())
        let boot = try #require(disks.first { $0.bsdName == bootName })
        #expect(boot.mountPoint == "/")
        #expect(boot.holdsBootVolume)
        // The physical disk at the top of the chain holds it too, and is a real device.
        let physical = try #require(disks.first { $0.holdsBootVolume && $0.isWhole && $0.parentBSDName == nil })
        #expect(physical.isOnBootDisk)
        // Real hardware reports its bus (PCI-Express, USB…); virtual disks in VMs and CI runners may
        // only name the model or the media.
        #expect(physical.busProtocol != nil || physical.model != nil || physical.mediaName != nil)
        #expect(physical.size >= boot.size)
        #expect(disks.contains { $0.mountPoint == "/System/Volumes/Data" && $0.isOnBootDisk })
        #expect(DiskEnumerator.disk(bsdName: physical.bsdName)?.bsdName == physical.bsdName)
        #expect(DiskEnumerator.disk(bsdName: "disk999") == nil)
    }

    private func disk(_ name: String, parent: String?, whole: Bool, mount: String? = nil) -> DiskInfo {
        DiskInfo(bsdName: name, size: 1 << 30, blockSize: 512, physicalBlockSize: 4096, isWhole: whole, isLeaf: false,
                 wholeDiskBSDName: String(name.firstMatch(of: /^disk[0-9]+/)!.output), parentBSDName: parent, isWritable: true,
                 isRemovable: false, isEjectable: false, isInternal: true, busProtocol: nil, mediaName: nil, vendor: nil,
                 model: nil, content: nil, volumeKind: nil, volumeName: nil, mountPoint: mount)
    }

    /// disk0 → disk0s2 → disk3 (APFS container) → disk3s1 → disk3s1s1 at "/", plus an external disk4.
    private var sample: [DiskInfo] {
        [disk("disk4s1", parent: "disk4", whole: false), disk("disk3s1s1", parent: "disk3s1", whole: false, mount: "/"),
         disk("disk0", parent: nil, whole: true), disk("disk0s1", parent: "disk0", whole: false),
         disk("disk0s2", parent: "disk0", whole: false), disk("disk3", parent: "disk0s2", whole: true),
         disk("disk3s1", parent: "disk3", whole: false), disk("disk3s5", parent: "disk3", whole: false),
         disk("disk4", parent: nil, whole: true), disk("disk10", parent: nil, whole: true)]
    }

    @Test func bootFlagsFollowTheMediaTree() {
        let marked = DiskEnumerator.markBootDisk(sample, bootBSDName: "disk3s1s1")
        #expect(marked.map(\.bsdName) == ["disk0", "disk0s1", "disk0s2", "disk3", "disk3s1", "disk3s1s1", "disk3s5",
                                          "disk4", "disk4s1", "disk10"])
        #expect(marked.filter(\.holdsBootVolume).map(\.bsdName) == ["disk0", "disk0s2", "disk3", "disk3s1", "disk3s1s1"])
        #expect(marked.filter(\.isOnBootDisk).map(\.bsdName) == ["disk0", "disk0s1", "disk0s2", "disk3", "disk3s1",
                                                                  "disk3s1s1", "disk3s5"])
        #expect(marked.first { $0.bsdName == "disk3" }?.isSynthesized == true)
        #expect(marked.first { $0.bsdName == "disk0" }?.isSynthesized == false)
        #expect(DiskEnumerator.markBootDisk(sample, bootBSDName: nil).allSatisfy { !$0.isOnBootDisk && !$0.holdsBootVolume })
    }

    @Test func unmountRefusesTheBootDiskAndFindsContainers() {
        let marked = DiskEnumerator.markBootDisk(sample, bootBSDName: "disk3s1s1")
        for disk in marked {
            if disk.isOnBootDisk {
                #expect(throws: DiskArbitrationError.bootDisk(bsdName: disk.bsdName)) {
                    try DiskArbitrationSession.checkUnmountAllowed(disk)
                }
            } else {
                #expect(throws: Never.self) { try DiskArbitrationSession.checkUnmountAllowed(disk) }
            }
        }
        #expect(DiskArbitrationSession.synthesizedDescendants(of: "disk0", in: marked).map(\.bsdName) == ["disk3"])
        #expect(DiskArbitrationSession.synthesizedDescendants(of: "disk0s2", in: marked).map(\.bsdName) == ["disk3"])
        #expect(DiskArbitrationSession.synthesizedDescendants(of: "disk4", in: marked).isEmpty)
    }

    @Test func unmountingAMissingDiskThrows() async {
        await #expect(throws: DiskArbitrationError.notFound(bsdName: "disk999")) {
            try await DiskArbitrationSession.shared.unmount(bsdName: "disk999")
        }
    }

    @Test func wellKnownPartitionTypesHaveNames() {
        var info = disk("disk9s1", parent: "disk9", whole: false)
        info.content = "7c3457ef-0000-11aa-aa11-00306543ecac"
        #expect(info.contentDescription == "Apple_APFS")
        info.content = "GUID_partition_scheme"
        #expect(info.contentDescription == "GUID_partition_scheme")
        #expect(DiskEvent.changed(bsdName: "disk2").bsdName == "disk2")
    }
}
