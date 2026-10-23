import HexerCore
import SwiftUI

/// A sheet shown over a document window; `content` builds its SwiftUI view.
struct SheetRequest: Identifiable {
    let id = UUID()
    let content: AnyView

    init(@ViewBuilder _ content: () -> some View) {
        self.content = AnyView(content())
    }
}

/// A number typed in hex, decimal or octal, like HxD's number fields with their base buttons.
/// Switching the base converts what was typed.
@Observable
final class NumberInput {
    var text: String
    var base: NumberBase {
        didSet {
            guard oldValue != base, let v = oldValue.parse(text) else { return }
            text = base.format(v)
        }
    }

    init(_ value: UInt64 = 0, base: NumberBase) {
        self.base = base
        text = base.format(value)
    }

    var value: UInt64? { base.parse(text) }
}

/// The hex/dec/oct switch shared by the number fields of a dialog.
struct NumberBasePicker: View {
    @Binding var base: NumberBase

    var body: some View {
        Picker("Number base", selection: $base) {
            Text("hex").tag(NumberBase.hexadecimal)
            Text("dec").tag(NumberBase.decimal)
            Text("oct").tag(NumberBase.octal)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A monospaced number field that turns red while its text is not a number in its base.
struct NumberField: View {
    let title: LocalizedStringKey
    @Bindable var input: NumberInput
    var allowsSign = false

    var body: some View {
        TextField(title, text: $input.text)
            .font(.body.monospaced())
            .textFieldStyle(.roundedBorder)
            .foregroundStyle(isValid ? Color.primary : Color.red)
            .frame(minWidth: 180)
    }

    private var isValid: Bool {
        var t = input.text.trimmingCharacters(in: .whitespaces)
        if allowsSign, let first = t.first, first == "-" || first == "+" { t.removeFirst() }
        return t.isEmpty || input.base.parse(t) != nil
    }
}

/// Title, content and Cancel/OK buttons in the layout every Hexer sheet uses.
struct SheetScaffold<Content: View>: View {
    let title: LocalizedStringKey
    var confirmTitle: LocalizedStringKey = "OK"
    var canConfirm = true
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        // Sheets don't grow to fit wide content on their own.
        .fixedSize()
    }
}
