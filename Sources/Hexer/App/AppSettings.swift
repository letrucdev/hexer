import AppKit
import HexerCore
import Observation

/// Edit modes shown in the toolbar and status bar.
enum EditMode: String, CaseIterable, Codable {
    case insert, overwrite, readOnly

    var title: String {
        switch self {
        case .insert: L("Insert")
        case .overwrite: L("Overwrite")
        case .readOnly: L("Read-only")
        }
    }
}

/// App-wide defaults (Settings window). Each document window starts from these and the View
/// menu then changes only that window.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var bytesPerRow: Int { didSet { defaults.set(bytesPerRow, forKey: "BytesPerRow") } }
    var fitToWidth: Bool { didSet { defaults.set(fitToWidth, forKey: "FitRows") } }
    var groupSize: Int { didSet { defaults.set(groupSize, forKey: "ByteGroupSize") } }
    var encoding: TextEncoding { didSet { defaults.set(encoding.rawValue, forKey: "Charset") } }
    var offsetBase: NumberBase { didSet { defaults.set(offsetBase.rawValue, forKey: "OffsetBase") } }
    var lowercaseHex: Bool { didSet { defaults.set(lowercaseHex, forKey: "LowerCaseHexLetters") } }
    var columns: VisibleColumns { didSet { defaults.set(columns.rawValue, forKey: "VisibleColumns") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "FontSize") } }
    var fontName: String { didSet { defaults.set(fontName, forKey: "FontName") } }
    var makeBackups: Bool { didSet { defaults.set(makeBackups, forKey: "MakeBackupFiles") } }
    var confirmSizeChange: Bool { didSet { defaults.set(confirmSizeChange, forKey: "AllowStreamResizeQuestion") } }
    var diskReadOnlyByDefault: Bool { didSet { defaults.set(diskReadOnlyByDefault, forKey: "DiskReadOnlyByDefault") } }
    var warnDiskWriteAccess: Bool { didSet { defaults.set(warnDiskWriteAccess, forKey: "DiskWriteAccessWarning") } }
    var warnFilteredClipboard: Bool { didSet { defaults.set(warnFilteredClipboard, forKey: "WarnAboutFilteredCopiedText") } }
    var warnFilteredSelection: Bool { didSet { defaults.set(warnFilteredSelection, forKey: "WarnAboutFilteredSelText") } }
    var defaultMode: EditMode { didSet { defaults.set(defaultMode.rawValue, forKey: "DefaultEditMode") } }
    var characterFilter: CharacterFilter {
        didSet { defaults.set(try? JSONEncoder().encode(characterFilter), forKey: "CharacterFilter") }
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "BytesPerRow": 16, "FitRows": false, "ByteGroupSize": 1, "Charset": TextEncoding.windowsLatin1.rawValue,
            "OffsetBase": NumberBase.hexadecimal.rawValue, "LowerCaseHexLetters": false,
            "VisibleColumns": VisibleColumns.hexAndText.rawValue, "FontSize": 13.0, "FontName": "",
            "MakeBackupFiles": false, "AllowStreamResizeQuestion": true, "DiskReadOnlyByDefault": true,
            "DiskWriteAccessWarning": true, "WarnAboutFilteredCopiedText": true, "WarnAboutFilteredSelText": false,
            "DefaultEditMode": EditMode.overwrite.rawValue,
        ])
        bytesPerRow = d.integer(forKey: "BytesPerRow")
        fitToWidth = d.bool(forKey: "FitRows")
        groupSize = d.integer(forKey: "ByteGroupSize")
        encoding = TextEncoding(rawValue: d.string(forKey: "Charset") ?? "") ?? .windowsLatin1
        offsetBase = NumberBase(rawValue: d.integer(forKey: "OffsetBase")) ?? .hexadecimal
        lowercaseHex = d.bool(forKey: "LowerCaseHexLetters")
        columns = VisibleColumns(rawValue: d.string(forKey: "VisibleColumns") ?? "") ?? .hexAndText
        fontSize = d.double(forKey: "FontSize")
        fontName = d.string(forKey: "FontName") ?? ""
        makeBackups = d.bool(forKey: "MakeBackupFiles")
        confirmSizeChange = d.bool(forKey: "AllowStreamResizeQuestion")
        diskReadOnlyByDefault = d.bool(forKey: "DiskReadOnlyByDefault")
        warnDiskWriteAccess = d.bool(forKey: "DiskWriteAccessWarning")
        warnFilteredClipboard = d.bool(forKey: "WarnAboutFilteredCopiedText")
        warnFilteredSelection = d.bool(forKey: "WarnAboutFilteredSelText")
        defaultMode = EditMode(rawValue: d.string(forKey: "DefaultEditMode") ?? "") ?? .overwrite
        characterFilter = d.data(forKey: "CharacterFilter").flatMap { try? JSONDecoder().decode(CharacterFilter.self, from: $0) } ?? .all
    }

    /// The editor font: the chosen one, else SF Mono.
    var font: NSFont {
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: fontSize) { return f }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}
