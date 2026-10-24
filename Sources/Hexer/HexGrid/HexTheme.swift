import AppKit
import CoreText

extension NSColor {
    /// A color with separate light and dark variants. Nonisolated: SwiftUI resolves colors on its
    /// render thread while animating, and a main-actor provider traps there.
    nonisolated static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Colors of the hex grid, following HxD's scheme (blue offsets, alternating column colors,
/// red modified bytes) adapted to light and dark appearance.
enum HexTheme {
    static let background = NSColor.textBackgroundColor
    static let text = NSColor.textColor
    static let offset = NSColor.dynamic(light: NSColor(hex: 0x0B47B8), dark: NSColor(hex: 0x7CB9FF))
    static let oddColumn = NSColor.dynamic(light: NSColor(hex: 0x7A5652), dark: NSColor(hex: 0xD1AAA3))
    static let modified = NSColor.dynamic(light: NSColor(hex: 0xD70015), dark: NSColor(hex: 0xFF6B63))
    static let undefined = NSColor.tertiaryLabelColor
    /// The capsule of a folded undefined section and its label.
    static let foldBackground = NSColor.quaternarySystemFill
    static let foldText = NSColor.secondaryLabelColor
    static let headerText = NSColor.secondaryLabelColor
    static let headerBackground = NSColor.dynamic(light: NSColor(hex: 0xF7F7F9), dark: NSColor(hex: 0x202023))
    static let separator = NSColor.separatorColor
    static let searchHit = NSColor.dynamic(light: NSColor(hex: 0xFFC400, alpha: 0.42), dark: NSColor(hex: 0xFFD60A, alpha: 0.35))
    static let difference = NSColor.dynamic(light: NSColor(hex: 0xFF9500, alpha: 0.30), dark: NSColor(hex: 0xFF9F0A, alpha: 0.35))
    static let bookmark = NSColor.systemOrange
}

/// Font metrics of the grid.
struct HexMetrics: Equatable {
    let font: NSFont
    let charWidth: CGFloat
    let ascent: CGFloat
    let rowHeight: CGFloat
    let baseline: CGFloat

    init(font: NSFont) {
        self.font = font
        var glyph = CGGlyph(0)
        var zero: UniChar = 0x30
        CTFontGetGlyphsForCharacters(font, &zero, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        charWidth = advance.width
        ascent = font.ascender
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        rowHeight = lineHeight + 5
        baseline = floor((rowHeight - lineHeight) / 2 + font.ascender)
    }
}

/// Maps characters to glyphs of the grid font, falling back to other fonts for characters the
/// monospaced font lacks (e.g. CP437 box drawing) while keeping every cell the same width.
final class GlyphCache {
    struct Entry {
        let fontIndex: Int
        let glyph: CGGlyph
    }

    let font: NSFont
    private(set) var fonts: [CTFont]
    private var cache: [Character: Entry] = [:]

    init(font: NSFont) {
        self.font = font
        fonts = [font as CTFont]
    }

    func entry(for c: Character) -> Entry {
        if let e = cache[c] { return e }
        let utf16 = Array(String(c).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        var e = Entry(fontIndex: 0, glyph: 0)
        if CTFontGetGlyphsForCharacters(font as CTFont, utf16, &glyphs, utf16.count) {
            e = Entry(fontIndex: 0, glyph: glyphs[0])
        } else {
            let fallback = CTFontCreateForString(font as CTFont, String(c) as CFString, CFRange(location: 0, length: utf16.count))
            if CTFontGetGlyphsForCharacters(fallback, utf16, &glyphs, utf16.count) {
                let name = CTFontCopyPostScriptName(fallback) as String
                let index = fonts.firstIndex { (CTFontCopyPostScriptName($0) as String) == name } ?? {
                    fonts.append(fallback)
                    return fonts.count - 1
                }()
                e = Entry(fontIndex: index, glyph: glyphs[0])
            } else {
                e = entry(for: ".")
            }
        }
        cache[c] = e
        return e
    }
}

/// Collects glyphs per (font, color) and draws each batch with one CoreText call.
struct GlyphBatcher {
    private var batches: [Int: (font: Int, color: NSColor, glyphs: [CGGlyph], positions: [CGPoint])] = [:]
    private var colorIndex: [NSColor: Int] = [:]

    /// Adds a glyph whose baseline origin is `p` in the (flipped) view's coordinates.
    mutating func add(_ e: GlyphCache.Entry, at p: CGPoint, color: NSColor) {
        let ci: Int
        if let i = colorIndex[color] { ci = i } else { ci = colorIndex.count; colorIndex[color] = ci }
        let key = e.fontIndex << 16 | ci
        if batches[key] == nil { batches[key] = (e.fontIndex, color, [], []) }
        batches[key]!.glyphs.append(e.glyph)
        // Positions are in text space, which the flipped text matrix below mirrors vertically.
        batches[key]!.positions.append(CGPoint(x: p.x, y: -p.y))
    }

    func draw(in ctx: CGContext, fonts: [CTFont]) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for b in batches.values {
            ctx.setFillColor(b.color.cgColor)
            CTFontDrawGlyphs(fonts[b.font], b.glyphs, b.positions, b.glyphs.count, ctx)
        }
        ctx.restoreGState()
    }
}
