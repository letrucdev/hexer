import HexerCore
import SwiftUI

/// State of the Filter Characters sheet.
@Observable
final class CharacterFilterModel {
    enum Preset: Hashable { case all, ascii, alphanumeric, custom }

    var preset: Preset
    var custom: String

    init(_ filter: CharacterFilter) {
        switch filter {
        case .all: preset = .all
        case .ascii: preset = .ascii
        case .alphanumeric: preset = .alphanumeric
        default: preset = .custom
        }
        custom = filter.isAll ? "20-7E, A0-FF" : filter.text
    }

    var filter: CharacterFilter? {
        switch preset {
        case .all: .all
        case .ascii: .ascii
        case .alphanumeric: .alphanumeric
        case .custom: CharacterFilter(parsing: custom)
        }
    }
}

/// View ▸ Filter Characters: which byte values the text column shows as characters.
struct CharacterFilterSheet: View {
    @Bindable var model: CharacterFilterModel
    let session: EditorSession

    var body: some View {
        SheetScaffold(title: "Filter Characters", canConfirm: model.filter != nil,
                      onCancel: session.closeSheet, onConfirm: apply) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Show as characters", selection: $model.preset) {
                        Text("All characters").tag(CharacterFilterModel.Preset.all)
                        Text("ASCII only (20–7E)").tag(CharacterFilterModel.Preset.ascii)
                        Text("Letters and digits").tag(CharacterFilterModel.Preset.alphanumeric)
                        Text("Custom byte ranges:").tag(CharacterFilterModel.Preset.custom)
                    }
                    .pickerStyle(.radioGroup)
                    TextField("e.g. 20-7E, A0-FF", text: $model.custom)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.preset != .custom)
                        .foregroundStyle(model.preset == .custom && model.filter == nil ? Color.red : Color.primary)
                        .frame(width: 220)
                    Text("Other bytes show as a dot in the text column. Searching and copying are not affected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 220, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                preview
            }
        }
    }

    /// The 256 byte values as the text column would show them.
    private var preview: some View {
        let table = session.encoding.table
        let filter = model.filter ?? .all
        return Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<16, id: \.self) { row in
                GridRow {
                    ForEach(0..<16, id: \.self) { column in
                        let byte = row * 16 + column
                        let shown = filter.allows(UInt8(byte)) && table.isPrintable(UInt8(byte))
                        Text(verbatim: shown ? String(table.display[byte]) : "·")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(shown ? Color.primary : Color.secondary.opacity(0.5))
                            .frame(width: 15, height: 17)
                    }
                }
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .help("Preview in \(session.encoding.displayName)")
    }

    private func apply() {
        guard let filter = model.filter else { return }
        session.characterFilter = filter
        AppSettings.shared.characterFilter = filter
        session.closeSheet()
        session.editorView?.canvas.needsDisplay = true
    }
}
