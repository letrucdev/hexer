// Renders Hexer's app icon into an .iconset folder: a deep blue squircle with a glassy hex
// grid tile. Usage: swift Scripts/make_icon.swift Resources/Icon/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Full-bleed squircle on the macOS icon grid (824/1024 body).
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.20, blue: 0.52, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.18, green: 0.52, blue: 1.0, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.03, green: 0.16, blue: 0.45, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Hex digit grid: 4 x 3 cells, one highlighted like a caret.
    let digits = ["4D", "5A", "90", "00", "50", "45", "00", "00", "48", "78", "FF", "C3"]
    let cols = 4, rows = 3
    let gridW = body.width * 0.74, gridH = body.height * 0.48
    let cellW = gridW / CGFloat(cols), cellH = gridH / CGFloat(rows)
    let origin = CGPoint(x: body.midX - gridW / 2, y: body.midY - gridH / 2 - body.height * 0.02)
    let font = NSFont.monospacedSystemFont(ofSize: cellH * 0.56, weight: .semibold)
    for i in 0..<digits.count {
        let c = i % cols, r = rows - 1 - i / cols
        let cell = CGRect(x: origin.x + CGFloat(c) * cellW, y: origin.y + CGFloat(r) * cellH, width: cellW, height: cellH)
        let highlighted = i == 9
        if highlighted {
            let pill = CGPath(roundedRect: cell.insetBy(dx: cellW * 0.06, dy: cellH * 0.1), cornerWidth: cellH * 0.28, cornerHeight: cellH * 0.28, transform: nil)
            ctx.addPath(pill)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.fillPath()
        }
        let color = highlighted ? NSColor(srgbRed: 0.05, green: 0.25, blue: 0.70, alpha: 1)
            : NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.95 : 0.62)
        let str = NSAttributedString(string: digits[i], attributes: [.font: font, .foregroundColor: color])
        let size = str.size()
        str.draw(at: CGPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
    }

    // Glass highlight along the top edge.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.maxY - body.height * 0.42), options: [])
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
    ctx.setLineWidth(max(1, s / 256))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Wrote \(out.path)")
