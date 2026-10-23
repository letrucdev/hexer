import AppKit
import HexerCore
import UniformTypeIdentifiers

/// The formats of File ▸ Export and Edit ▸ Copy As; raw values are the menu item tags.
enum ExportFormat: Int, CaseIterable {
    case raw = 1, hexValues = 2, decodedText = 3
    case pascal = 10, c = 11, csharp = 12, java = 13, vbnet = 14, purebasic = 15
    case editorView = 20, html = 21, rtf = 22, tex = 23
    case s19 = 30, s28 = 31, s37 = 32, intelHex16 = 33, intelHex20 = 34, intelHex32 = 35

    var title: String {
        switch self {
        case .raw: L("Raw Data")
        case .hexValues: L("Hexadecimal Values")
        case .decodedText: L("Decoded Text")
        case .pascal, .c, .csharp, .java, .vbnet, .purebasic: language!.displayName
        case .editorView, .html, .rtf, .tex: L(formatted!.displayName)
        case .s19: "Motorola S19"
        case .s28: "Motorola S28"
        case .s37: "Motorola S37"
        case .intelHex16: L("Intel Hex (16-bit)")
        case .intelHex20: L("Intel Hex (20-bit)")
        case .intelHex32: L("Intel Hex (32-bit)")
        }
    }

    nonisolated var language: SourceLanguage? {
        switch self {
        case .pascal: .pascal
        case .c: .c
        case .csharp: .cSharp
        case .java: .java
        case .vbnet: .visualBasic
        case .purebasic: .pureBasic
        default: nil
        }
    }

    nonisolated var formatted: FormattedFormat? {
        switch self {
        case .editorView: .editorView
        case .html: .html
        case .rtf: .rtf
        case .tex: .tex
        default: nil
        }
    }

    var fileExtension: String {
        switch self {
        case .raw: "bin"
        case .hexValues, .decodedText: "txt"
        case .s19: "s19"
        case .s28: "s28"
        case .s37: "s37"
        case .intelHex16, .intelHex20, .intelHex32: "hex"
        default: language?.fileExtension ?? formatted?.fileExtension ?? "txt"
        }
    }

    /// HxD refuses these when the data contains undefined bytes.
    var needsDefinedData: Bool { language != nil || formatted != nil }

    /// Writes `range` of `snapshot` as this format to `sink`, in chunks.
    nonisolated func export(_ snapshot: ByteSnapshot, range: Range<UInt64>, layout: ExportLayout, options: ExportOptions,
                            sourceName: String, isCancelled: () -> Bool, progress: (Double) -> Void,
                            to sink: (String) throws -> Void) throws {
        switch self {
        case .raw:
            preconditionFailure("Raw data is written as bytes")
        case .hexValues:
            try PlainExporter.exportHexValues(snapshot, range: range, options: HexValuesOptions(uppercase: layout.uppercase),
                                              isCancelled: isCancelled, progress: progress, to: sink)
        case .decodedText:
            try PlainExporter.exportDecodedText(snapshot, range: range, encoding: layout.encoding,
                                                isCancelled: isCancelled, progress: progress, to: sink)
        case .pascal, .c, .csharp, .java, .vbnet, .purebasic:
            let source = SourceCodeOptions(lineWrap: options.sourceWrap, sourceName: sourceName,
                                           timestamp: Date().formatted(date: .numeric, time: .standard))
            try SourceCodeExporter.export(snapshot, range: range, language: language!, options: source,
                                          isCancelled: isCancelled, progress: progress, to: sink)
        case .editorView, .html, .rtf, .tex:
            try FormattedExporter.export(snapshot, range: range, format: formatted!, layout: layout, title: sourceName,
                                         isCancelled: isCancelled, progress: progress, to: sink)
        case .s19, .s28, .s37:
            let variant: SRecordVariant = self == .s19 ? .s19 : self == .s28 ? .s28 : .s37
            try RecordExporter.exportSRecord(snapshot, range: range, variant: variant,
                                             options: RecordExportOptions(bytesPerLine: options.srecordBytesPerLine),
                                             isCancelled: isCancelled, progress: progress, to: sink)
        case .intelHex16, .intelHex20, .intelHex32:
            let variant: IntelHexVariant = self == .intelHex16 ? .bits16 : self == .intelHex20 ? .bits20 : .bits32
            try RecordExporter.exportIntelHex(snapshot, range: range, variant: variant,
                                              options: RecordExportOptions(bytesPerLine: options.intelHexBytesPerLine),
                                              isCancelled: isCancelled, progress: progress, to: sink)
        }
    }
}

extension EditorSession {
    /// The layout of the window, for Editor view, HTML, RTF and TeX output.
    var exportLayout: ExportLayout {
        ExportLayout(bytesPerRow: effectiveBytesPerRow, groupSize: groupSize, columns: columns, offsetBase: offsetBase,
                     offsetDigits: offsetBase.digits(forLength: length), encoding: encoding, uppercase: !lowercaseHex)
    }

    private func refuseUndefined(_ format: ExportFormat, _ range: Range<UInt64>) -> Bool {
        guard format.needsDefinedData, ExportText.containsUndefined(snapshot(), in: range) else { return false }
        document?.showMessage(L(ExportText.undefinedDataMessage), info: "")
        return true
    }

    /// File ▸ Export: the selection, or everything when nothing is selected.
    func export(_ format: ExportFormat) {
        guard let window = editorView?.window, let document else { return }
        let range = selection.isEmpty ? 0..<length : selection.range
        guard !range.isEmpty, !refuseUndefined(format, range) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        let base = (document.displayName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.directoryURL = document.fileURL?.deletingLastPathComponent()
        panel.message = selection.isEmpty ? L("Exports the whole file as %@.", format.title)
                                          : L("Exports the selected %@ bytes as %@.", (range.upperBound - range.lowerBound).formatted(), format.title)
        let snapshot = snapshot()
        let layout = exportLayout
        let options = ExportOptions.current
        let name: String = document.displayName ?? ""
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let done: Void? = try await self.jobs.run(L("Exporting")) { job in
                        if format == .raw {
                            try FileWriter.write(snapshot, range: range, to: url, isCancelled: { job.isCancelled }, progress: job.report)
                        } else {
                            try Self.writeText(to: url, encoding: format == .tex ? .windowsCP1252 : .utf8) { sink in
                                try format.export(snapshot, range: range, layout: layout, options: options, sourceName: name,
                                                  isCancelled: { job.isCancelled }, progress: job.report, to: sink)
                            }
                        }
                    }
                    if done == nil { try? FileManager.default.removeItem(at: url) }
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: url)
                } catch FileWriter.WriteError.cancelled {
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    document.presentError(error)
                }
            }
        }
    }

    /// Streams text into a new file at `url`.
    nonisolated static func writeText(to url: URL, encoding: String.Encoding,
                                      _ produce: ((String) throws -> Void) throws -> Void) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try produce { chunk in
            guard let data = chunk.data(using: encoding, allowLossyConversion: true) else { return }
            try handle.write(contentsOf: data)
        }
    }

    static let maxCopyAsBytes: UInt64 = 16 << 20

    /// Edit ▸ Copy As: the selection as text in `format`, with RTF and HTML flavors where they apply.
    func copyAs(_ format: ExportFormat) {
        let range = selection.range
        guard !range.isEmpty, !refuseUndefined(format, range) else { NSSound.beep(); return }
        guard range.upperBound - range.lowerBound <= Self.maxCopyAsBytes else {
            document?.showMessage(L("The selection is too large to copy as text."),
                                  info: L("Use File ▸ Export to write it to a file instead."))
            return
        }
        let snapshot = snapshot()
        let layout = exportLayout
        let options = ExportOptions.current
        let name = document?.displayName ?? ""
        do {
            let text = try ExportText.collect { sink in
                try format.export(snapshot, range: range, layout: layout, options: options, sourceName: name,
                                  isCancelled: { false }, progress: { _ in }, to: sink)
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            switch format {
            case .rtf:
                pasteboard.setData(Data(text.utf8), forType: .rtf)
                pasteboard.setString(text, forType: .string)
            case .html:
                pasteboard.setString(text, forType: .html)
                let plain = try ExportText.collect { sink in
                    try ExportFormat.editorView.export(snapshot, range: range, layout: layout, options: options, sourceName: name,
                                                       isCancelled: { false }, progress: { _ in }, to: sink)
                }
                pasteboard.setString(plain, forType: .string)
            default:
                pasteboard.setString(text, forType: .string)
            }
        } catch {
            document?.presentError(error)
        }
    }
}

/// File ▸ Import: Intel Hex, Motorola S-Record and ETL Extended files open as new documents,
/// with gaps between records as undefined sections.
enum RecordImport {
    static func run(_ format: HexRecordFormat) {
        let panel = NSOpenPanel()
        panel.message = L("Choose a %@ file to import.", format.displayName)
        panel.allowedContentTypes = format.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try RecordImporter.importRecords(try Data(contentsOf: url), format: format, fileName: url.lastPathComponent)
                }.value
                let document = HexDocument(imported: image.makeBuffer(), name: url.deletingPathExtension().lastPathComponent)
                NSDocumentController.shared.addDocument(document)
                document.makeWindowControllers()
                document.showWindows()
            } catch {
                NSApp.presentError(error)
            }
        }
    }
}
