import AppKit
import Charts
import HexerCore
import SwiftUI

/// The histogram shown by a document's Statistics window.
@Observable
final class StatisticsModel {
    let session: EditorSession
    var counts: [UInt64]?
    var range: Range<UInt64> = 0..<0
    var selectionOnly = false
    /// HxD's "Hide maximum": leaves out the most frequent byte so the others are readable.
    var hideMaximum = true
    var hovered: Int?
    /// The bar clicked last; the side panel shows the hovered bar, else this one.
    var selected: Int?

    init(session: EditorSession) {
        self.session = session
        selectionOnly = !session.selection.isEmpty
    }

    func refresh() {
        let range = selectionOnly && !session.selection.isEmpty ? session.selection.range : 0..<session.length
        let snapshot = session.snapshot()
        Task {
            do {
                let counts = try await session.jobs.run(L("Counting bytes")) { job in
                    ByteStatistics.histogram(snapshot: snapshot, range: range, isCancelled: { job.isCancelled }, progress: job.report)
                }
                guard let counts = counts ?? nil else { return }
                self.counts = counts
                self.range = range
            } catch {
                session.document?.presentError(error)
            }
        }
    }

    var maximum: (value: UInt8, count: UInt64)? { counts.flatMap(ByteStatistics.mostFrequent) }
}

/// A window with the byte histogram of one document (Analysis ▸ Statistics).
final class StatisticsWindowController: NSWindowController, NSWindowDelegate {
    let model: StatisticsModel

    init(session: EditorSession) {
        model = StatisticsModel(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("Statistics — %@", session.document?.displayName ?? "")
        window.contentViewController = NSHostingController(rootView: StatisticsView(model: model))
        window.setContentSize(NSSize(width: 760, height: 460))
        window.minSize = NSSize(width: 520, height: 320)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("HexerStatisticsWindow")
        model.refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func show(for session: EditorSession) {
        if let existing = session.statisticsWindow {
            existing.showWindow(nil)
            return
        }
        let controller = StatisticsWindowController(session: session)
        session.statisticsWindow = controller
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.session.statisticsWindow = nil
    }
}

struct StatisticsView: View {
    @Bindable var model: StatisticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Scope", selection: $model.selectionOnly) {
                    Text("Whole file").tag(false)
                    Text("Selection").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.session.selection.isEmpty && !model.selectionOnly)
                Toggle("Hide maximum", isOn: $model.hideMaximum)
                    .help("Leave out the most frequent byte so the other bars are readable")
                Spacer()
                if let counts = model.counts {
                    Text(verbatim: L("%lld of 256 values present", counts.filter { $0 > 0 }.count))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                    .disabled(model.session.jobs.isBusy)
            }
            if let counts = model.counts {
                HStack(alignment: .top, spacing: 20) {
                    chart(counts)
                    details(counts)
                        .frame(width: 230)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .onChange(of: model.selectionOnly) { model.refresh() }
    }

    private struct Bar: Identifiable {
        let value: Int
        let count: UInt64
        var id: Int { value }
    }

    /// Each byte value owns the interval value..<value+1 of a continuous axis.
    private func barMark(_ bar: Bar) -> some ChartContent {
        let color: Color = bar.value == shownValue ? .orange : Color.accentColor.opacity(0.75)
        let x = Double(bar.value)
        let xStart: PlottableValue<Double> = .value("Byte", x + 0.08)
        let xEnd: PlottableValue<Double> = .value("Byte", x + 0.92)
        let yStart: PlottableValue<Double> = .value("Count", 0)
        let yEnd: PlottableValue<Double> = .value("Count", Double(bar.count))
        return RectangleMark(xStart: xStart, xEnd: xEnd, yStart: yStart, yEnd: yEnd).foregroundStyle(color)
    }

    private func chart(_ counts: [UInt64]) -> some View {
        let hidden = model.hideMaximum ? model.maximum.map { Int($0.value) } : nil
        let bars = counts.enumerated().map { Bar(value: $0.offset, count: $0.offset == hidden ? 0 : $0.element) }
        return Chart(bars) { barMark($0) }
        .chartXScale(domain: 0...256)
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
            }
        }
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: 256, by: 32))) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text(verbatim: String(format: "%02X", min(v, 255))).font(.caption.monospaced()) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let frame = proxy.plotFrame else { return }
                            let x = point.x - geometry[frame].origin.x
                            model.hovered = proxy.value(atX: x, as: Double.self).map { min(255, max(0, Int($0.rounded(.down)))) }
                        case .ended:
                            model.hovered = nil
                        }
                    }
                    .onTapGesture { model.selected = model.hovered }
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                        .demoAnchor("Statistics plot")
                }
            }
        }
        .frame(minHeight: 220)
    }

    /// The value described by the side panel: hovered, else clicked, else the most frequent.
    private var shownValue: Int? { model.hovered ?? model.selected ?? model.maximum.map { Int($0.value) } }

    private func details(_ counts: [UInt64]) -> some View {
        let total = ByteStatistics.total(counts)
        let table = model.session.encoding.table
        let value = shownValue ?? 0
        let count = counts[value]
        let share = total == 0 ? 0 : Double(count) / Double(total)
        return VStack(alignment: .leading, spacing: 10) {
            Text(model.hovered != nil ? "Value under the pointer" : "Selected value")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(verbatim: String(format: "0x%02X", value))
                .font(.system(size: 30, weight: .bold, design: .monospaced))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Character").foregroundStyle(.secondary)
                    Text(verbatim: table.isPrintable(UInt8(value)) ? "“\(table.display[value])”" : L("(control)"))
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Count").foregroundStyle(.secondary)
                    Text(verbatim: count.formatted())
                }
                GridRow {
                    Text("Share").foregroundStyle(.secondary)
                    Text(share, format: .percent.precision(.fractionLength(2)))
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Bytes").foregroundStyle(.secondary)
                    Text(verbatim: total.formatted())
                }
                GridRow {
                    Text("Entropy").foregroundStyle(.secondary)
                    Text(verbatim: L("%@ bits/byte", ByteStatistics.entropy(counts).formatted(.number.precision(.fractionLength(3)))))
                }
            }
            Text("Click a bar to keep it selected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}
