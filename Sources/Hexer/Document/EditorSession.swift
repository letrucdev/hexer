import AppKit
import HexerCore
import Observation
import SwiftUI

enum ActiveColumn { case hex, text }

/// Panes of the results drawer below the grid.
enum DrawerPane: String, CaseIterable, Identifiable {
    case searchResults, checksums, compare
    var id: String { rawValue }

    var title: String {
        switch self {
        case .searchResults: L("Search Results")
        case .checksums: L("Checksums")
        case .compare: L("Compare")
        }
    }
}

/// The editing state of one document window: selection, mode, view options and panels.
@Observable
final class EditorSession {
    @ObservationIgnored weak var document: HexDocument?
    @ObservationIgnored let buffer: EditableBuffer
    @ObservationIgnored weak var editorView: HexEditorView?

    /// Increments on every change of the bytes, so views that show them refresh.
    private(set) var revision = 0
    var selection = Selection(caret: 0)
    /// Which digit of the caret byte the next hex keystroke changes (0 = high nibble).
    var nibble = 0
    var activeColumn: ActiveColumn = .hex
    var mode: EditMode

    var bytesPerRow: Int
    var fitToWidth: Bool
    /// Bytes per row actually shown (differs from `bytesPerRow` when fitting to the width).
    var effectiveBytesPerRow: Int
    var groupSize: Int
    var encoding: TextEncoding
    var offsetBase: NumberBase
    var lowercaseHex: Bool
    var columns: VisibleColumns
    var characterFilter: CharacterFilter
    /// Whole rows inside undefined sections collapse into one row (View ▸ Fold Undefined Sections).
    var foldsUndefinedSections = true
    /// Undefined sections opened from their fold row, by first byte.
    var unfoldedSections: Set<UInt64> = []

    var showInspector = true
    var columnVisibility = NavigationSplitViewVisibility.all
    /// View state of the data inspector (SwiftUI's @State is unavailable without Xcode's macro plugin).
    let inspector = InspectorModel()
    var drawerPane: DrawerPane?
    var bookmarks: [Int: UInt64] = [:]
    let find = FindModel()
    /// Find All results, sorted and non-overlapping.
    var searchHits: [SearchHit] = []
    var searchHitsTruncated = false
    var searchResultSelection: SearchHit.ID?
    var checksumResults: [ChecksumEntry] = []
    var checksumSelection: Set<ChecksumEntry.ID> = []
    /// Checksum typed by the user to compare results against ("" = none).
    var expectedChecksum = ""
    @ObservationIgnored var statisticsWindow: NSWindowController?
    /// Set while this window is compared with another one.
    var compare: CompareSession?
    /// Set for disks and disk images: the sector navigator shows and offsets map to sectors.
    var sectorSize: Int?
    let sectorInput = SectorInput()
    var compareSelection: UInt64?
    /// The sheet shown over the window (Go To, Fill Selection, …).
    var sheet: SheetRequest?
    let jobs = JobCenter()
    /// The user agreed to edits that change the file size (asked once per document).
    @ObservationIgnored var sizeChangeConfirmed = false

    init(document: HexDocument, buffer: EditableBuffer) {
        self.document = document
        self.buffer = buffer
        let s = AppSettings.shared
        mode = buffer.isReadOnly ? .readOnly : s.defaultMode
        bytesPerRow = s.bytesPerRow
        effectiveBytesPerRow = s.bytesPerRow
        fitToWidth = s.fitToWidth
        groupSize = s.groupSize
        encoding = s.encoding
        offsetBase = s.offsetBase
        lowercaseHex = s.lowercaseHex
        columns = s.columns
        characterFilter = s.characterFilter
    }

    var length: UInt64 {
        _ = revision
        return buffer.length
    }

    var isDirty: Bool { _ = revision; return buffer.isModified }
    var canUndo: Bool { _ = revision; return buffer.canUndo }
    var canRedo: Bool { _ = revision; return buffer.canRedo }

    func snapshot() -> ByteSnapshot {
        _ = revision
        return buffer.snapshot()
    }

    /// Called by the document when the buffer changed.
    func bufferDidChange() {
        revision &+= 1
        selection = selection.clamped(to: buffer.length)
    }

    /// Undefined sections (gaps between imported records), in order.
    func undefinedSections(limit: Int = .max) -> [Range<UInt64>] {
        _ = revision
        var out: [Range<UInt64>] = []
        buffer.tree.forEachRun(of: .undefined) { if out.count < limit { out.append($0) } }
        return out
    }

    /// The window subtitle: size and mode ("9.6 MB · Overwrite").
    var windowSubtitle: String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: length), countStyle: .file)) · \(mode.title)"
    }

    /// The offset whose byte the caret is on (the start of the selection when there is one).
    var caretByte: UInt64 { selection.isEmpty ? selection.caret : selection.range.lowerBound }

    func setSelection(_ s: Selection, nibble: Int = 0, scroll: Bool = true) {
        if s != selection { buffer.breakCoalescing() }
        selection = s.clamped(to: buffer.length)
        self.nibble = nibble
        if scroll { editorView?.scrollToVisible(offset: selection.caret) }
        if NSWorkspace.shared.isVoiceOverEnabled { editorView?.canvas.announceCaretChange() }
    }

    func present(@ViewBuilder _ content: () -> some View) {
        sheet = SheetRequest(content)
    }

    func closeSheet() {
        sheet = nil
        if let canvas = editorView?.canvas { canvas.window?.makeFirstResponder(canvas) }
    }

    func formatOffset(_ value: UInt64, minDigits: Int = 1) -> String {
        offsetBase.format(value, minDigits: minDigits, uppercase: !lowercaseHex)
    }
}
