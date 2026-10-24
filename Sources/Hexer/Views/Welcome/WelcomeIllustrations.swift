import AppKit
import SwiftUI

// The moving pictures of the welcome tour. Each is a function of the seconds into its loop and
// redraws only at the moments something changes, in a step, as the editor does when you type:
// SwiftUI draws this window on the CPU, and animating between the steps cost a fifth of a core.
// With Reduce Motion each holds one telling moment.

private let hexStrings: [String] = (0..<256).map { String(format: "%02X", $0) }

func welcomeHex(_ byte: UInt8) -> String { hexStrings[Int(byte)] }

/// SplitMix64 of a few integers: the same "random" bytes every time.
func welcomeScramble(_ a: Int, _ b: Int = 0, _ c: Int = 0) -> UInt64 {
    var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791)) &+ 0x9E37_79B9_7F4A_7C15
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    return x ^ (x >> 31)
}

/// The moments a picture changes: `times` seconds into each `cycle` after `start` (an infinite
/// cycle runs once, then the timeline stops).
struct WelcomeSchedule: TimelineSchedule {
    let start: Date
    let times: [Double]
    let cycle: Double

    func entries(from date: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var first: Date? = date
        var loop = cycle.isFinite ? max(0, (date.timeIntervalSince(start) / cycle).rounded(.down)) : 0
        var index = 0
        return AnyIterator { [start, times, cycle] in
            if let now = first {
                first = nil
                return now
            }
            while !times.isEmpty {
                if index == times.count {
                    guard cycle.isFinite else { return nil }
                    index = 0
                    loop += 1
                }
                let next = start.addingTimeInterval((cycle.isFinite ? loop * cycle : 0) + times[index])
                index += 1
                if next > date { return next }
            }
            return nil
        }
    }
}

/// Shows `content` at the seconds into its loop, `delay` after `start`, updating at `times`.
struct WelcomeLoop<Content: View>: View {
    let start: Date
    var delay = 0.6
    var cycle = Double.infinity
    let times: [Double]
    /// The moment shown with Reduce Motion.
    let still: Double
    @ViewBuilder let content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content(still)
        } else {
            TimelineView(WelcomeSchedule(start: start.addingTimeInterval(delay), times: times, cycle: cycle)) { context in
                // A hair late, so a moment from the schedule never rounds to just before itself.
                content(max(0, context.date.timeIntervalSince(start) - delay + 0.001).truncatingRemainder(dividingBy: cycle))
            }
        }
    }
}

// MARK: - Shared pieces

extension View {
    /// The white (or dark) sheet of an illustration, like the editor's grid.
    fileprivate func welcomeCard() -> some View {
        background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 7)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

/// A few rows of the hex grid drawn like the editor's: offsets, alternating column colors,
/// modified bytes in bold red, search hits, the caret and its ghost in the text column.
struct WelcomeMiniGrid: View {
    struct Cell {
        var byte: UInt8
        var modified = false
        var mark = Mark.none
    }

    enum Mark { case none, hit, current }

    var firstOffset: Int
    var rows: [[Cell]]
    var caret: (row: Int, column: Int)?
    var hitOpacity = 1.0

    private static let cellWidth: CGFloat = 23
    private static let offsetWidth: CGFloat = 74
    private var columns: Int { rows.first?.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: L("Offset") + " (h)")
                    .frame(width: Self.offsetWidth, alignment: .leading)
                ForEach(0..<columns, id: \.self) { c in
                    Text(verbatim: welcomeHex(UInt8(c)))
                        .foregroundStyle(caret?.column == c ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: Self.cellWidth)
                }
                Text("Decoded text")
                    .lineLimit(1)
                    .padding(.leading, 12)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 24, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: HexTheme.headerBackground))
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    Text(verbatim: String(format: "%08X", firstOffset + r * columns))
                        .foregroundStyle(Color(nsColor: HexTheme.offset))
                        .frame(width: Self.offsetWidth, alignment: .leading)
                    ForEach(0..<columns, id: \.self) { c in hexCell(r, c) }
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { c in textCell(r, c) }
                    }
                    .padding(.leading, 12)
                }
                .padding(.horizontal, 14)
                .frame(height: 21)
            }
            .padding(.vertical, 2)
        }
        .font(.system(size: 12, design: .monospaced))
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .welcomeCard()
    }

    private func isCaret(_ r: Int, _ c: Int) -> Bool { caret.map { $0.row == r && $0.column == c } ?? false }

    private func markFill(_ mark: Mark) -> Color {
        switch mark {
        case .none: .clear
        case .hit: Color(nsColor: HexTheme.searchHit).opacity(hitOpacity)
        case .current: Color.accentColor.opacity(0.3 * hitOpacity)
        }
    }

    private func hexCell(_ r: Int, _ c: Int) -> some View {
        let cell = rows[r][c]
        let color: Color = cell.modified ? Color(nsColor: HexTheme.modified)
            : c % 2 == 1 ? Color(nsColor: HexTheme.oddColumn) : .primary
        return Text(verbatim: welcomeHex(cell.byte))
            .fontWeight(cell.modified ? .bold : .regular)
            .foregroundStyle(color)
            .frame(width: Self.cellWidth, height: 18)
            .background(markFill(cell.mark), in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .bottom) {
                if isCaret(r, c) {
                    Rectangle().fill(Color.accentColor).frame(width: 17, height: 2)
                }
            }
    }

    private func textCell(_ r: Int, _ c: Int) -> some View {
        let cell = rows[r][c]
        let character = (0x20...0x7E).contains(cell.byte) ? String(UnicodeScalar(cell.byte)) : "."
        return Text(verbatim: character)
            .fontWeight(cell.modified ? .bold : .regular)
            .foregroundStyle(cell.modified ? Color(nsColor: HexTheme.modified) : .primary)
            .frame(width: 8, height: 18)
            .background(markFill(cell.mark))
            .overlay {
                if isCaret(r, c) {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                }
            }
    }
}

/// A small label in a capsule, standing for the glass capsules and chips of the editor.
private struct WelcomeCapsule<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6, content: content)
            .font(.system(size: 11.5))
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background {
                if let tint {
                    Capsule().fill(tint.opacity(0.15))
                }
            }
            .barGlass(interactive: false)
    }
}

// MARK: - Page 0

/// "Hexer" as the grid would show it: random bytes settle one by one into 48 65 78 65 72 while
/// the caret walks along, and each letter appears in the text column as its byte settles.
struct WelcomeDecodeRow: View {
    let start: Date

    private static let word = Array("Hexer".utf8)

    var body: some View {
        WelcomeLoop(start: start, delay: 0.8, times: Array(stride(from: 0, through: 1.2, by: 0.05)), still: 10) { t in
            HStack(spacing: 0) {
                Text(verbatim: "00000000")
                    .foregroundStyle(Color(nsColor: HexTheme.offset))
                    .padding(.trailing, 14)
                ForEach(Self.word.indices, id: \.self) { i in byteCell(i, t: t) }
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 24)
                    .padding(.horizontal, 14)
                ForEach(Self.word.indices, id: \.self) { i in character(i, t: t) }
            }
            .font(.system(size: 18, weight: .medium, design: .monospaced))
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .welcomeCard()
        }
        .accessibilityHidden(true)
    }

    private func settled(_ i: Int, _ t: Double) -> Bool { t >= 0.15 + 0.17 * Double(i) }

    private func byteCell(_ i: Int, t: Double) -> some View {
        let settled = settled(i, t)
        let value = settled ? Self.word[i] : UInt8(truncatingIfNeeded: welcomeScramble(i, Int((t * 20).rounded()), 7))
        return Text(verbatim: welcomeHex(value))
            .foregroundStyle(settled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .scaleEffect(settled ? 1 : 0.82)
            .animation(.spring(duration: 0.35, bounce: 0.6), value: settled)
            .frame(width: 34)
            .overlay(alignment: .bottom) {
                if !settled && (i == 0 || self.settled(i - 1, t)) {
                    Capsule().fill(Color.accentColor).frame(width: 22, height: 2.5).offset(y: 5)
                }
            }
    }

    private func character(_ i: Int, t: Double) -> some View {
        let settled = settled(i, t)
        return Text(verbatim: String(UnicodeScalar(Self.word[i])))
            .foregroundStyle(settled ? Color.primary : Color.accentColor)
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 8)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: settled)
            .frame(width: 13)
    }
}

// MARK: - Page 1

/// Typing over "hello" turns it into "HEXER", byte by byte in bold red, then ⌘Z takes it back.
struct WelcomeEditIllustration: View {
    let start: Date

    private static let original: [[UInt8]] = [Array("Hex edit".utf8), Array("hello, w".utf8), Array("orld!\n\0\0".utf8)]
    private static let typed = Array("HEXER".utf8)

    /// When byte `i` gets its high nibble; the low one follows `nibble` later, and the caret moves on.
    private static func typesAt(_ i: Int) -> Double { 0.3 + 0.4 * Double(i) }
    private static let nibble = 0.2
    private static func undoneAt(_ i: Int) -> Double { 3.8 + 0.2 * Double(typed.count - 1 - i) }
    private static let keycap = 3.4..<5.0
    private static let times = (typed.indices.flatMap { [typesAt($0), typesAt($0) + nibble, undoneAt($0)] }
        + [0, keycap.lowerBound, keycap.upperBound]).sorted()

    var body: some View {
        WelcomeLoop(start: start, cycle: 7, times: Self.times, still: 3.2) { t in
            WelcomeMiniGrid(firstOffset: 0x40, rows: rows(at: t), caret: (1, caretColumn(at: t)))
                .overlay(alignment: .topTrailing) {
                    WelcomeCapsule(tint: .accentColor) { Text("Overwrite") }
                        .offset(x: 18, y: -34)
                }
                .overlay(alignment: .bottomTrailing) { keycap(at: t).offset(x: 34, y: 18) }
        }
    }

    private func rows(at t: Double) -> [[WelcomeMiniGrid.Cell]] {
        var rows = Self.original.map { $0.map { WelcomeMiniGrid.Cell(byte: $0) } }
        for (i, new) in Self.typed.enumerated() where t >= Self.typesAt(i) && t < Self.undoneAt(i) {
            let old = Self.original[1][i]
            // The high nibble goes in first, then the low one, as when typing in the grid.
            rows[1][i] = .init(byte: t < Self.typesAt(i) + Self.nibble ? new & 0xF0 | old & 0x0F : new, modified: true)
        }
        return rows
    }

    private func caretColumn(at t: Double) -> Int {
        if t >= Self.undoneAt(Self.typed.count - 1) {
            return Self.typed.indices.filter { t >= Self.undoneAt($0) }.min() ?? 0
        }
        return Self.typed.indices.filter { t >= Self.typesAt($0) + Self.nibble }.count
    }

    private func keycap(at t: Double) -> some View {
        VStack(spacing: 3) {
            Text(verbatim: "⌘Z")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(width: 52, height: 40)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            Text("Undo")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .opacity(Self.keycap.contains(t) ? 1 : 0)
    }
}

// MARK: - Page 2

/// Find marks every FF D8 FF (a JPEG header), the current match moves from one to the next, and
/// the inspector decodes the bytes there.
struct WelcomeFindIllustration: View {
    let start: Date

    private static let data: [[UInt8]] = [
        [0x00, 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A],
        [0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x48],
        [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x18, 0x45, 0x78],
        [0x69, 0x66, 0x00, 0xFF, 0xD8, 0xFF, 0xDB, 0x00],
    ]
    private static let hits = [(0, 1), (2, 0), (3, 3)]
    private static let fadesAt = 5.8

    private static func current(at t: Double) -> Int? {
        t < 1.0 || t >= fadesAt ? nil : min(Int((t - 1.0) / 1.6), hits.count - 1)
    }

    var body: some View {
        WelcomeLoop(start: start, cycle: 6.6, times: [0, 0.4, 0.55, 0.7, 1.0, 2.6, 4.2, Self.fadesAt], still: 1.5) { t in
            let now = Self.current(at: t)
            HStack(alignment: .top, spacing: 12) {
                WelcomeMiniGrid(firstOffset: 0, rows: rows(at: t, current: now),
                                caret: now.map { Self.hits[$0] }, hitOpacity: t >= Self.fadesAt ? 0 : 1)
                    .overlay(alignment: .topTrailing) {
                        WelcomeCapsule {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            Text(verbatim: "FF D8 FF").font(.system(size: 11.5, design: .monospaced))
                            Text(verbatim: L("%lld of %lld", (now ?? 0) + 1, Self.hits.count))
                                .foregroundStyle(.secondary)
                        }
                        .offset(x: 16, y: -34)
                    }
                inspector(at: now ?? 0)
                    .padding(.top, 26)
            }
        }
    }

    private func rows(at t: Double, current: Int?) -> [[WelcomeMiniGrid.Cell]] {
        var rows = Self.data.map { $0.map { WelcomeMiniGrid.Cell(byte: $0) } }
        for (k, (r, c)) in Self.hits.enumerated() where t >= 0.4 + 0.15 * Double(k) {
            for j in c..<(c + 3) { rows[r][j].mark = k == current ? .current : .hit }
        }
        return rows
    }

    private func inspector(at hit: Int) -> some View {
        let (r, c) = Self.hits[hit]
        let bytes = Array(Self.data[r][c...]) + Array(Self.data[min(r + 1, Self.data.count - 1)])
        let int32 = Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        let values: [(String, Int64)] = [
            ("Int8", Int64(Int8(bitPattern: bytes[0]))),
            ("UInt16", Int64(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)),
            ("Int32", Int64(int32)),
        ]
        return VStack(alignment: .leading, spacing: 7) {
            Text("Data Inspector")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            ForEach(values.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: values[i].0)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(values[i].1)")
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }
        .padding(12)
        .frame(width: 118, alignment: .leading)
        .welcomeCard()
    }
}

// MARK: - Page 3

/// A disk opened read-only: the sector navigator steps through sectors and the lock stays shut.
struct WelcomeDiskIllustration: View {
    let start: Date

    private static let sectorCount = 16_384
    private static let step = 1.4
    private static let bootSector: [UInt8] = [0xEB, 0x3C, 0x90, 0x4D, 0x53, 0x44, 0x4F, 0x53, 0x35, 0x2E, 0x30, 0x00, 0x02, 0x08, 0x01, 0x00]

    var body: some View {
        WelcomeLoop(start: start, cycle: 6 * Self.step, times: (0..<6).map { Double($0) * Self.step }, still: 0) { t in
            card(sector: min(Int(t / Self.step), 5))
        }
    }

    private func bytes(sector: Int) -> [UInt8] {
        sector == 0 ? Self.bootSector : (0..<16).map { UInt8(truncatingIfNeeded: welcomeScramble(sector, $0, 3)) }
    }

    private func card(sector: Int) -> some View {
        let data = bytes(sector: sector)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, height: 52)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.green))
                        .offset(x: 6, y: 6)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "disk4 — HEXER")
                        .font(.system(size: 14, weight: .semibold))
                    Text(verbatim: "8.4 MB · " + L("Read-only"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                WelcomeCapsule(tint: .accentColor) { Text("Read-only") }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<2, id: \.self) { r in
                    HStack(spacing: 0) {
                        Text(verbatim: String(format: "%08X", sector * 512 + r * 8))
                            .foregroundStyle(Color(nsColor: HexTheme.offset))
                            .frame(width: 74, alignment: .leading)
                        ForEach(0..<8, id: \.self) { c in
                            Text(verbatim: welcomeHex(data[r * 8 + c]))
                                .foregroundStyle(c % 2 == 1 ? Color(nsColor: HexTheme.oddColumn) : .primary)
                                .frame(width: 23)
                        }
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .padding(16)
        .frame(width: 400)
        .welcomeCard()
        .overlay(alignment: .bottom) { navigator(sector: sector).offset(y: 22) }
        .padding(.bottom, 20)
    }

    private func navigator(sector: Int) -> some View {
        WelcomeCapsule {
            Image(systemName: "backward.end")
            Image(systemName: "chevron.left")
            Text("Sector").foregroundStyle(.secondary)
            Text(verbatim: "\(sector)")
                .font(.system(size: 11.5).monospacedDigit())
                .frame(minWidth: 36)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.5), in: .capsule)
            Text(verbatim: L("of %@", Self.sectorCount.formatted())).foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
            Image(systemName: "forward.end")
        }
    }
}

