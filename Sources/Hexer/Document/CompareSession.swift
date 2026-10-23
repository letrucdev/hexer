import AppKit
import HexerCore
import Observation

/// Two windows compared byte by byte (Analysis ▸ Compare): differences are highlighted in
/// both, F6/⇧F6 step through them, and scrolling one window scrolls the other.
///
/// Each side compares a range of its document (everything, or the selection when comparing
/// selected data); offsets inside those ranges are "relative" and start at 0 on both sides.
@Observable
final class CompareSession {
    @ObservationIgnored weak var left: EditorSession?
    @ObservationIgnored weak var right: EditorSession?
    let leftRange: Range<UInt64>
    let rightRange: Range<UInt64>
    var vertical: Bool
    /// The difference found last, relative to the compared ranges.
    var current: Range<UInt64>?
    var status: String?
    var isSearching = false
    /// Every differing run (relative offsets), listed in the Compare pane once computed.
    var allDifferences: [Range<UInt64>]?
    var allDifferencesTruncated = false
    @ObservationIgnored private var syncingScroll = false
    nonisolated static let maxListedDifferences = 10_000

    init(left: EditorSession, leftRange: Range<UInt64>, right: EditorSession, rightRange: Range<UInt64>, vertical: Bool) {
        self.left = left
        self.right = right
        self.leftRange = leftRange
        self.rightRange = rightRange
        self.vertical = vertical
    }

    private func range(of session: EditorSession) -> Range<UInt64>? {
        session === left ? leftRange : session === right ? rightRange : nil
    }

    private func partner(of session: EditorSession) -> EditorSession? {
        session === left ? right : session === right ? left : nil
    }

    /// The compared bytes of both sides, as snapshots starting at 0.
    private func snapshots() -> (ByteSnapshot, ByteSnapshot)? {
        guard let left, let right else { return nil }
        return (left.snapshot().slice(leftRange), right.snapshot().slice(rightRange))
    }

    /// Differing byte runs of `session` inside `visible` (absolute offsets), for highlighting.
    func differences(for session: EditorSession, visible: Range<UInt64>) -> [Range<UInt64>] {
        guard let mine = range(of: session), let other = partner(of: session), let otherRange = range(of: other) else { return [] }
        let lo = max(visible.lowerBound, mine.lowerBound), hi = min(visible.upperBound, mine.upperBound)
        guard lo < hi else { return [] }
        let a = session.snapshot().slice(mine)
        let b = other.snapshot().slice(otherRange)
        let relative = (lo - mine.lowerBound)..<(hi - mine.lowerBound)
        return CompareEngine.differingOffsets(in: relative, a, b).map {
            ($0.lowerBound + mine.lowerBound)..<($0.upperBound + mine.lowerBound)
        }
    }

    /// Selects the next (or previous) difference after the caret of `session` in both windows.
    func step(from session: EditorSession, backward: Bool) {
        guard !isSearching, let mine = range(of: session), let (a, b) = snapshots() else { return }
        let caret = session.caretByte
        let relCaret = caret < mine.lowerBound ? 0 : min(caret - mine.lowerBound, mine.upperBound - mine.lowerBound)
        // Continue after the difference shown last when the caret is still on it.
        let from = backward ? (current.map { relCaret <= $0.lowerBound ? relCaret : $0.lowerBound } ?? relCaret)
                            : (current.map { $0.contains(relCaret) ? $0.upperBound : relCaret } ?? relCaret)
        let flipped = session === right
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                let found = try await session.jobs.run(L("Comparing")) { job in
                    let (x, y) = flipped ? (b, a) : (a, b)
                    return backward
                        ? CompareEngine.previousDifference(x, y, before: from, isCancelled: { job.isCancelled }, progress: job.report)
                        : CompareEngine.nextDifference(x, y, from: from, isCancelled: { job.isCancelled }, progress: job.report)
                }
                guard let diff = found ?? nil else {
                    status = backward ? L("No earlier differences") : L("No more differences")
                    NSSound.beep()
                    return
                }
                current = diff
                status = L("Difference at %@ · %@ bytes", session.formatOffset(diff.lowerBound + mine.lowerBound),
                           (diff.upperBound - diff.lowerBound).formatted())
                show(diff)
            } catch {
                session.document?.presentError(error)
            }
        }
    }

    /// Lists every differing run, up to `maxListedDifferences`, for the Compare pane.
    func listDifferences(using session: EditorSession) {
        guard !isSearching, let (a, b) = snapshots() else { return }
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                let runs = try await session.jobs.run(L("Comparing")) { job -> [Range<UInt64>] in
                    var runs: [Range<UInt64>] = []
                    var from: UInt64 = 0
                    let total = Double(max(a.length, b.length, 1))
                    while runs.count <= Self.maxListedDifferences, !job.isCancelled,
                          let run = CompareEngine.nextDifference(a, b, from: from, isCancelled: { job.isCancelled }) {
                        runs.append(run)
                        from = run.upperBound
                        job.report(Double(from) / total)
                    }
                    return runs
                }
                guard let runs else { return }
                allDifferencesTruncated = runs.count > Self.maxListedDifferences
                allDifferences = Array(runs.prefix(Self.maxListedDifferences))
            } catch {
                session.document?.presentError(error)
            }
        }
    }

    /// Selects the difference `diff` (relative offsets) in both windows.
    func select(_ diff: Range<UInt64>) {
        current = diff
        show(diff)
    }

    /// The bytes of `diff` on the left or right side, at most `limit`.
    func bytes(of diff: Range<UInt64>, left side: Bool, limit: UInt64 = 16) -> [UInt8] {
        guard let session = side ? left : right else { return [] }
        let base = side ? leftRange : rightRange
        let lo = min(base.lowerBound + diff.lowerBound, base.upperBound)
        let hi = min(base.lowerBound + min(diff.upperBound, diff.lowerBound + limit), base.upperBound)
        return session.snapshot().bytes(lo..<hi)
    }

    /// Selects the relative range `diff` in both windows (clamped to each side's data).
    private func show(_ diff: Range<UInt64>) {
        for (session, range) in [(left, leftRange), (right, rightRange)] {
            guard let session else { continue }
            let lo = min(range.lowerBound + diff.lowerBound, range.upperBound)
            let hi = min(range.lowerBound + diff.upperBound, range.upperBound)
            session.setSelection(Selection(anchor: lo, caret: hi))
            session.editorView?.canvas.needsDisplay = true
        }
    }

    /// Keeps the other window at the same relative row while one of them scrolls.
    func didScroll(_ session: EditorSession, topRow: Double) {
        guard !syncingScroll, let other = partner(of: session), let mine = range(of: session),
              let theirs = range(of: other), let view = other.editorView, let mineView = session.editorView else { return }
        syncingScroll = true
        defer { syncingScroll = false }
        let relativeByte = mineView.topByte - Double(mine.lowerBound)
        view.scroll(toTopByte: relativeByte + Double(theirs.lowerBound))
    }

    func redrawBoth() {
        left?.editorView?.canvas.needsDisplay = true
        right?.editorView?.canvas.needsDisplay = true
    }

    /// Places the two windows side by side (or one above the other) on the screen.
    func arrange() {
        guard let a = left?.editorView?.window, let b = right?.editorView?.window,
              let screen = a.screen ?? NSScreen.main else { return }
        for w in [a, b] where (w.tabbedWindows?.count ?? 0) > 1 { w.moveTabToNewWindow(nil) }
        let area = screen.visibleFrame
        if vertical {
            a.setFrame(NSRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height), display: true)
            b.setFrame(NSRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height), display: true)
        } else {
            a.setFrame(NSRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2), display: true)
            b.setFrame(NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2), display: true)
        }
    }

    func stop() {
        for session in [left, right] {
            session?.compare = nil
            session?.editorView?.canvas.needsDisplay = true
        }
    }

    /// Starts comparing two windows and lines them up.
    static func start(_ left: EditorSession, _ leftRange: Range<UInt64>, _ right: EditorSession, _ rightRange: Range<UInt64>,
                      vertical: Bool) {
        left.compare?.stop()
        right.compare?.stop()
        let compare = CompareSession(left: left, leftRange: leftRange, right: right, rightRange: rightRange, vertical: vertical)
        left.compare = compare
        right.compare = compare
        // Hide the side panels so both grids get the room.
        for session in [left, right] {
            session.showInspector = false
            session.columnVisibility = .detailOnly
        }
        compare.status = L("F6: next difference")
        compare.redrawBoth()
        // Resize once SwiftUI has collapsed the side columns; resizing during that update
        // makes AppKit's constraint pass loop.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            compare.arrange()
        }
    }
}
