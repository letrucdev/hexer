import HexerCore
import SwiftUI

/// State of the Go To sheet; the base and origin are remembered between uses, like HxD.
@Observable
final class GoToModel {
    enum Origin: Int, CaseIterable {
        case begin, current, end

        var title: LocalizedStringKey {
            switch self {
            case .begin: "Beginning of the file"
            case .current: "Current offset (+ or −)"
            case .end: "End of the file (backwards)"
            }
        }
    }

    let offset: NumberInput
    var origin: Origin { didSet { UserDefaults.standard.set(origin.rawValue, forKey: "GoToOrigin") } }

    init(defaultBase: NumberBase) {
        let d = UserDefaults.standard
        let base = (d.object(forKey: "GoToBase") as? Int).flatMap(NumberBase.init(rawValue:)) ?? defaultBase
        offset = NumberInput(base: base)
        offset.text = ""
        origin = Origin(rawValue: d.integer(forKey: "GoToOrigin")) ?? .begin
    }

    /// The offset to jump to, or nil while the input is not a number.
    func target(caret: UInt64, length: UInt64) -> UInt64? {
        var text = offset.text.trimmingCharacters(in: .whitespaces)
        var negative = false
        if origin == .current, let sign = text.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            text.removeFirst()
        }
        guard let value = offset.base.parse(text) else { return nil }
        switch origin {
        case .begin: return min(value, length)
        case .current: return negative ? caret - min(value, caret) : min(caret &+ value, length)
        case .end: return length - min(value, length)
        }
    }

    func remember() { UserDefaults.standard.set(offset.base.rawValue, forKey: "GoToBase") }
}

/// HxD's "Go to" dialog: an offset relative to the start, the caret or the end.
struct GoToSheet: View {
    @Bindable var model: GoToModel
    let session: EditorSession

    var body: some View {
        let target = model.target(caret: session.caretByte, length: session.length)
        SheetScaffold(title: "Go to Offset", confirmTitle: "Go", canConfirm: target != nil,
                      onCancel: session.closeSheet, onConfirm: go) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Offset:").gridColumnAlignment(.trailing)
                    HStack {
                        NumberField(title: "Offset", input: model.offset, allowsSign: model.origin == .current)
                        NumberBasePicker(base: Bindable(model.offset).base)
                    }
                }
                GridRow(alignment: .top) {
                    Text("Relative to:")
                    Picker("Relative to", selection: $model.origin) {
                        ForEach(GoToModel.Origin.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(verbatim: target.map { L("Destination: %@", session.formatOffset($0)) } ?? " ")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func go() {
        guard let target = model.target(caret: session.caretByte, length: session.length) else { return }
        model.remember()
        session.closeSheet()
        session.setSelection(Selection(caret: target))
        session.editorView?.canvas.needsDisplay = true
    }
}

/// State of the Select Block sheet, starting from the current selection.
@Observable
final class SelectBlockModel {
    let start: NumberInput
    let end: NumberInput
    let length: NumberInput
    var usesLength: Bool { didSet { UserDefaults.standard.set(usesLength, forKey: "SelectBlockUsesLength") } }

    init(selection: Selection, base: NumberBase) {
        let r = selection.range
        start = NumberInput(r.lowerBound, base: base)
        end = NumberInput(r.isEmpty ? r.lowerBound : r.upperBound - 1, base: base)
        length = NumberInput(max(1, r.upperBound - r.lowerBound), base: base)
        usesLength = UserDefaults.standard.bool(forKey: "SelectBlockUsesLength")
    }

    var base: NumberBase {
        get { start.base }
        set { [start, end, length].forEach { $0.base = newValue } }
    }

    /// The bytes to select, or nil while an input is invalid or the block is empty.
    func range(length docLength: UInt64) -> Range<UInt64>? {
        guard let s = start.value, s < docLength else { return nil }
        let upper: UInt64
        if usesLength {
            guard let n = length.value, n > 0 else { return nil }
            upper = s.addingReportingOverflow(n).overflow ? docLength : min(s + n, docLength)
        } else {
            guard let e = end.value, e >= s else { return nil }
            upper = min(e + 1, docLength)
        }
        return s..<upper
    }
}

/// HxD's "Select block" dialog: start offset plus end offset or length.
struct SelectBlockSheet: View {
    @Bindable var model: SelectBlockModel
    let session: EditorSession

    var body: some View {
        let range = model.range(length: session.length)
        SheetScaffold(title: "Select Block", confirmTitle: "Select", canConfirm: range != nil,
                      onCancel: session.closeSheet, onConfirm: select) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Start offset:").gridColumnAlignment(.trailing)
                    NumberField(title: "Start offset", input: model.start)
                }
                GridRow {
                    Picker("End", selection: $model.usesLength) {
                        Text("End offset:").tag(false)
                        Text("Length:").tag(true)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    NumberField(title: model.usesLength ? "Length" : "End offset",
                                input: model.usesLength ? model.length : model.end)
                }
                GridRow {
                    Text("Numbers in:")
                    NumberBasePicker(base: $model.base)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(verbatim: range.map { L("%@ bytes", ($0.upperBound - $0.lowerBound).formatted()) } ?? L("The block is empty or outside the file."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func select() {
        guard let range = model.range(length: session.length) else { return }
        session.closeSheet()
        session.setSelection(Selection(range: range))
        session.editorView?.canvas.needsDisplay = true
    }
}
