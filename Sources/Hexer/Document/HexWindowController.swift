import AppKit
import HexerCore
import SwiftUI

/// A document window: native tabs, a SwiftUI split view hosting the AppKit grid, and the
/// actions of the View and Search menus.
final class HexWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: EditorSession

    init(document: HexDocument) {
        session = document.session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "HexerDocument"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 720, height: 420)
        let host = NSHostingController(rootView: DocumentWindowView(session: document.session))
        // Before macOS 26 the SwiftUI split view draws the title bar itself and drops
        // NSWindow.subtitle; let it bridge the subtitle from DocumentWindowView instead.
        if #available(macOS 26, *) {
            host.sceneBridgingOptions = [.toolbars]
        } else {
            host.sceneBridgingOptions = [.toolbars, .title]
        }
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1280, height: 820))
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        window.setFrameAutosaveName("HexerDocumentWindow")
        updateSubtitle()
        observeSession()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func windowDidLoad() {
        super.windowDidLoad()
        focusEditor()
    }

    func focusEditor() {
        if let canvas = session.editorView?.canvas { window?.makeFirstResponder(canvas) }
    }

    private func observeSession() {
        withObservationTracking {
            _ = session.length
            _ = session.mode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateSubtitle()
                self?.observeSession()
            }
        }
    }

    private func updateSubtitle() {
        window?.subtitle = session.windowSubtitle
    }

    func windowDidBecomeKey(_ notification: Notification) {
        session.editorView?.canvas.needsDisplay = true
        (document as? HexDocument)?.checkExternalChange()
    }

    func windowWillClose(_ notification: Notification) {
        session.jobs.cancelAll()
        session.compare?.stop()
        session.statisticsWindow?.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        session.editorView?.canvas.needsDisplay = true
    }

    // MARK: View options

    @objc func setBytesPerRow(_ sender: NSMenuItem) {
        if sender.tag == 0 {
            promptBytesPerRow()
        } else {
            session.fitToWidth = false
            session.bytesPerRow = sender.tag
        }
    }

    private func promptBytesPerRow() {
        let alert = NSAlert()
        alert.messageText = L("Bytes per row")
        let field = NSTextField(string: "\(session.bytesPerRow)")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let n = Int(field.stringValue), (1...4096).contains(n) else { return }
            self?.session.fitToWidth = false
            self?.session.bytesPerRow = n
        }
        alert.window.makeFirstResponder(field)
    }

    @objc func toggleFitToWidth(_ sender: Any?) { session.fitToWidth.toggle() }
    @objc func setGroupSize(_ sender: NSMenuItem) { session.groupSize = sender.tag }
    @objc func setOffsetBase(_ sender: NSMenuItem) { session.offsetBase = NumberBase(rawValue: sender.tag) ?? .hexadecimal }
    @objc func setTextEncoding(_ sender: NSMenuItem) { session.encoding = TextEncoding.allCases[sender.tag] }
    @objc func setVisibleColumns(_ sender: NSMenuItem) {
        session.columns = VisibleColumns.allCases[sender.tag]
        if !session.columns.showsHex { session.activeColumn = .text }
        if !session.columns.showsText { session.activeColumn = .hex }
    }
    @objc func toggleLowercaseHex(_ sender: Any?) { session.lowercaseHex.toggle() }
    /// Folding again closes the sections opened one by one.
    @objc func toggleFoldUndefinedSections(_ sender: Any?) {
        session.foldsUndefinedSections.toggle()
        session.unfoldedSections = []
    }
    @objc func filterCharacters(_ sender: Any?) {
        let model = CharacterFilterModel(session.characterFilter)
        session.present { CharacterFilterSheet(model: model, session: session) }
    }
    @objc func toggleInspector(_ sender: Any?) { session.showInspector.toggle() }
    @objc func showDrawerPane(_ sender: NSMenuItem) {
        let pane = DrawerPane.allCases[sender.tag]
        session.drawerPane = session.drawerPane == pane ? nil : pane
    }

    @objc func setEditMode(_ sender: NSMenuItem) {
        let mode = EditMode.allCases[sender.tag]
        if mode != .readOnly && session.buffer.isReadOnly { NSSound.beep(); return }
        session.mode = mode
        session.nibble = 0
        session.editorView?.canvas.needsDisplay = true
    }

    @objc func toggleInsertMode(_ sender: Any?) {
        guard session.mode != .readOnly else { NSSound.beep(); return }
        session.mode = session.mode == .insert ? .overwrite : .insert
        session.editorView?.canvas.needsDisplay = true
    }

    @objc func reloadFromDisk(_ sender: Any?) {
        guard let document = document as? HexDocument else { return }
        if document.isDocumentEdited {
            let alert = NSAlert()
            alert.messageText = L("Reload “%@” from disk?", document.displayName)
            alert.informativeText = L("Reloading discards your unsaved changes.")
            alert.addButton(withTitle: L("Reload"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        document.reloadFromDisk()
    }

    @objc func copyOffset(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.formatOffset(session.caretByte), forType: .string)
    }

    // MARK: Navigation and selection

    @objc func goToOffset(_ sender: Any?) {
        let model = GoToModel(defaultBase: session.offsetBase)
        session.present { GoToSheet(model: model, session: session) }
    }

    @objc func selectBlock(_ sender: Any?) {
        let model = SelectBlockModel(selection: session.selection, base: session.offsetBase)
        session.present { SelectBlockSheet(model: model, session: session) }
    }

    @objc func saveSelectionAs(_ sender: Any?) {
        let range = session.selection.range
        guard !range.isEmpty, let window, let document = document as? HexDocument else { NSSound.beep(); return }
        let panel = NSSavePanel()
        let base = (document.displayName as NSString).deletingPathExtension
        panel.nameFieldStringValue = L("%@ (selection).bin", base)
        panel.directoryURL = document.fileURL?.deletingLastPathComponent()
        let snapshot = session.snapshot()
        panel.beginSheetModal(for: window) { [session] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let done: Void? = try await session.jobs.run(L("Saving selection")) { job in
                        try FileWriter.write(snapshot, range: range, to: url, isCancelled: { job.isCancelled }, progress: job.report)
                    }
                    if done == nil { try? FileManager.default.removeItem(at: url) }
                } catch FileWriter.WriteError.cancelled {
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    document.presentError(error)
                }
            }
        }
    }

    // MARK: Export

    @objc func exportAs(_ sender: NSMenuItem) {
        guard let format = ExportFormat(rawValue: sender.tag) else { return }
        session.export(format)
    }

    @objc func copyAs(_ sender: NSMenuItem) {
        guard let format = ExportFormat(rawValue: sender.tag) else { return }
        session.copyAs(format)
    }

    // MARK: Edit tools

    @objc func insertBytes(_ sender: Any?) {
        let model = InsertBytesModel(base: session.offsetBase)
        session.present { InsertBytesSheet(model: model, session: session) }
    }

    @objc func fillSelection(_ sender: Any?) {
        let model = FillSelectionModel()
        session.present { FillSelectionSheet(model: model, session: session) }
    }

    // MARK: Search

    @objc func showFind(_ sender: Any?) { session.showFind(replace: false) }
    @objc func showReplace(_ sender: Any?) { session.showFind(replace: true) }
    @objc func findNext(_ sender: Any?) { session.findNext() }
    @objc func findPrevious(_ sender: Any?) { session.findNext(backward: true) }
    @objc func useSelectionForFind(_ sender: Any?) { session.useSelectionForFind() }

    // MARK: Analysis

    @objc func showStatistics(_ sender: Any?) {
        StatisticsWindowController.show(for: session)
    }

    @objc func compareDocuments(_ sender: Any?) {
        let model = CompareModel()
        session.present { CompareSheet(model: model, session: session) }
    }

    @objc func nextDifference(_ sender: Any?) { session.compare?.step(from: session, backward: false) }
    @objc func previousDifference(_ sender: Any?) { session.compare?.step(from: session, backward: true) }

    @objc func generateChecksums(_ sender: Any?) {
        let model = ChecksumModel(hasSelection: !session.selection.isEmpty)
        session.present { ChecksumSheet(model: model, session: session) }
    }

    // MARK: Bookmarks

    @objc func setBookmark(_ sender: NSMenuItem) {
        session.bookmarks[sender.tag] = session.caretByte
    }

    @objc func goToBookmark(_ sender: NSMenuItem) {
        guard let offset = session.bookmarks[sender.tag] else { NSSound.beep(); return }
        session.setSelection(Selection(caret: min(offset, session.length)))
        session.editorView?.canvas.needsDisplay = true
    }

    // MARK: Window

    @objc func saveAllDocuments(_ sender: Any?) {
        for case let doc as HexDocument in NSDocumentController.shared.documents where doc.isDocumentEdited {
            doc.save(nil)
        }
    }

    @objc func closeAllDocuments(_ sender: Any?) {
        NSDocumentController.shared.closeAllDocuments(withDelegate: nil, didCloseAllSelector: nil, contextInfo: nil)
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let tabs = window?.tabbedWindows, sender.tag < tabs.count else { return }
        tabs[sender.tag].makeKeyAndOrderFront(nil)
    }

    @objc func tileWindows(_ sender: NSMenuItem) {
        let windows = NSApp.orderedWindows.filter { $0.windowController is HexWindowController && $0.isVisible }
        guard let screen = window?.screen ?? NSScreen.main, !windows.isEmpty else { return }
        let area = screen.visibleFrame
        let vertical = sender.tag == 0
        for (i, w) in windows.enumerated() {
            let n = CGFloat(windows.count)
            let frame = vertical
                ? NSRect(x: area.minX + area.width / n * CGFloat(i), y: area.minY, width: area.width / n, height: area.height)
                : NSRect(x: area.minX, y: area.maxY - area.height / n * CGFloat(i + 1), width: area.width, height: area.height / n)
            if w.tabbedWindows?.count ?? 0 > 1 { w.moveTabToNewWindow(nil) }
            w.setFrame(frame, display: true, animate: true)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setBytesPerRow(_:)):
            item.state = !session.fitToWidth && item.tag == session.bytesPerRow ? .on : .off
        case #selector(toggleFitToWidth(_:)): item.state = session.fitToWidth ? .on : .off
        case #selector(setGroupSize(_:)): item.state = item.tag == session.groupSize ? .on : .off
        case #selector(setOffsetBase(_:)): item.state = item.tag == session.offsetBase.rawValue ? .on : .off
        case #selector(setTextEncoding(_:)): item.state = TextEncoding.allCases[item.tag] == session.encoding ? .on : .off
        case #selector(setVisibleColumns(_:)): item.state = VisibleColumns.allCases[item.tag] == session.columns ? .on : .off
        case #selector(toggleLowercaseHex(_:)): item.state = session.lowercaseHex ? .on : .off
        case #selector(toggleFoldUndefinedSections(_:)): item.state = session.foldsUndefinedSections ? .on : .off
        case #selector(toggleInspector(_:)): item.title = session.showInspector ? L("Hide Inspector") : L("Show Inspector")
        case #selector(showDrawerPane(_:)): item.state = session.drawerPane == DrawerPane.allCases[item.tag] ? .on : .off
        case #selector(setEditMode(_:)):
            item.state = EditMode.allCases[item.tag] == session.mode ? .on : .off
            return EditMode.allCases[item.tag] == .readOnly || !session.buffer.isReadOnly
        case #selector(toggleInsertMode(_:)): return session.mode != .readOnly
        case #selector(goToBookmark(_:)): return session.bookmarks[item.tag] != nil
        case #selector(saveSelectionAs(_:)): return !session.selection.isEmpty
        case #selector(generateChecksums(_:)): return !session.jobs.isBusy
        case #selector(useSelectionForFind(_:)): return !session.selection.isEmpty
        case #selector(copyAs(_:)): return !session.selection.isEmpty
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)): return session.compare != nil
        case #selector(exportAs(_:)): return session.length > 0 && !session.jobs.isBusy
        case #selector(insertBytes(_:)): return session.isEditable && !session.buffer.isFixedSize
        case #selector(fillSelection(_:)): return session.isEditable && !session.selection.isEmpty
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return !session.find.isSearching
        case #selector(reloadFromDisk(_:)): return (document as? HexDocument)?.fileURL != nil
        case #selector(saveAllDocuments(_:)): return NSDocumentController.shared.documents.contains { $0.isDocumentEdited }
        case #selector(selectTabByNumber(_:)): return item.tag < (window?.tabbedWindows?.count ?? 1)
        default: break
        }
        return true
    }
}
