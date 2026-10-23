import HexerCore
import SwiftUI

/// Offset, selection and mode, like HxD's status bar. The mode chip toggles insert/overwrite.
struct StatusBarView: View {
    let session: EditorSession

    var body: some View {
        HStack(spacing: 18) {
            field("Offset", session.formatOffset(session.caretByte))
            if session.selection.isEmpty {
                field("Block", "—")
                field("Length", "0")
            } else {
                let r = session.selection.range
                field("Block", "\(session.formatOffset(r.lowerBound))–\(session.formatOffset(r.upperBound - 1))")
                field("Length", "\(session.formatOffset(r.upperBound - r.lowerBound)) (\(r.upperBound - r.lowerBound))")
            }
            Spacer(minLength: 8)
            ForEach(session.jobs.jobs) { JobCapsule(job: $0) }
            // Encoding and offset base are the first to go when the window is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    Text(session.encoding.shortName)
                    Text(offsetBaseName)
                }
                Text(session.encoding.shortName)
                Color.clear.frame(width: 0, height: 0)
            }
            .lineLimit(1)
            Button {
                guard session.mode != .readOnly else { NSSound.beep(); return }
                session.mode = session.mode == .insert ? .overwrite : .insert
            } label: {
                Text(session.mode.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .glassEffect(.regular.tint(.accentColor.opacity(0.18)).interactive(), in: .capsule)
            .help("Click to switch between Insert and Overwrite (⌘I)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var offsetBaseName: String {
        switch session.offsetBase {
        case .hexadecimal: L("Hex offsets")
        case .decimal: L("Decimal offsets")
        case .octal: L("Octal offsets")
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: L(title) + ":")
            Text(verbatim: value)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A running background job: title, progress and a stop button, in a glass capsule.
struct JobCapsule: View {
    let job: Job

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: job.progress)
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text(verbatim: job.title)
                .lineLimit(1)
            Text(job.progress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
            Button {
                job.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Stop")
        }
        .font(.caption)
        // A status indicator, not a control: no Liquid Glass (WWDC25 "Build an AppKit app with
        // the new design").
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: .capsule)
    }
}
