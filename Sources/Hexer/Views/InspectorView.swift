import AppKit
import HexerCore
import HexerDisasm
import SwiftUI

/// Shows the bytes at the caret as every enabled data type; values can be edited in place.
struct InspectorView: View {
    @Bindable var session: EditorSession
    @Bindable private var model: InspectorModel
    @AppStorage("InspectorLittleEndian") private var littleEndian = true
    @AppStorage("InspectorHexIntegers") private var hexIntegers = false
    @FocusState private var fieldFocused: Bool

    init(session: EditorSession) {
        self.session = session
        self.model = session.inspector
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 10) {
                Picker("Byte order", selection: $littleEndian) {
                    Text("Little endian").tag(true)
                    Text("Big endian").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .demoAnchor("Byte order")
                Toggle("Hex", isOn: $hexIntegers)
                    .controlSize(.small)
                    .help("Show integers in hexadecimal")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(InspectorType.Category.allCases, id: \.self) { category in
                        let rows = types.filter { $0.category == category }
                        if !rows.isEmpty {
                            Text(LocalizedStringKey(category.rawValue))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 3)
                            ForEach(rows, id: \.self) { type in row(type) }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            Divider()
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Data Inspector")
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("Data Inspector")
                .font(.system(size: 13, weight: .bold))
            Spacer()
            Group {
                Menu {
                    Toggle("Show integers in hexadecimal", isOn: $hexIntegers)
                    Divider()
                    Button("Choose Types…") { AppDelegate.openSettings(pane: 3) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Inspector options")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(InspectorType.allCases.filter { $0.fixedWidth != nil }, id: \.self) { t in
                    Button(LocalizedStringKey(t.displayName)) { model.stepType = t }
                }
            } label: {
                Text("Step as \(L(model.stepType.displayName))")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .help("The data type whose size the arrows step by")
            Spacer()
            stepButton("backward.end", "First array item") { step(to: 0) }
            stepButton("chevron.left", "Previous array item") { step(by: -1) }
            stepButton("chevron.right", "Next array item") { step(by: 1) }
            stepButton("forward.end", "Last array item") { step(to: .max) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
    }

    private var types: [InspectorType] {
        InspectorPreferences.enabledTypes
    }

    private var options: InspectorOptions {
        InspectorOptions(littleEndian: littleEndian, hexIntegers: hexIntegers, encoding: session.encoding)
    }

    /// The bytes at the caret up to the first undefined or unreadable one; types needing more show
    /// "—", as at the end of the data.
    private var caretBytes: [UInt8] {
        let p = session.caretByte
        let data = session.snapshot().read(p..<min(p + 16, session.length))
        let end = data.states.firstIndex { $0 == .undefined || $0 == .unreadable } ?? data.bytes.count
        return Array(data.bytes[..<end])
    }

    @ViewBuilder
    private func row(_ type: InspectorType) -> some View {
        let value = type.isDisassembly
            ? InspectorDisassembly.decode(type, caretBytes, address: session.caretByte)
            : DataInspector.decode(type, caretBytes, options: options)
        // Invalid values carry a short English word from HexerCore ("Invalid").
        let text = value.isValid ? value.text : L(value.text)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LocalizedStringKey(type.shortName))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if model.editing == type {
                TextField("Value", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .focused($fieldFocused)
                    .onSubmit { commit(type) }
                    .onExitCommand { model.editing = nil }
                    .frame(maxWidth: 180)
            } else {
                Text(verbatim: text)
                    .font(.system(size: 12, design: value.isValid ? .monospaced : .default))
                    .foregroundStyle(value.isValid ? .primary : .tertiary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(type.isDisassembly ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 3.5)
        .background(model.hovered == type ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { model.hovered = $0 ? type : (model.hovered == type ? nil : model.hovered) }
        .onTapGesture(count: 2) {
            guard type.isEditable, session.isEditable else { NSSound.beep(); return }
            model.draft = value.isValid ? value.text : ""
            model.editing = type
            fieldFocused = true
        }
        .help(Text(verbatim: type.isEditable ? text + "\n" + L("Double-click to edit") : text))
    }

    private func commit(_ type: InspectorType) {
        defer { model.editing = nil }
        do {
            let bytes = try DataInspector.encode(type, model.draft, options: options)
            let p = session.caretByte
            let before = session.selection
            if session.buffer.isFixedSize && p + UInt64(bytes.count) > session.length { NSSound.beep(); return }
            if p + UInt64(bytes.count) > session.length && !session.confirmSizeChange() { return }
            try session.buffer.overwrite(bytes, at: p, name: L("Edit %@", L(type.displayName)),
                                         selectionBefore: before, selectionAfter: before)
        } catch {
            NSSound.beep()
            session.document?.showMessage(L("“%@” is not a valid %@ value.", model.draft, L(type.displayName)), info: "")
        }
    }

    private func stepButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private func step(by items: Int64) {
        let w = Int64(model.stepType.fixedWidth ?? 1)
        let target = Int64(clamping: session.caretByte) + items * w
        session.setSelection(Selection(caret: UInt64(max(0, min(target, Int64(clamping: session.length))))))
    }

    private func step(to target: UInt64) {
        let w = UInt64(model.stepType.fixedWidth ?? 1)
        let start = session.caretByte % w
        if target == 0 {
            session.setSelection(Selection(caret: start))
        } else {
            let last = session.length >= w ? (session.length - w - start) / w * w + start : 0
            session.setSelection(Selection(caret: last))
        }
    }
}

/// Which inspector types are shown, in which order (Settings ▸ Data Inspector).
enum InspectorPreferences {
    static let key = "InspectorTypes"

    static var enabledTypes: [InspectorType] {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else { return InspectorType.allCases }
        return raw.compactMap(InspectorType.init(rawValue:))
    }

    static func setEnabledTypes(_ types: [InspectorType]) {
        UserDefaults.standard.set(types.map(\.rawValue), forKey: key)
    }
}

/// Editing state of the inspector.
@Observable
final class InspectorModel {
    var editing: InspectorType?
    var hovered: InspectorType?
    var draft = ""
    var stepType: InspectorType = .int32
}

/// Decodes the disassembly rows with Capstone: the instruction starting at the caret.
enum InspectorDisassembly {
    private static let disassemblers: [InspectorType: Disassembler] = {
        let archs: [(InspectorType, DisassemblyArchitecture)] = [(.x86_16, .x86_16), (.x86_32, .x86_32), (.x86_64, .x86_64), (.arm64, .arm64)]
        return Dictionary(uniqueKeysWithValues: archs.compactMap { type, arch in (try? Disassembler(arch)).map { (type, $0) } })
    }()

    static func decode(_ type: InspectorType, _ bytes: [UInt8], address: UInt64) -> InspectorValue {
        guard let disassembler = disassemblers[type], let instruction = disassembler.first(bytes, address: address) else {
            return InspectorValue(text: L("Invalid"), width: 0, isValid: false)
        }
        return InspectorValue(text: instruction.text, width: instruction.size, isValid: true)
    }
}
