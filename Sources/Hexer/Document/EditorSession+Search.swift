import AppKit
import HexerCore
import Observation

/// State of a window's find bar. The query options (not the pattern) are remembered.
@Observable
final class FindModel {
    var isVisible = false
    var showsReplace = false
    var showsOptions = false
    var query: SearchQuery { didSet { saveOptions() } }
    var replacement = ""
    var direction: SearchDirection { didSet { UserDefaults.standard.set(direction.rawValue, forKey: "SearchDirection") } }
    /// Ask before each replacement during Replace All (HxD's "Prompt on replace").
    var promptOnReplace = true
    /// "3 of 15", "Not found", …
    var status: String?
    /// Why the pattern can't be searched for, in HxD's wording.
    var error: String?
    var isSearching = false
    /// Incremented to move keyboard focus into the search field.
    var focusRequest = 0

    init() {
        let d = UserDefaults.standard
        var saved = d.data(forKey: "SearchOptions").flatMap { try? JSONDecoder().decode(SearchQuery.self, from: $0) } ?? SearchQuery()
        saved.pattern = ""
        query = saved
        direction = SearchDirection(rawValue: d.string(forKey: "SearchDirection") ?? "") ?? .all
    }

    private func saveOptions() {
        var options = query
        options.pattern = ""
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "SearchOptions") }
    }
}

/// A row of the Search Results pane: a match identified by its offset.
struct SearchHit: Identifiable, Hashable {
    let range: Range<UInt64>
    var id: UInt64 { range.lowerBound }
}

extension EditorSession {
    // MARK: Showing the bar

    func showFind(replace: Bool) {
        find.isVisible = true
        if replace { find.showsReplace = true }
        find.focusRequest &+= 1
    }

    func hideFind() {
        find.isVisible = false
        find.status = nil
        jobs.cancelAll()
        if let canvas = editorView?.canvas { canvas.window?.makeFirstResponder(canvas) }
    }

    /// Puts the selected bytes into the search field: hex values from the hex column, text
    /// from the text column (HxD's "use selection for find").
    func useSelectionForFind() {
        let range = selection.range
        guard !range.isEmpty else { NSSound.beep(); return }
        let bytes = snapshot().bytes(range.lowerBound..<min(range.upperBound, range.lowerBound + 1024))
        if activeColumn == .hex {
            find.query.dataType = .hex
            find.query.pattern = bytes.map { String(format: lowercaseHex ? "%02x" : "%02X", $0) }.joined(separator: " ")
        } else {
            find.query.dataType = .text
            find.query.pattern = encoding.table.decode(bytes, filtered: false)
        }
        showFind(replace: false)
    }

    // MARK: Searching

    /// The query with the text encoding of this window, compiled; reports problems in the bar.
    private func compiledQuery() -> CompiledSearch? {
        var query = find.query
        if case .editor = query.text.encoding { query.text.encoding = .editor(encoding) }
        do {
            let compiled = try SearchEngine.compile(query)
            find.error = nil
            return compiled
        } catch {
            find.error = error.displayMessage
            NSSound.beep()
            return nil
        }
    }

    /// Finds the next match after the selection (or the previous one before it). Wraps around
    /// when the search direction is "All", like HxD.
    func findNext(backward: Bool = false) {
        guard !find.query.pattern.isEmpty else { showFind(replace: false); return }
        guard let compiled = compiledQuery(), !find.isSearching else { return }
        let snapshot = snapshot()
        let sel = selection
        let from = backward ? sel.range.lowerBound : (sel.isEmpty ? sel.caret : sel.range.lowerBound + 1)
        let wrap = find.direction == .all
        find.isSearching = true
        find.status = nil
        Task {
            defer { find.isSearching = false }
            do {
                let hit = try await jobs.run(L("Searching")) { job in
                    try SearchEngine.findNext(in: snapshot, query: compiled, from: from, direction: backward ? .backward : .forward,
                                              wrap: wrap, isCancelled: { job.isCancelled }, progress: job.report)
                }
                guard let hit = hit ?? nil else {
                    find.status = L("Not found")
                    NSSound.beep()
                    return
                }
                setSelection(Selection(anchor: hit.lowerBound, caret: hit.upperBound))
                editorView?.canvas.needsDisplay = true
                let wrapped = backward ? hit.lowerBound >= from : hit.lowerBound < from
                find.status = hitStatus(hit) ?? (wrapped ? L("Search wrapped") : nil)
            } catch is CancellationError {
                find.status = nil
            } catch {
                document?.presentError(error)
            }
        }
    }

    /// "3 of 15" when the hit is among the Find All results.
    private func hitStatus(_ hit: Range<UInt64>) -> String? {
        guard !searchHits.isEmpty else { return nil }
        let i = searchHits.partitioningIndex { $0.range.lowerBound >= hit.lowerBound }
        guard i < searchHits.count, searchHits[i].range == hit else { return nil }
        return L("%lld of %lld", i + 1, searchHits.count) + (searchHitsTruncated ? "+" : "")
    }

    /// Lists every match in the Search Results pane and highlights them in the grid.
    func findAll() {
        guard !find.query.pattern.isEmpty, let compiled = compiledQuery(), !find.isSearching else { return }
        let snapshot = snapshot()
        find.isSearching = true
        Task {
            defer { find.isSearching = false }
            do {
                let result = try await jobs.run(L("Searching")) { job in
                    try SearchEngine.findAll(in: snapshot, query: compiled, limit: Self.maxSearchHits,
                                             isCancelled: { job.isCancelled }, progress: job.report)
                }
                guard let result else { return }
                searchHits = result.matches.map(SearchHit.init)
                searchHitsTruncated = result.truncated
                drawerPane = .searchResults
                find.status = result.matches.isEmpty ? L("Not found")
                    : L("%lld matches", result.matches.count) + (result.truncated ? "+" : "")
                if result.matches.isEmpty { NSSound.beep() }
                editorView?.canvas.needsDisplay = true
            } catch is CancellationError {
            } catch {
                document?.presentError(error)
            }
        }
    }

    nonisolated static let maxSearchHits = 100_000

    /// Find All results that overlap `range`, for highlighting the visible rows.
    func searchHits(overlapping range: Range<UInt64>) -> ArraySlice<SearchHit> {
        guard !searchHits.isEmpty else { return [] }
        // Hits don't overlap, so their ends are sorted like their starts.
        let lo = searchHits.partitioningIndex { $0.range.upperBound > range.lowerBound }
        let hi = searchHits.partitioningIndex { $0.range.lowerBound >= range.upperBound }
        return lo < hi ? searchHits[lo..<hi] : []
    }

    func clearSearchHits() {
        searchHits = []
        searchHitsTruncated = false
        editorView?.canvas.needsDisplay = true
    }

    // MARK: Replacing

    private func compiledReplacement(for search: CompiledSearch) -> CompiledReplacement? {
        do {
            let replacement = try SearchEngine.compileReplacement(find.replacement, for: search)
            if buffer.isFixedSize { try replacement.validateFixedSize() }
            find.error = nil
            return replacement
        } catch {
            find.error = error.displayMessage
            NSSound.beep()
            return nil
        }
    }

    /// Replaces the selection if it is a match, then finds the next one.
    func replaceCurrent() {
        guard isEditable else { NSSound.beep(); return }
        guard let search = compiledQuery(), let replacement = compiledReplacement(for: search) else { return }
        let sel = selection
        let selected = snapshot().bytes(sel.range)
        if !sel.isEmpty, search.matchLength(selected) == selected.count {
            let bytes = replacement.bytes(forMatchLength: selected.count)
            if bytes.count != selected.count && !confirmSizeChange() { return }
            do {
                let after = Selection(caret: sel.range.lowerBound + UInt64(bytes.count))
                try buffer.apply(L("Replace"), replacing: sel.range, with: buffer.addPieces(bytes),
                                 selectionBefore: sel, selectionAfter: after)
                selection = after
                clearSearchHits()
            } catch {
                NSSound.beep()
                return
            }
        }
        findNext()
    }

    /// Replaces every match in one undoable step, asking first for each one when
    /// "Prompt on replace" is on.
    func replaceAll() {
        guard isEditable else { NSSound.beep(); return }
        guard let search = compiledQuery(), let replacement = compiledReplacement(for: search), !find.isSearching else { return }
        if replacement.changesLength && !confirmSizeChange() { return }
        let snapshot = snapshot()
        let before = selection
        find.isSearching = true
        Task {
            defer { find.isSearching = false }
            do {
                let found = try await jobs.run(L("Finding matches")) { job in
                    try ReplaceEngine.findMatches(in: snapshot, search: search, isCancelled: { job.isCancelled }, progress: job.report)
                }
                guard var matches = found, !matches.isEmpty else {
                    find.status = L("Not found")
                    NSSound.beep()
                    return
                }
                if find.promptOnReplace {
                    guard let chosen = promptForEachMatch(matches) else { return }
                    matches = chosen
                }
                guard !matches.isEmpty else { return }
                let pieces = replacement.bytesByMatchLength.mapValues { buffer.addPieces($0) }
                let tree = ReplaceEngine.replacingAll(in: snapshot.tree, matches: matches) {
                    pieces[Int($0.upperBound - $0.lowerBound)] ?? []
                }
                try buffer.apply(L("Replace All"), tree: tree, selectionBefore: before,
                                 selectionAfter: Selection(caret: min(matches[0].lowerBound, tree.length)))
                clearSearchHits()
                editorView?.canvas.needsDisplay = true
                find.status = L("Replaced %lld occurrences", matches.count)
            } catch is CancellationError {
            } catch {
                document?.presentError(error)
            }
        }
    }

    /// Selects each match in turn and asks Replace / Skip / All / Cancel. Returns the matches
    /// to replace, or nil when cancelled.
    private func promptForEachMatch(_ matches: [Range<UInt64>]) -> [Range<UInt64>]? {
        var chosen: [Range<UInt64>] = []
        for (i, match) in matches.enumerated() {
            setSelection(Selection(anchor: match.lowerBound, caret: match.upperBound))
            editorView?.canvas.needsDisplay = true
            editorView?.canvas.displayIfNeeded()
            let alert = NSAlert()
            alert.messageText = L("Replace this occurrence at %@?", formatOffset(match.lowerBound))
            alert.informativeText = L("Occurrence %lld of %lld.", i + 1, matches.count)
            alert.addButton(withTitle: L("Replace"))
            alert.addButton(withTitle: L("Skip"))
            alert.addButton(withTitle: L("All"))
            alert.addButton(withTitle: L("Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: chosen.append(match)
            case .alertSecondButtonReturn: continue
            case .alertThirdButtonReturn: return chosen + matches[i...]
            default: return nil
            }
        }
        return chosen
    }
}

extension RandomAccessCollection {
    /// The first index whose element satisfies `predicate`, which must be false for a prefix
    /// of the collection and true for the rest (binary search).
    func partitioningIndex(where predicate: (Element) -> Bool) -> Index {
        var lo = startIndex
        var n = count
        while n > 0 {
            let half = n / 2
            let mid = index(lo, offsetBy: half)
            if predicate(self[mid]) {
                n = half
            } else {
                lo = index(after: mid)
                n -= half + 1
            }
        }
        return lo
    }
}
