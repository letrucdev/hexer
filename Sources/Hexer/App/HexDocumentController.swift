import AppKit

/// Opens any file as a `HexDocument`, even when running without an Info.plist.
final class HexDocumentController: NSDocumentController {
    static let documentType = "public.data"

    override var documentClassNames: [String] { [NSStringFromClass(HexDocument.self)] }
    override var defaultType: String? { Self.documentType }

    override func documentClass(forType typeName: String) -> AnyClass? { HexDocument.self }

    override func typeForContents(of url: URL) throws -> String { Self.documentType }

    override func displayName(forType typeName: String) -> String? { L("Binary File") }

    /// Disk images are listed in File ▸ Open Recent Disk Image (with their sector size) and not here:
    /// reopened from the normal list they would open as plain, resizable files.
    override func noteNewRecentDocument(_ document: NSDocument) {
        guard (document as? HexDocument)?.isDiskImage != true else { return }
        super.noteNewRecentDocument(document)
    }

    override func noteNewRecentDocumentURL(_ url: URL) {
        guard (self.document(for: url) as? HexDocument)?.isDiskImage != true else { return }
        super.noteNewRecentDocumentURL(url)
    }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        openPanel.treatsFilePackagesAsDirectories = true
        openPanel.showsHiddenFiles = true
        return super.runModalOpenPanel(openPanel, forTypes: nil)
    }
}
