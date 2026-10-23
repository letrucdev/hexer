import AppKit
import HexerCore

/// One pass of Fill Selection: repeated hex values or random bytes in a range.
struct FillPass: Identifiable, Hashable {
    enum Kind: Hashable { case hex, random }

    let id = UUID()
    var kind: Kind = .hex
    var hex = "00"
    var randomMin = 0
    var randomMax = 255

    /// The generator for this pass, or nil while the hex values are invalid.
    func generator(seed: UInt64) -> Generator? {
        switch kind {
        case .hex:
            guard let bytes = EditorSession.parseHex(hex), !bytes.isEmpty else { return nil }
            return .pattern(bytes)
        case .random:
            let lo = UInt8(clamping: min(randomMin, randomMax)), hi = UInt8(clamping: max(randomMin, randomMax))
            return .random(seed: seed, min: lo, max: hi)
        }
    }

    var summary: String {
        switch kind {
        case .hex: L("Hex values: %@", hex)
        case .random: L("Random bytes: %lld – %lld", randomMin, randomMax)
        }
    }

    /// HxD's DoD sanitizing preset: zeros, ones, then random data.
    static var dodPreset: [FillPass] {
        [FillPass(kind: .hex, hex: "00"), FillPass(kind: .hex, hex: "FF"), FillPass(kind: .random)]
    }
}

extension EditorSession {
    /// Inserts `count` bytes of a repeated pattern at the caret, as one undoable step that
    /// needs no memory however large `count` is.
    func insertBytes(count: UInt64, pattern: [UInt8]) {
        guard isEditable, count > 0, !pattern.isEmpty else { NSSound.beep(); return }
        guard confirmSizeChange() else { return }
        let before = selection
        let at = caretByte
        do {
            try buffer.apply(L("Insert Bytes"), replacing: at..<at, with: buffer.generatedPieces(.pattern(pattern), count: count),
                             selectionBefore: before, selectionAfter: Selection(anchor: at, caret: at + count))
            selection = Selection(anchor: at, caret: at + count)
            editorView?.scrollToVisible(offset: at)
        } catch {
            NSSound.beep()
        }
    }

    /// Fills the selection with the last pass (earlier passes only matter when writing
    /// directly, where each pass reaches the disk).
    func fillSelection(passes: [FillPass]) {
        let range = selection.range
        guard isEditable, !range.isEmpty, let last = passes.last,
              let generator = last.generator(seed: UInt64.random(in: 0...UInt64.max)) else { NSSound.beep(); return }
        let before = selection
        do {
            try buffer.apply(L("Fill Selection"), replacing: range,
                             with: buffer.generatedPieces(generator, count: range.upperBound - range.lowerBound),
                             selectionBefore: before, selectionAfter: before)
        } catch {
            NSSound.beep()
        }
    }

    /// Writes every pass straight into the file (HxD's "direct writing"), flushing each one to
    /// the storage device, then reloads the file. This cannot be undone.
    func fillSelectionDirectly(passes: [FillPass]) {
        guard let document, let url = document.fileURL, !buffer.isModified else {
            document?.showMessage(L("Save your changes first."),
                                  info: L("Writing directly changes the file on disk, so it must match what Hexer shows."))
            return
        }
        let range = selection.range
        let generators = passes.compactMap { $0.generator(seed: UInt64.random(in: 0...UInt64.max)) }
        guard !range.isEmpty, generators.count == passes.count else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Overwrite %@ bytes of “%@” directly?", (range.upperBound - range.lowerBound).formatted(), document.displayName)
        alert.informativeText = L("Each pass is written to the disk immediately. This cannot be undone.")
        alert.addDestructiveButton(withTitle: L("Write Directly"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                _ = try await jobs.run(L("Writing directly")) { job in
                    let fd = open(url.path, O_WRONLY | O_CLOEXEC)
                    guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
                    defer { close(fd) }
                    try FileTools.overwrite(fd: fd, path: url.path, range: range, passes: generators,
                                            isCancelled: { job.isCancelled }, progress: job.report)
                }
                document.reloadFromDisk()
            } catch {
                document.presentError(error)
                document.reloadFromDisk()
            }
        }
    }
}
