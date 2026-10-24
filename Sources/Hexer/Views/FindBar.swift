import HexerCore
import SwiftUI

/// The floating Liquid Glass find bar over the top-right of the grid (⌘F, ⌥⌘F with Replace).
///
/// The capsules share one glass container, so the Replace row grows out of the Find capsule.
struct FindBar: View {
    let session: EditorSession
    @Bindable var find: FindModel
    @FocusState private var fieldFocused: Bool
    @FocusState private var replaceFocused: Bool
    @Namespace private var glass

    init(session: EditorSession) {
        self.session = session
        find = session.find
    }

    var body: some View {
        GlassGroup(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    searchCapsule
                    HStack(spacing: 0) {
                        iconButton("chevron.up", "Find Previous (⇧⌘G)") { session.findNext(backward: true) }
                        iconButton("chevron.down", "Find Next (⌘G)") { session.findNext() }
                    }
                    .padding(.horizontal, 4)
                    .frame(height: GlassBar.height)
                    .barGlass()
                    .barGlassID("nav", in: glass)
                    .demoAnchor("Find navigation")
                    Button("Find All", action: session.findAll)
                        .buttonStyle(.glassCapsuleProminent)
                        .disabled(find.query.pattern.isEmpty || find.isSearching)
                        .barGlassID("all", in: glass)
                        .demoAnchor("Find All")
                    HStack(spacing: 0) {
                        iconButton("arrow.left.arrow.right", find.showsReplace ? "Hide Replace" : "Show Replace") {
                            withAnimation(.bouncy) { find.showsReplace.toggle() }
                        }
                        .foregroundStyle(find.showsReplace ? Color.accentColor : Color.primary)
                        iconButton("xmark", "Close (Esc)") { session.hideFind() }
                    }
                    .padding(.horizontal, 4)
                    .frame(height: GlassBar.height)
                    .barGlass()
                    .barGlassID("tools", in: glass)
                }
                if find.showsReplace {
                    replaceRow
                }
                if let error = find.error {
                    Text(verbatim: error)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        // A message, not a control: a standard material rather than Liquid Glass.
                        .background(.regularMaterial, in: .capsule)
                }
            }
        }
        .onAppear { fieldFocused = true }
        .onChange(of: find.focusRequest) { fieldFocused = true }
        .onChange(of: find.query) { find.error = nil }
        .onExitCommand { session.hideFind() }
    }

    private var searchCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $find.query.pattern)
                .textFieldStyle(.plain)
                .font(find.query.dataType == .text ? .body : .body.monospaced())
                // The fields give way first when the grid is narrow; labels never wrap.
                .frame(minWidth: 90, idealWidth: 200, maxWidth: 200)
                .focused($fieldFocused)
                .onSubmit { session.findNext(backward: find.direction == .backward) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    session.findNext(backward: find.direction != .backward)
                    return .handled
                }
            if find.isSearching {
                ProgressView().controlSize(.small)
                Button("Stop") { session.jobs.cancelAll() }
                    .controlSize(.small)
            } else if let status = find.status {
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button {
                find.showsOptions.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text(dataTypeTitle(find.query.dataType))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Data type and search options")
            .demoAnchor("Find type")
            .popover(isPresented: $find.showsOptions, arrowEdge: .bottom) {
                FindOptions(find: find, editorEncoding: session.encoding)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: GlassBar.height)
        .demoAnchor("Find field")
        .barGlass()
        .overlay {
            if find.error != nil { Capsule().strokeBorder(.red, lineWidth: 1.5) }
        }
        .barGlassID("search", in: glass)
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Toggle("Prompt on replace", isOn: $find.promptOnReplace)
                .toggleStyle(.checkbox)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: GlassBar.height)
                .barGlass(interactive: false)
                .barGlassID("prompt", in: glass)
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Replace with", text: $find.replacement)
                    .textFieldStyle(.plain)
                    .font(find.query.dataType == .text ? .body : .body.monospaced())
                    .frame(minWidth: 90, idealWidth: 228, maxWidth: 228)
                    .focused($replaceFocused)
                    .onSubmit(session.replaceCurrent)
            }
            .padding(.horizontal, 12)
            .frame(height: GlassBar.height)
            .barGlass()
            .barGlassID("replace", in: glass)
            Button("Replace", action: session.replaceCurrent)
                .buttonStyle(.glassCapsule)
            Button("Replace All", action: session.replaceAll)
                .buttonStyle(.glassCapsuleProminent)
        }
        .disabled(!session.isEditable || find.isSearching)
    }

    private var placeholder: String {
        switch find.query.dataType {
        case .text: L("Find text")
        case .hex: L("Find hex values, e.g. 4D 5A")
        case .integer: L("Find an integer")
        case .float: L("Find a floating point number")
        }
    }

    private func iconButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        GlassBarIconButton(symbol, help, action: action)
    }
}

/// Short names for the data type button.
func dataTypeTitle(_ type: SearchQuery.DataType) -> String {
    switch type {
    case .text: L("Text")
    case .hex: L("Hex")
    case .integer: L("Integer")
    case .float: L("Float")
    }
}

/// The search options popover: data type, its options, and the search direction.
struct FindOptions: View {
    @Bindable var find: FindModel
    let editorEncoding: TextEncoding

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Data type", selection: $find.query.dataType) {
                ForEach(SearchQuery.DataType.allCases, id: \.self) { Text(dataTypeTitle($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .demoAnchor("Find data type")
            Group {
                switch find.query.dataType {
                case .text: textOptions
                case .hex:
                    Text("Type hex pairs, spaces optional: 54 46 6F 72 6D. ⌘E with bytes selected in the hex column fills this in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .integer: integerOptions
                case .float: floatOptions
                }
            }
            .frame(width: 330, alignment: .leading)
            Divider()
            HStack {
                Text("Direction")
                    .foregroundStyle(.secondary)
                Picker("Direction", selection: $find.direction) {
                    Text("All").tag(SearchDirection.all)
                    Text("Forward").tag(SearchDirection.forward)
                    Text("Backward").tag(SearchDirection.backward)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text("“All” searches the whole file, wrapping around at the end.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var textOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Encoding").foregroundStyle(.secondary)
                Picker("Encoding", selection: $find.query.text.encoding) {
                    Text(L("Editor (%@)", editorEncoding.shortName)).tag(SearchQuery.TextEncodingChoice.editor(editorEncoding))
                    Text("Unicode UTF-16 LE").tag(SearchQuery.TextEncodingChoice.utf16LittleEndian)
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Case sensitive", isOn: $find.query.text.caseSensitive)
            }
        }
        .onAppear {
            // The editor encoding follows the window, whatever was saved.
            if case .editor = find.query.text.encoding { find.query.text.encoding = .editor(editorEncoding) }
        }
    }

    private var integerOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Bit width").foregroundStyle(.secondary)
                Picker("Bit width", selection: $find.query.integer.width) {
                    ForEach(SearchQuery.IntegerWidth.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Byte order").foregroundStyle(.secondary)
                byteOrderPicker($find.query.integer.byteOrder)
            }
            GridRow {
                Text("Sign").foregroundStyle(.secondary)
                Picker("Sign", selection: $find.query.integer.signedness) {
                    Text("Either").tag(SearchQuery.Signedness.either)
                    Text("Signed").tag(SearchQuery.Signedness.signed)
                    Text("Unsigned").tag(SearchQuery.Signedness.unsigned)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var floatOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Type").foregroundStyle(.secondary)
                Picker("Type", selection: $find.query.float.type) {
                    ForEach(SearchQuery.FloatType.allCases, id: \.self) { t in
                        Text(L("%@ · %lld bytes", t.displayName, t.byteCount)).tag(t)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            GridRow {
                Text("Byte order").foregroundStyle(.secondary)
                byteOrderPicker($find.query.float.byteOrder)
            }
        }
    }

    private func byteOrderPicker(_ selection: Binding<SearchQuery.ByteOrder>) -> some View {
        Picker("Byte order", selection: selection) {
            Text("Little endian").tag(SearchQuery.ByteOrder.littleEndian)
            Text("Big endian").tag(SearchQuery.ByteOrder.bigEndian)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
