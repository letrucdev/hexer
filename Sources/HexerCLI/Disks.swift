import Foundation
import HexerCore
import HexerPlatform

/// `disks [list]` and `disks read NAME [--range RANGE] [--sector-size N] [-o OUT]`
///
/// `list` prints every disk and partition the Open Disk window offers, one per line:
/// `NAME SIZE BLOCK whole|part FLAGS DESCRIPTION` with SIZE in bytes, BLOCK the logical sector size
/// and FLAGS from internal/external, removable, writable, image, boot (on the startup disk, which
/// Hexer never writes) and mounted.
///
/// `read` copies raw bytes of a disk ("disk4", "disk4s1") or a disk image file, reading whole
/// sectors as the app does. There is no administrator prompt here: the device must be readable
/// (attached disk images are; other disks need sudo).
func disks(_ args: [String]) {
    switch args.first {
    case nil, "list": listDisks(Array(args.dropFirst()))
    case "read": readDisk(Array(args.dropFirst()))
    case let other?: fail("disks: unknown subcommand \(other) (list, read)")
    }
}

private func listDisks(_ args: [String]) {
    _ = Arguments(args, command: "disks list").expect(0, usage: "disks [list]")
    let out = Output()
    for disk in DiskEnumerator.disks() {
        var flags = [disk.isInternal ? "internal" : "external"]
        if disk.isRemovable { flags.append("removable") }
        if disk.isWritable { flags.append("writable") }
        if disk.isDiskImage { flags.append("image") }
        if disk.isOnBootDisk || disk.holdsBootVolume { flags.append("boot") }
        if disk.isMounted { flags.append("mounted") }
        let description = disk.volumeName ?? disk.model ?? disk.mediaName ?? disk.contentDescription ?? ""
        out.write([disk.bsdName, String(disk.size), String(disk.blockSize), disk.isWhole ? "whole" : "part",
                   flags.joined(separator: ","), description].joined(separator: "  ") + "\n")
    }
    out.close()
}

private func readDisk(_ args: [String]) {
    let usage = "disks read NAME|IMAGE [--range RANGE] [--sector-size N] [-o OUT]"
    let a = Arguments(args, command: "disks read", options: ["--range", "--sector-size", "-o"])
    let name = a.expect(1, usage: usage)[0]
    let path = (try? RawDeviceOpener.devicePath(forBSDName: name)) ?? name
    let sectorSize = Int(clamping: a.number("--sector-size") ?? 512)
    let source = attempt("disks read") { try DiskByteSource(path: path, sectorSize: sectorSize) }
    let range = parseRange(a.value("--range"), length: source.length)
    let out = Output.to(a.value("-o"))
    let chunk = 1 << 20
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
    defer { buffer.deallocate() }
    var offset = range.lowerBound
    while offset < range.upperBound {
        let want = Int(min(UInt64(chunk), range.upperBound - offset))
        let n = attempt("disks read") { try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<want]), at: offset) }
        guard n > 0 else { fail("disks read: \(path) ended at \(offset)") }
        out.write(bytes: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
        offset += UInt64(n)
    }
    out.close()
}
