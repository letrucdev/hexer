import HexerCore
import SwiftUI

/// State of the Insert Bytes sheet.
@Observable
final class InsertBytesModel {
    let count: NumberInput
    var pattern = "00"

    init(base: NumberBase) {
        count = NumberInput(16, base: base)
    }

    var bytes: [UInt8]? { EditorSession.parseHex(pattern) }
}

/// HxD's "Insert bytes": a byte count and a repeated fill pattern, inserted at the caret.
struct InsertBytesSheet: View {
    @Bindable var model: InsertBytesModel
    let session: EditorSession

    var body: some View {
        let count = model.count.value ?? 0
        let valid = count > 0 && model.bytes?.isEmpty == false
        SheetScaffold(title: "Insert Bytes", confirmTitle: "Insert", canConfirm: valid && session.isEditable,
                      onCancel: session.closeSheet, onConfirm: insert) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Byte count:").gridColumnAlignment(.trailing)
                    HStack {
                        NumberField(title: "Byte count", input: model.count)
                        NumberBasePicker(base: Bindable(model.count).base)
                    }
                }
                GridRow {
                    Text("Fill pattern:")
                    TextField("Hex values", text: $model.pattern)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(model.bytes == nil ? Color.red : Color.primary)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(verbatim: valid
                         ? L("Hex values, repeated to fill. Inserts %@ bytes at offset %@ — the file grows to %@ bytes.",
                             count.formatted(), session.formatOffset(session.caretByte), (session.length + count).formatted())
                         : L("Enter a byte count and at least one hex value."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 340, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func insert() {
        guard let count = model.count.value, let bytes = model.bytes else { return }
        session.closeSheet()
        session.insertBytes(count: count, pattern: bytes)
        session.editorView?.canvas.needsDisplay = true
    }
}

/// State of the Fill Selection sheet.
@Observable
final class FillSelectionModel {
    var passes: [FillPass] = [FillPass()]
    var selected: FillPass.ID?
    var writeDirectly = false

    init() { selected = passes.first?.id }

    var current: FillPass? {
        get { passes.first { $0.id == selected } }
        set {
            guard let newValue, let i = passes.firstIndex(where: { $0.id == newValue.id }) else { return }
            passes[i] = newValue
        }
    }

    var isValid: Bool { !passes.isEmpty && passes.allSatisfy { $0.generator(seed: 0) != nil } }

    func add() {
        let pass = FillPass()
        passes.append(pass)
        selected = pass.id
    }

    func remove() {
        guard passes.count > 1, let id = selected, let i = passes.firstIndex(where: { $0.id == id }) else { return }
        passes.remove(at: i)
        selected = passes[min(i, passes.count - 1)].id
    }

    func preset(_ passes: [FillPass]) {
        self.passes = passes
        selected = passes.first?.id
    }
}

/// HxD's "Fill selection": one or more passes of hex values or random bytes, with presets for
/// secure deletion and an option to write each pass straight to the disk.
struct FillSelectionSheet: View {
    @Bindable var model: FillSelectionModel
    let session: EditorSession

    var body: some View {
        SheetScaffold(title: "Fill Selection", confirmTitle: "Fill", canConfirm: model.isValid && session.isEditable,
                      onCancel: session.closeSheet, onConfirm: fill) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Passes").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    List(selection: $model.selected) {
                        ForEach(Array(model.passes.enumerated()), id: \.element.id) { index, pass in
                            HStack {
                                Text(verbatim: "\(index + 1)").foregroundStyle(.secondary).monospacedDigit()
                                Text(verbatim: pass.summary).lineLimit(1)
                            }
                            .tag(pass.id)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(width: 220, height: 150)
                    HStack {
                        Button("Add", action: model.add)
                        Button("Remove", action: model.remove).disabled(model.passes.count < 2)
                    }
                    .controlSize(.small)
                    Text("Presets").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 6)
                    HStack {
                        Button("DoD Sanitizing") { model.preset(FillPass.dodPreset) }
                        Button("Zero Bytes") { model.preset([FillPass(kind: .hex, hex: "00")]) }
                    }
                    .controlSize(.small)
                }
                passEditor
                    .frame(width: 260, alignment: .topLeading)
            }
            Toggle("Write directly to disk (cannot be undone)", isOn: $model.writeDirectly)
            Text(verbatim: model.writeDirectly
                 ? L("Every pass is written to the file and flushed before the next one; undo history is cleared.")
                 : L("Only the last pass is kept, as one undoable change. Earlier passes matter only when writing directly."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 500, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var passEditor: some View {
        if let index = model.passes.firstIndex(where: { $0.id == model.selected }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Pattern of pass %lld", index + 1)).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Picker("Pattern", selection: $model.passes[index].kind) {
                    Text("Hex values").tag(FillPass.Kind.hex)
                    Text("Random bytes").tag(FillPass.Kind.random)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if model.passes[index].kind == .hex {
                    TextField("Hex values", text: $model.passes[index].hex)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(model.passes[index].generator(seed: 0) == nil ? Color.red : Color.primary)
                } else {
                    HStack {
                        Text("From")
                        TextField("From", value: $model.passes[index].randomMin, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                        Text("to")
                        TextField("To", value: $model.passes[index].randomMax, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                        Text("(decimal)").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func fill() {
        let passes = model.passes
        session.closeSheet()
        if model.writeDirectly {
            session.fillSelectionDirectly(passes: passes)
        } else {
            session.fillSelection(passes: passes)
        }
        session.editorView?.canvas.needsDisplay = true
    }
}
