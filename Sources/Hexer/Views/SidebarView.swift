import HexerCore
import SwiftUI

/// Bookmarks, undefined/unreadable sections and document facts, in the system sidebar list so
/// row sizes follow the user's sidebar size setting.
struct SidebarView: View {
    let session: EditorSession

    var body: some View {
        List {
            Section("Bookmarks") {
                if session.bookmarks.isEmpty {
                    Text("Press ⌃⇧0–9 to bookmark the caret position; ⌃0–9 jumps back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(session.bookmarks.keys.sorted(), id: \.self) { key in
                        let offset = session.bookmarks[key]!
                        Button {
                            session.setSelection(Selection(caret: min(offset, session.length)))
                            session.editorView?.canvas.needsDisplay = true
                        } label: {
                            HStack {
                                // A fixed color, used sparingly, marks bookmarks like Mail's VIP star.
                                Label {
                                    Text(verbatim: session.formatOffset(offset, minDigits: 8)).monospaced()
                                } icon: {
                                    Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                                }
                                Spacer()
                                Text(verbatim: "⌃\(key)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Bookmark") { session.bookmarks[key] = nil }
                        }
                    }
                }
            }
            Section("Sections") {
                let gaps = undefinedSections
                if gaps.isEmpty {
                    HStack {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text(verbatim: session.length == 0 ? "—"
                             : "\(session.formatOffset(0, minDigits: 8))–\(session.formatOffset(session.length - 1, minDigits: 8))")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                        Text("readable").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Undefined regions from Intel Hex and S-Record imports and unreadable disk sectors appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(gaps, id: \.lowerBound) { gap in
                        Button {
                            session.setSelection(Selection(range: gap))
                            session.editorView?.canvas.needsDisplay = true
                        } label: {
                            HStack {
                                Circle().fill(.secondary).frame(width: 7, height: 7)
                                Text(verbatim: "\(session.formatOffset(gap.lowerBound, minDigits: 8))–\(session.formatOffset(gap.upperBound - 1, minDigits: 8))")
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Spacer()
                                Text("undefined").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Document") {
                fact("Size", "\(session.length.formatted()) " + L("bytes"))
                fact("Modified", "\(modifiedBytes.formatted()) " + L("bytes"),
                     color: modifiedBytes > 0 ? Color(nsColor: HexTheme.modified) : .primary)
                fact("Encoding", session.encoding.shortName)
                fact("Layout", L("%lld bytes · group %lld", session.effectiveBytesPerRow, session.groupSize))
            }
        }
        .listStyle(.sidebar)
    }

    private func fact(_ title: LocalizedStringKey, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.callout)
    }

    private var undefinedSections: [Range<UInt64>] { session.undefinedSections(limit: 500) }

    private var modifiedBytes: UInt64 {
        _ = session.revision
        return session.buffer.tree.modifiedLength
    }
}
