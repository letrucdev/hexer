import AppKit
import HexerCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        DebugLaunchArguments.apply()
        SoftwareUpdate.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SoftwareUpdate.shared.applicationWillTerminate()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates(_:)) || SoftwareUpdate.shared.canUpdate
    }

    /// Launching without a document, or clicking the Dock icon with no window open, shows the Open
    /// panel instead of an untitled document; the very first time, the welcome tour comes first.
    /// Scripted runs open their own documents, so they skip both.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !DebugLaunchArguments.isScripted }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Once the launch event is handled, so a file opened from Finder meanwhile isn't held behind the panel.
        DispatchQueue.main.async {
            guard !WelcomeWindowController.showIfFirstLaunch() else { return }
            NSDocumentController.shared.openDocument(nil)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Every `presentError` (documents' included) ends up here; core errors get their UI-language text.
    func application(_ application: NSApplication, willPresentError error: Error) -> Error { error.localizedForDisplay }

    @objc func importIntelHex(_ sender: Any?) { RecordImport.run(.intelHex) }
    @objc func importSRecord(_ sender: Any?) { RecordImport.run(.motorolaSRecord) }
    @objc func importETLExtended(_ sender: Any?) { RecordImport.run(.etlExtended) }

    @objc func showAbout(_ sender: Any?) { AboutAndHelp.showAbout() }
    @objc func showAcknowledgements(_ sender: Any?) { AboutAndHelp.showAcknowledgements() }
    @objc func showHelp(_ sender: Any?) { AboutAndHelp.showHelp() }
    @objc func showWelcome(_ sender: Any?) { WelcomeWindowController.show() }
    @objc func checkForUpdates(_ sender: Any?) { SoftwareUpdate.shared.checkForUpdates() }

    @objc func openDisk(_ sender: Any?) {
        let model = OpenDiskModel()
        ToolWindowController.show(L("Open Disk")) { OpenDiskView(model: model, controller: $0) }
    }

    @objc func cloneDisk(_ sender: Any?) {
        let model = CloneDiskModel()
        ToolWindowController.show(L("Clone Disk")) { CloneDiskView(model: model, controller: $0) }
    }

    @objc func openDiskImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = L("Choose a disk image to open. It keeps its size, like a disk: bytes can be overwritten but not inserted or deleted.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = L("Sector size")
        alert.informativeText = L("Specify the sector size of “%@”.", url.lastPathComponent)
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        for (title, size) in [(L("512 bytes (hard disks, USB drives)"), 512), (L("2048 bytes (CD, DVD)"), 2048),
                              (L("4096 bytes (Advanced Format)"), 4096)] {
            picker.addItem(withTitle: title)
            picker.lastItem?.tag = size
        }
        alert.accessoryView = picker
        alert.addButton(withTitle: L("Open"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HexDocument.pendingDiskImages[url.standardizedFileURL] = picker.selectedTag()
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    // MARK: Tools

    /// The file of the frontmost document, to start file tools with.
    private var currentFile: URL? { (NSDocumentController.shared.currentDocument as? HexDocument)?.fileURL }

    @objc func splitFile(_ sender: Any?) {
        let model = SplitModel()
        model.source = currentFile
        ToolWindowController.show(L("Split File")) { SplitFileView(model: model, controller: $0) }
    }

    @objc func concatenateFiles(_ sender: Any?) {
        let model = ConcatenateModel()
        ToolWindowController.show(L("Concatenate Files")) { ConcatenateFilesView(model: model, controller: $0) }
    }

    @objc func wipeFile(_ sender: Any?) {
        let model = WipeModel()
        model.file = currentFile
        ToolWindowController.show(L("Wipe Securely")) { WipeFileView(model: model, controller: $0) }
    }

    /// Shows Settings at pane `pane` (0 General … 3 Inspector, 4 Export).
    static func openSettings(pane: Int) {
        SettingsWindowController.shared.showWindow(nil)
        (SettingsWindowController.shared.window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = pane
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }
}
