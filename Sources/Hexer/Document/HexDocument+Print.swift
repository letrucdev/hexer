import AppKit
import HexerCore

extension HexDocument {
    /// The most data File ▸ Print renders: a hex dump of 16-byte rows fills about 900 pages
    /// per MiB, so 256 KiB is already over 200 pages.
    static let maxPrintBytes: UInt64 = 256 << 10

    /// Prints the selection (or the whole document) as the editor shows it: offsets, hex and
    /// text, with as many bytes per row as fit the paper.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let range = session.selection.isEmpty ? 0..<session.length : session.selection.range
        guard range.upperBound - range.lowerBound <= Self.maxPrintBytes else {
            throw NSError(domain: "com.nongdandev.hexer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("The data is too large to print."),
                NSLocalizedRecoverySuggestionErrorKey: L("Select at most %@ to print, or use File ▸ Export ▸ Editor View.",
                                                         ByteCountFormatter.string(fromByteCount: Int64(Self.maxPrintBytes), countStyle: .file)),
            ])
        }
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic

        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        var layout = session.exportLayout
        layout.lineBreak = "\n"
        // Shrink the row until offset, hex and text columns fit the printable width.
        let columns = Int(info.imageablePageBounds.width / charWidth)
        while layout.bytesPerRow > 1 && Self.printedRowWidth(layout) > columns { layout.bytesPerRow /= 2 }

        let snapshot = session.snapshot()
        let text = try ExportText.collect { sink in
            try FormattedExporter.export(snapshot, range: range, format: .editorView, layout: layout, to: sink)
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: info.imageablePageBounds.width, height: 100))
        view.font = font
        view.string = text
        view.isEditable = false
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = displayName
        return operation
    }

    /// Characters in one printed row: offset, gap, hex groups, gap, text.
    private static func printedRowWidth(_ layout: ExportLayout) -> Int {
        let hex = layout.bytesPerRow * 3 + layout.bytesPerRow / max(layout.groupSize, 1)
        return layout.offsetDigits + 2 + (layout.columns.showsHex ? hex : 0) + (layout.columns.showsText ? layout.bytesPerRow + 2 : 0)
    }
}
