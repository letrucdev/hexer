import AppKit
import HexerCore
import HexerPlatform

/// A file opened in Hexer. Opening only records the file; bytes are read on demand, so files of
/// any size open instantly.
@objc(HexDocument)
final class HexDocument: NSDocument {
    private(set) var buffer: EditableBuffer
    private(set) var session: EditorSession!
    private(set) var source: FileByteSource?
    /// Registry id of `source`, so saving can tell which bytes are still the file's own.
    private(set) var sourceID: UInt32?

    override init() {
        buffer = EditableBuffer(source: nil)
        super.init()
        hasUndoManager = false
        configureSession()
    }

    /// An untitled document holding imported data (Intel Hex, S-Record, …).
    convenience init(imported buffer: EditableBuffer, name: String) {
        self.init()
        self.buffer = buffer
        configureSession()
        importedName = name
    }

    private var importedName: String?

    /// A raw disk opened with File ▸ Open Disk: what it is and the descriptor it was opened with.
    struct DiskContext {
        let info: DiskInfo
        /// Owned by the document's `DiskByteSource`, which closes it.
        let descriptor: Int32
        let writable: Bool
        let sourceID: UInt32
    }

    private(set) var disk: DiskContext?

    /// A document showing a raw disk. Writing happens through `saveDisk()`, never NSDocument.
    convenience init(disk info: DiskInfo, descriptor: Int32, writable: Bool) throws {
        self.init()
        let source = try DiskByteSource(descriptor: descriptor, path: info.devicePath, sectorSize: info.blockSize)
        buffer = EditableBuffer(source: source)
        buffer.isReadOnly = !writable
        disk = DiskContext(info: info, descriptor: source.descriptor, writable: writable, sourceID: buffer.initialSourceID!)
        configureSession()
        session.sectorSize = source.sectorSize
        importedName = info.volumeName.map { "\(info.bsdName) — \($0)" } ?? info.bsdName
    }

    override var displayName: String! {
        get { fileURL == nil ? importedName ?? super.displayName : super.displayName }
        set { super.displayName = newValue }
    }

    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var autosavesDrafts: Bool { false }
    nonisolated override class var preservesVersions: Bool { false }
    nonisolated override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }
    nonisolated override var isEntireFileLoaded: Bool { false }

    private func configureSession() {
        session = EditorSession(document: self, buffer: buffer)
        buffer.onChange = { [weak self] _ in self?.bufferDidChange() }
    }

    /// Files to open as disk images, with their sector size (File ▸ Open Disk Image).
    static var pendingDiskImages: [URL: Int] = [:]

    /// Reading happens on the main thread (`canConcurrentlyReadDocuments` is false).
    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let sectorSize = MainActor.assumeIsolated { Self.pendingDiskImages.removeValue(forKey: url.standardizedFileURL) }
        // A disk image keeps its size, like the disk it came from.
        let source = try FileByteSource(url: url, fixedSize: sectorSize != nil)
        MainActor.assumeIsolated {
            self.source = source
            buffer = EditableBuffer(source: source)
            sourceID = buffer.initialSourceID
            buffer.isReadOnly = !FileManager.default.isWritableFile(atPath: url.path)
            configureSession()
            session.sectorSize = sectorSize
        }
    }

    override func makeWindowControllers() {
        addWindowController(HexWindowController(document: self))
    }

    private func bufferDidChange() {
        session.bufferDidChange()
        updateChangeCount(buffer.isModified ? .changeDone : .changeCleared)
    }

    /// Imported data exists only in memory until it is saved, so it counts as edited.
    override var isDocumentEdited: Bool { buffer.isModified || (fileURL == nil && importedName != nil && disk == nil) }

    /// Disks are saved in place, sector by sector.
    override func save(_ sender: Any?) {
        if disk != nil { saveDisk() } else { super.save(sender) }
    }

    /// Writes the changed sectors back to the disk after unmounting its volumes. The disk then
    /// holds what the editor shows, so undo history (which may refer to the old sectors) ends.
    func saveDisk() {
        guard let disk, buffer.isModified else { return }
        guard disk.writable else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Write the changes to %@?", disk.info.bsdName)
        alert.informativeText = L("Its volumes are unmounted first. Writing to a disk cannot be undone, and the undo history is cleared afterwards.")
        alert.addDestructiveButton(withTitle: L("Write to Disk"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let snapshot = buffer.snapshot()
        let changed = FileWriter.changedRanges(in: snapshot.tree, base: disk.sourceID)
        let sectorSize = session.sectorSize ?? disk.info.blockSize
        Task {
            do {
                try await DiskArbitrationSession.shared.unmount(bsdName: disk.info.bsdName)
                _ = try await session.jobs.run(L("Writing to disk")) { job in
                    try DiskWriter.write(snapshot, changedRanges: changed, to: disk.descriptor, sectorSize: sectorSize,
                                         baseSourceID: disk.sourceID, isCancelled: { job.isCancelled }, progress: job.report)
                }
                // The source now reads the new sectors; start over from it.
                buffer.cache.removeAll()
                let source = buffer.registry.source(disk.sourceID)!
                try buffer.apply(L("Write to Disk"), tree: PieceTree(pieces: [Piece(.source(disk.sourceID), start: 0, length: source.length)]),
                                 selectionBefore: session.selection, selectionAfter: session.selection)
                buffer.clearHistory()
                buffer.markSaved()
                session.bufferDidChange()
                updateChangeCount(.changeCleared)
            } catch {
                presentError(error)
            }
        }
    }

    // MARK: Saving

    /// Writing happens on the main thread (asynchronous saving is not enabled). When only a few
    /// bytes changed, the original is cloned and patched, so saving a large file is instant.
    nonisolated override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                                    originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        let (snapshot, source, sourceID) = MainActor.assumeIsolated { (buffer.snapshot(), source, sourceID) }
        if let original = absoluteOriginalContentsURL ?? source?.url, let source, let sourceID,
           FileIdentity.of(path: original.path) == source.identity,
           try FileWriter.writePatchingClone(of: original, snapshot: snapshot, base: sourceID, to: url) {
            return
        }
        try FileWriter.write(snapshot, to: url)
    }

    nonisolated override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        let makeBackups = MainActor.assumeIsolated { AppSettings.shared.makeBackups }
        if saveOperation == .saveOperation, makeBackups, let current = fileURL,
           FileManager.default.fileExists(atPath: current.path) {
            let backup = current.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            // A clone on APFS: instant and takes no space until the original changes.
            if copyfile(current.path, backup.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) != 0 {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: backup.path])
            }
        }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, let self, saveOperation == .saveOperation || saveOperation == .saveAsOperation {
                self.didSave(to: url)
            }
            completionHandler(error)
        }
    }

    /// After saving, the document refers to the new file. The previous file's descriptor stays
    /// open, so undo history that still refers to its bytes keeps working.
    private func didSave(to url: URL) {
        guard let newSource = try? FileByteSource(url: url) else { return }
        source = newSource
        let id = buffer.registry.register(newSource)
        sourceID = id
        let tree = newSource.length > 0 ? PieceTree(pieces: [Piece(.source(id), start: 0, length: newSource.length)]) : PieceTree()
        buffer.markSaved(replacingTreeWith: tree.length == buffer.length ? tree : nil)
        buffer.isReadOnly = false
        session.bufferDidChange()
    }

    // MARK: External changes

    nonisolated override func presentedItemDidChange() {
        super.presentedItemDidChange()
        Task { @MainActor in self.checkExternalChange() }
    }

    private var isShowingReloadPrompt = false

    func checkExternalChange() {
        guard let source, let url = fileURL, !isShowingReloadPrompt,
              let identity = FileIdentity.of(path: url.path), identity != source.identity else { return }
        isShowingReloadPrompt = true
        defer { isShowingReloadPrompt = false }
        let alert = NSAlert()
        alert.messageText = L("“%@” was changed by another application.", displayName)
        alert.informativeText = buffer.isModified
            ? L("Reloading discards your unsaved changes.")
            : L("Reload it to see the current contents.")
        alert.addButton(withTitle: L("Reload"))
        alert.addButton(withTitle: L("Keep Current Version"))
        if alert.runModal() == .alertFirstButtonReturn { reloadFromDisk() }
    }

    func reloadFromDisk() {
        guard let url = fileURL else { return }
        do {
            let newSource = try FileByteSource(url: url)
            source = newSource
            buffer.cache.removeAll()
            let id = buffer.registry.register(newSource)
            sourceID = id
            let tree = newSource.length > 0 ? PieceTree(pieces: [Piece(.source(id), start: 0, length: newSource.length)]) : PieceTree()
            try buffer.apply(L("Reload"), tree: tree, selectionBefore: session.selection, selectionAfter: session.selection.clamped(to: tree.length))
            buffer.clearHistory()
            buffer.markSaved()
            session.bufferDidChange()
            updateChangeCount(.changeCleared)
        } catch {
            presentError(error)
        }
    }

    // MARK: Messages

    func showMessage(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        if let window = windowControllers.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
