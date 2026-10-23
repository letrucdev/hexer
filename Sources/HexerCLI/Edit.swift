import HexerCore

/// `edit FILE -o OUT OP...`
///
/// Applies edits in order through the editor's buffer (piece tree, undo history) and saves with
/// `FileWriter`, as the app does. OUT may be FILE. Operations (numbers decimal or 0x hex, HEX as
/// digit pairs without spaces, RANGE as elsewhere but within the data):
///
///     overwrite:OFFSET:HEX   writes over the bytes at OFFSET; past the end it appends
///     insert:OFFSET:HEX      inserts before OFFSET (OFFSET may be the length)
///     delete:RANGE           removes the bytes
///     fill:RANGE:HEX         repeats HEX over the bytes (HxD's Fill Selection)
///     undo / redo            steps through the history
func edit(_ args: [String]) {
    let usage = "edit FILE -o OUT OP... (overwrite:OFFSET:HEX insert:OFFSET:HEX delete:RANGE fill:RANGE:HEX undo redo)"
    let a = Arguments(args, command: "edit", options: ["-o"])
    guard let output = a.value("-o"), a.positional.count >= 2 else { fail("usage: hexer-cli \(usage)") }
    let buffer = openBuffer(a.positional[0])

    func bytes(_ hex: String, _ op: String) -> [UInt8] {
        guard let b = try? SearchEngine.parseHex(hex), !b.isEmpty else { fail("edit: \(op): invalid hex values \(hex)") }
        return b
    }
    func offset(_ s: String, _ op: String) -> UInt64 {
        let v = parseNumber(s, op)
        guard v <= buffer.length else { fail("edit: \(op): offset \(v) is past the end (\(buffer.length))") }
        return v
    }
    func range(_ s: String, _ op: String) -> Range<UInt64> {
        let r = parseRange(s, length: .max)
        let upper = s.hasSuffix("-") ? buffer.length : r.upperBound
        guard r.lowerBound <= upper, upper <= buffer.length else {
            fail("edit: \(op): range \(s) is not within the data (\(buffer.length) bytes)")
        }
        return r.lowerBound..<upper
    }

    for op in a.positional.dropFirst() {
        let parts = op.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        attempt("edit") {
            switch (parts[0], parts.count) {
            case ("overwrite", 3):
                let at = offset(parts[1], op)
                try buffer.overwrite(bytes(parts[2], op), at: at, selectionBefore: Selection(caret: at))
            case ("insert", 3):
                let at = offset(parts[1], op)
                try buffer.insert(bytes(parts[2], op), at: at, selectionBefore: Selection(caret: at))
            case ("delete", 2):
                let r = range(parts[1], op)
                try buffer.delete(r, selectionBefore: Selection(range: r))
            case ("fill", 3):
                let r = range(parts[1], op)
                let selection = Selection(range: r)
                try buffer.apply("Fill", replacing: r,
                                 with: buffer.generatedPieces(.pattern(bytes(parts[2], op)), count: r.upperBound - r.lowerBound),
                                 selectionBefore: selection, selectionAfter: selection)
            case ("undo", 1):
                guard buffer.canUndo else { fail("edit: nothing to undo") }
                buffer.undo()
            case ("redo", 1):
                guard buffer.canRedo else { fail("edit: nothing to redo") }
                buffer.redo()
            default:
                fail("edit: invalid operation \(op) (see hexer-cli help)")
            }
        }
    }
    writeSnapshot(buffer.snapshot(), to: output, command: "edit")
}
