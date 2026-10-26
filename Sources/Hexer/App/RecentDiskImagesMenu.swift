import AppKit
import HexerCore

/// File ▸ Open Recent Disk Image, HxD's separate history list: images opened with Open Disk Image
/// are listed here with their sector size and never in the normal Open Recent (see
/// `HexDocumentController.noteNewRecentDocument`). The list is kept in UserDefaults.
final class RecentDiskImagesMenu: NSObject, NSMenuDelegate {
    static let shared = RecentDiskImagesMenu()
    private static let defaultsKey = "RecentDiskImages"

    private(set) var list: RecentDiskImages

    private override init() {
        list = RecentDiskImages(decoding: UserDefaults.standard.data(forKey: Self.defaultsKey))
        super.init()
    }

    private func save() { UserDefaults.standard.set(list.encoded(), forKey: Self.defaultsKey) }

    /// The submenu for the File menu; `menuNeedsUpdate` fills it each time it opens.
    func makeMenuItem() -> NSMenuItem {
        let title = L("Open Recent Disk Image")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        menu.delegate = self
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (entry, title) in zip(list.entries, list.titles) {
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.path
            item.toolTip = entry.path + "\n" + L("Sector size: %lld bytes", entry.sectorSize)
            menu.addItem(item)
        }
        if !list.entries.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: L("Clear Menu"), action: #selector(clearMenu(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !list.entries.isEmpty
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let sectorSize = list.sectorSize(for: URL(fileURLWithPath: path)) else { return }
        Self.open(URL(fileURLWithPath: path), sectorSize: sectorSize)
    }

    @objc private func clearMenu(_ sender: Any?) {
        list.clear()
        save()
    }

    /// Drops a file from the list, e.g. after Wipe Securely deleted it.
    func remove(_ url: URL) {
        list.remove(url)
        save()
    }

    /// Opens `url` as a disk image of that sector size. A window that is already open for the file is
    /// shown as it is. The list learns the image once it is open, and forgets a file that is gone.
    static func open(_ url: URL, sectorSize: Int) {
        let url = url.standardizedFileURL
        HexDocument.pendingDiskImages[url] = sectorSize
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            HexDocument.pendingDiskImages[url] = nil
            if let error {
                if !FileManager.default.fileExists(atPath: url.path) { shared.remove(url) }
                NSApp.presentError(error)
            } else if (document as? HexDocument)?.isDiskImage == true {
                shared.list.record(url, sectorSize: sectorSize)
                shared.save()
            }
        }
    }
}
