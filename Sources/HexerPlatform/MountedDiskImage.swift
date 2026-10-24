import Foundation

/// A disk image attached read-only with `hdiutil`, hidden from the Finder. Call `detach()` when done.
public final class MountedDiskImage: Sendable {
    public let mountPoint: URL

    private init(mountPoint: URL) { self.mountPoint = mountPoint }

    public enum Failure: Error, Equatable, LocalizedError {
        case attachFailed(String)

        public var errorDescription: String? {
            switch self {
            case .attachFailed(let message): "The disk image could not be opened: \(message)"
            }
        }
    }

    /// Attaches `image` and mounts its volume in a new folder inside `folder`. The image's own
    /// checksums are not verified (2 s for Hexer's), as callers check its signature first.
    ///
    /// macOS 26 deprecates `hdiutil attach` for `diskutil image attach`, which macOS 15 lacks.
    public static func attach(_ image: URL, inside folder: URL) throws -> MountedDiskImage {
        let result = hdiutil(["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountrandom", folder.path,
                              "-plist", image.path])
        guard result.status == 0 else {
            throw Failure.attachFailed(result.error.isEmpty ? "hdiutil exited with status \(result.status)." : result.error)
        }
        let plist = try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let path = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else {
            // Attached without a volume (no file system hdiutil could mount): let it go again.
            for case let device as String in entities.compactMap({ $0["dev-entry"] }) { _ = hdiutil(["detach", device, "-force"]) }
            throw Failure.attachFailed("it contains no volume.")
        }
        return MountedDiskImage(mountPoint: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Unmounts the volume and detaches the image, forcibly if a file on it is still open.
    public func detach() {
        if Self.hdiutil(["detach", mountPoint.path, "-quiet"]).status != 0 {
            _ = Self.hdiutil(["detach", mountPoint.path, "-quiet", "-force"])
        }
    }

    private static func hdiutil(_ arguments: [String]) -> (status: Int32, output: Data, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data(), error.localizedDescription) }
        // Both pipes at once: a full stderr pipe would otherwise stall hdiutil before stdout ends.
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        // Without the deprecation notice macOS 26 prints for `attach` (see above).
        let message = String(decoding: errorData, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("hdiutil: WARNING:") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output, message)
    }
}
