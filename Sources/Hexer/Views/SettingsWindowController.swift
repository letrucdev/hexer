import AppKit
import HexerCore
import SwiftUI

/// The Settings window: a toolbar of panes, each a SwiftUI form.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func pane(_ title: String, _ symbol: String, _ view: some View) {
            let host = NSHostingController(rootView: view.frame(width: 520).fixedSize())
            // The tab view controller sizes the window to the selected pane's preferred size;
            // without it every pane sits centered in a default 500 × 500 window.
            host.sizingOptions = .preferredContentSize
            // Propagated to the window title, which names the visible pane (HIG).
            host.title = L(title)
            let item = NSTabViewItem(viewController: host)
            item.label = L(title)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L(title))
            tabs.addTabViewItem(item)
        }
        pane("General", "gearshape", GeneralSettingsView())
        pane("Format", "paintpalette", FormatSettingsView())
        pane("View", "rectangle.split.3x1", ViewSettingsView())
        pane("Inspector", "list.bullet.rectangle", InspectorSettingsView())
        pane("Export", "square.and.arrow.up", ExportSettingsView())
        // The title comes from the selected pane.
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        super.init(window: window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var hasBeenCentered = false

    /// Centers the window the first time it opens. The tab view controller sizes the window to the
    /// selected pane only as it comes on screen; centered before that, the window is centered at
    /// the tab view's default 500 × 500 and then grows to the right and down.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !hasBeenCentered else { return }
        hasBeenCentered = true
        window?.center()
    }
}

struct GeneralSettingsView: View {
    @Bindable var settings = AppSettings.shared
    @Bindable var update = SoftwareUpdate.shared

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Warn when opening a disk with write access", isOn: $settings.warnDiskWriteAccess)
                Toggle("Confirm file size changes", isOn: $settings.confirmSizeChange)
                Toggle("Tell me when copied text was filtered", isOn: $settings.warnFilteredClipboard)
                Toggle("Tell me when selected characters were filtered", isOn: $settings.warnFilteredSelection)
            }
            Section("Safety") {
                Toggle("Open disks as read-only", isOn: $settings.diskReadOnlyByDefault)
                Toggle("Keep a backup (.bak) when saving", isOn: $settings.makeBackups)
                Picker("New documents open in", selection: $settings.defaultMode) {
                    ForEach(EditMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if update.canUpdate {
                Section("Software Update") {
                    Toggle("Check for updates automatically", isOn: $update.checksAutomatically)
                    Toggle("Include beta versions", isOn: $update.includesBetas)
                    LabeledContent("Last checked") {
                        HStack {
                            Text(verbatim: update.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? L("Never"))
                            Button("Check Now") { update.checkForUpdates() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FormatSettingsView: View {
    @Bindable var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Font") {
                LabeledContent("Size") {
                    Stepper(value: $settings.fontSize, in: 9...28, step: 1) { Text(verbatim: "\(Int(settings.fontSize)) pt") }
                }
                Picker("Typeface", selection: $settings.fontName) {
                    Text(verbatim: "SF Mono").tag("")
                    Text(verbatim: "Menlo").tag("Menlo-Regular")
                    Text(verbatim: "Monaco").tag("Monaco")
                    Text(verbatim: "Courier New").tag("CourierNewPSMT")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ViewSettingsView: View {
    @Bindable var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Bytes per row", selection: $settings.bytesPerRow) {
                    ForEach([8, 16, 24, 32, 48, 64, 128, 256, 512, 1024, 4096], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                Toggle("Fit to window width", isOn: $settings.fitToWidth)
                Picker("Byte group size", selection: $settings.groupSize) {
                    ForEach([1, 2, 4, 8, 16], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                Picker("Columns", selection: $settings.columns) {
                    Text("Hex and Text").tag(VisibleColumns.hexAndText)
                    Text("Hex Only").tag(VisibleColumns.hex)
                    Text("Text Only").tag(VisibleColumns.text)
                }
            }
            Section {
                Picker("Text encoding", selection: $settings.encoding) {
                    ForEach(TextEncoding.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                Picker("Offset base", selection: $settings.offsetBase) {
                    Text("Hexadecimal").tag(NumberBase.hexadecimal)
                    Text("Decimal").tag(NumberBase.decimal)
                    Text("Octal").tag(NumberBase.octal)
                }
                Toggle("Lowercase hex digits (abcdef)", isOn: $settings.lowercaseHex)
            } header: {
                Text("Text and numbers")
            } footer: {
                Text("These defaults apply to newly opened documents. The View menu changes the current window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@Observable
final class InspectorSettingsModel {
    var enabled: Set<InspectorType> = Set(InspectorPreferences.enabledTypes)
}

struct InspectorSettingsView: View {
    @Bindable private var model = InspectorSettingsModel()

    var body: some View {
        Form {
            Section("Types shown") {
                ForEach(InspectorType.allCases, id: \.self) { t in
                    Toggle(LocalizedStringKey(t.displayName), isOn: Binding {
                        model.enabled.contains(t)
                    } set: { on in
                        if on { model.enabled.insert(t) } else { model.enabled.remove(t) }
                        InspectorPreferences.setEnabledTypes(InspectorType.allCases.filter(model.enabled.contains))
                    })
                }
            }
            Button("Reset") {
                model.enabled = Set(InspectorType.allCases)
                InspectorPreferences.setEnabledTypes(InspectorType.allCases)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

/// Export settings (HxD's Options ▸ Export), read by File ▸ Export and Edit ▸ Copy As.
struct ExportOptions: Sendable {
    var sourceWrap: SourceCodeOptions.LineWrap
    var srecordBytesPerLine: Int
    var intelHexBytesPerLine: Int

    static var current: ExportOptions {
        let d = UserDefaults.standard
        d.register(defaults: ["ExportSourceWrapByCharacters": true, "ExportSourceBytesPerLine": 16,
                              "ExportSourceCharsPerLine": 80, "ExportSRecordBytesPerLine": 32, "ExportIntelHexBytesPerLine": 32])
        let byCharacters = d.bool(forKey: "ExportSourceWrapByCharacters")
        return ExportOptions(
            sourceWrap: byCharacters ? .charactersPerLine(max(1, d.integer(forKey: "ExportSourceCharsPerLine")))
                                     : .bytesPerLine(max(1, d.integer(forKey: "ExportSourceBytesPerLine"))),
            srecordBytesPerLine: min(max(1, d.integer(forKey: "ExportSRecordBytesPerLine")), 250),
            intelHexBytesPerLine: min(max(1, d.integer(forKey: "ExportIntelHexBytesPerLine")), 255))
    }
}

struct ExportSettingsView: View {
    @AppStorage("ExportSourceWrapByCharacters") private var wrapByCharacters = true
    @AppStorage("ExportSourceBytesPerLine") private var sourceBytesPerLine = 16
    @AppStorage("ExportSourceCharsPerLine") private var sourceCharsPerLine = 80
    @AppStorage("ExportSRecordBytesPerLine") private var srecordBytesPerLine = 32
    @AppStorage("ExportIntelHexBytesPerLine") private var intelHexBytesPerLine = 32

    var body: some View {
        Form {
            Section("Source code") {
                Picker("Line break determined by", selection: $wrapByCharacters) {
                    Text("Bytes per line").tag(false)
                    Text("Characters per line").tag(true)
                }
                .pickerStyle(.radioGroup)
                if wrapByCharacters {
                    LabeledContent("Characters per line") {
                        Stepper(value: $sourceCharsPerLine, in: 20...1000) { Text(verbatim: "\(sourceCharsPerLine)") }
                    }
                } else {
                    LabeledContent("Bytes per line") {
                        Stepper(value: $sourceBytesPerLine, in: 1...1024) { Text(verbatim: "\(sourceBytesPerLine)") }
                    }
                }
            }
            Section("Motorola S-Record") {
                LabeledContent("Bytes per line") {
                    Stepper(value: $srecordBytesPerLine, in: 1...250) { Text(verbatim: "\(srecordBytesPerLine)") }
                }
            }
            Section("Intel Hex") {
                LabeledContent("Bytes per line") {
                    Stepper(value: $intelHexBytesPerLine, in: 1...255) { Text(verbatim: "\(intelHexBytesPerLine)") }
                }
            }
        }
        .formStyle(.grouped)
    }
}
