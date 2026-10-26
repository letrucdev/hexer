import Foundation

/// HxD's `RecentDiskImages` history list: the disk images opened with File ▸ Open Disk Image, most
/// recent first, each with the sector size it was opened with so reopening needs no question.
/// Raw disks have no such list (HxD has none either).
public struct RecentDiskImages: Equatable, Sendable {
    public struct Entry: Equatable, Hashable, Codable, Sendable {
        /// Standardized file path.
        public var path: String
        public var sectorSize: Int

        public var url: URL { URL(fileURLWithPath: path) }
    }

    /// Like HxD's history lists.
    public static let capacity = 10

    /// Most recent first, never more than `capacity`, one entry per path.
    public private(set) var entries: [Entry] = []

    public init() {}

    /// The key a file is known by: its standardized path (`..` and `.` resolved, no trailing slash).
    public static func key(for url: URL) -> String { url.standardizedFileURL.path }

    /// Puts the image at the top, replacing an earlier entry for the same file (and its sector size).
    /// Ignores a sector size that is not positive.
    public mutating func record(_ url: URL, sectorSize: Int) {
        guard sectorSize > 0 else { return }
        let path = Self.key(for: url)
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, sectorSize: sectorSize), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    /// Drops the entry for `url` (a missing or wiped file); nothing happens if it is not listed.
    public mutating func remove(_ url: URL) {
        let path = Self.key(for: url)
        entries.removeAll { $0.path == path }
    }

    public mutating func clear() { entries.removeAll() }

    public func sectorSize(for url: URL) -> Int? {
        let path = Self.key(for: url)
        return entries.first { $0.path == path }?.sectorSize
    }

    /// Menu titles, one per entry: the file name, followed by " — " and its folder's name when
    /// another entry has the same file name.
    public var titles: [String] {
        let names = entries.map { $0.url.lastPathComponent }
        return zip(entries, names).map { entry, name in
            guard names.filter({ $0 == name }).count > 1 else { return name }
            let folder = entry.url.deletingLastPathComponent().lastPathComponent
            return folder.isEmpty ? name : "\(name) — \(folder)"
        }
    }

    // MARK: Storage

    /// JSON for UserDefaults.
    public func encoded() -> Data { (try? JSONEncoder().encode(entries)) ?? Data() }

    /// Reads what `encoded()` wrote. Data that is not a list yields an empty one; entries with an
    /// empty path or a non-positive sector size and repeats of a path are skipped, and the list is
    /// cut to `capacity`.
    public init(decoding data: Data?) {
        guard let data, let stored = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        var seen = Set<String>()
        for entry in stored where !entry.path.isEmpty && entry.sectorSize > 0 && seen.insert(entry.path).inserted {
            entries.append(entry)
            if entries.count == Self.capacity { break }
        }
    }
}
