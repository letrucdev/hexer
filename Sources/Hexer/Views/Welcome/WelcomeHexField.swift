import AppKit
import QuartzCore

/// Hex bytes drifting up behind the welcome tour, faint behind the page. A selection sweeps across
/// now and then, bytes flash as if overwritten (in the editor's modified color), and a ring in the
/// page's color spreads from the middle when the page changes.
///
/// Core Animation draws and moves all of it: the bytes are rendered once into masks and the render
/// server animates the layers, so the field costs the app next to nothing. It sits under the
/// SwiftUI view rather than inside it: hosting an NSView makes SwiftUI draw the content around it
/// on the CPU, every frame of every animation.
final class WelcomeHexFieldView: NSView {
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private static let cell = CGSize(width: 27, height: 21)
    /// Rows before the field repeats: about two minutes at `speed`.
    private static let rows = 32
    /// Points a second.
    private static let speed: CGFloat = 6
    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    private var page: Int?
    private var builtSize = CGSize.zero
    private var columns = 0
    private var tileHeight: CGFloat { CGFloat(Self.rows) * Self.cell.height }
    private var tileWidth: CGFloat { CGFloat(columns) * Self.cell.width }
    /// Where the page's contents sit; the ripple starts there (layer coordinates, y up).
    private var focus: CGPoint { CGPoint(x: bounds.midX, y: bounds.height * 0.55) }
    /// When the scrolling started, shared by every scrolling layer so they stay aligned.
    private var scrollStart: CFTimeInterval = 0

    /// Strips filled with a color through a mask of the bytes or of their boxes; recolored when
    /// the appearance changes.
    private var strips: [(layer: CALayer, color: () -> NSColor)] = []
    private let ripple = CALayer()
    private let rippleRing = CAGradientLayer()
    private var flashes: CALayer?
    private var flashTimer: Timer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func displayOptionsChanged() {
        guard reduceMotion != NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        reduceMotion.toggle()
        rebuild()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { recolor() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            flashTimer?.invalidate()
            flashTimer = nil
        } else {
            rebuild()
        }
    }

    func show(page: Int) {
        guard page != self.page else { return }
        let first = self.page == nil
        self.page = page
        recolor()
        if !first { spreadRipple() }
    }

    private var tint: NSColor { WelcomeView.nsTint(page ?? 0) }

    // MARK: Layers

    private func rebuild() {
        guard let layer, window != nil, bounds.width > 0 else { return }
        builtSize = bounds.size
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        strips = []
        flashTimer?.invalidate()
        columns = Int(bounds.width / Self.cell.width) + 1
        let scale = window?.backingScaleFactor ?? 2
        guard let text = mask(scale: scale, drawing: drawBytes), let boxes = mask(scale: scale, drawing: drawBoxes) else { return }
        scrollStart = CACurrentMediaTime()

        layer.addSublayer(strip(text, color: { Self.ink(0.22, 0.1) }))

        // The sweep: brighter bytes on accent boxes, seen through a diagonal band that crosses
        // the field every half minute or so.
        let sweep = CALayer()
        sweep.frame = bounds
        sweep.addSublayer(strip(boxes, color: { .controlAccentColor.withAlphaComponent(0.16) }))
        sweep.addSublayer(strip(text, color: { Self.ink(0.3, 0.16) }))
        sweep.mask = sweepBand()
        layer.addSublayer(sweep)

        let flashes = scrollingLayer(height: 2 * tileHeight)
        layer.addSublayer(flashes)
        self.flashes = flashes

        // The ripple: boxes in the page's color, seen through a ring that grows from the middle.
        ripple.frame = bounds
        ripple.sublayers?.forEach { $0.removeFromSuperlayer() }
        ripple.addSublayer(strip(boxes, color: { [weak self] in self?.tint.withAlphaComponent(0.34) ?? .clear }))
        ripple.addSublayer(strip(text, color: { Self.ink(0.5, 0.3) }))
        let radius = hypot(bounds.width, bounds.height)
        rippleRing.type = .radial
        rippleRing.frame = CGRect(x: focus.x - radius, y: focus.y - radius, width: 2 * radius, height: 2 * radius)
        rippleRing.startPoint = CGPoint(x: 0.5, y: 0.5)
        rippleRing.endPoint = CGPoint(x: 1, y: 1)
        rippleRing.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        // Where the ring ends up; without model locations the animation has nothing to run between.
        rippleRing.locations = [0.94, 0.99, 1]
        rippleRing.opacity = 0
        ripple.mask = rippleRing
        layer.addSublayer(ripple)

        recolor()
        guard !reduceMotion else { return }
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            // A window that goes away doesn't always tell its views first.
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { flash() }
        }
    }

    /// Draws `drawing` into an image the size of one tile of rows, for use as a mask.
    private func mask(scale: CGFloat, drawing: (CGContext) -> Void) -> CGImage? {
        let size = CGSize(width: tileWidth, height: tileHeight)
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Rows from the top, as in the editor.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawing(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(x: CGFloat(column) * Self.cell.width, y: CGFloat(row) * Self.cell.height,
               width: Self.cell.width, height: Self.cell.height)
    }

    private func drawBytes(_ context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.black]
        let glyphSize = ("00" as NSString).size(withAttributes: attributes)
        for row in 0..<Self.rows {
            for column in 0..<columns {
                let cell = cellRect(row: row, column: column)
                let text = welcomeHex(UInt8(truncatingIfNeeded: welcomeScramble(column, row) >> 16)) as NSString
                text.draw(at: CGPoint(x: cell.midX - glyphSize.width / 2, y: cell.midY - glyphSize.height / 2), withAttributes: attributes)
            }
        }
    }

    private func drawBoxes(_ context: CGContext) {
        context.setFillColor(NSColor.black.cgColor)
        for row in 0..<Self.rows {
            for column in 0..<columns {
                let box = cellRect(row: row, column: column).insetBy(dx: 1.5, dy: 2.5)
                context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
            }
        }
        context.fillPath()
    }

    /// A layer two tiles tall that scrolls up one tile and starts over, seamlessly.
    private func scrollingLayer(height: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.frame = CGRect(x: (bounds.width - tileWidth) / 2, y: bounds.height - height, width: tileWidth, height: height)
        guard !reduceMotion else { return layer }
        let scroll = CABasicAnimation(keyPath: "transform.translation.y")
        scroll.fromValue = 0
        scroll.toValue = tileHeight
        scroll.duration = tileHeight / Self.speed
        scroll.repeatCount = .infinity
        scroll.beginTime = scrollStart
        layer.add(scroll, forKey: "scroll")
        return layer
    }

    /// Two tiles of `image`, one above the other, filled with `color`.
    private func strip(_ image: CGImage, color: @escaping () -> NSColor) -> CALayer {
        let strip = scrollingLayer(height: 2 * tileHeight)
        let mask = CALayer()
        mask.frame = strip.bounds
        for i in 0..<2 {
            let tile = CALayer()
            tile.contents = image
            tile.contentsGravity = .resize
            tile.frame = CGRect(x: 0, y: CGFloat(i) * tileHeight, width: tileWidth, height: tileHeight)
            mask.addSublayer(tile)
        }
        strip.mask = mask
        strips.append((strip, color))
        return strip
    }

    private func sweepBand() -> CALayer {
        let band = CAGradientLayer()
        let size = 2.4 * max(bounds.width, bounds.height)
        band.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        // From the top left to the bottom right, so the band runs from bottom left to top right.
        band.startPoint = CGPoint(x: 0, y: 1)
        band.endPoint = CGPoint(x: 1, y: 0)
        band.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        band.locations = [0.47, 0.5, 0.53]
        let from = CGPoint(x: -size / 2 + bounds.width * 0.2, y: size / 2 + bounds.height * 0.8)
        let to = CGPoint(x: size / 2 + bounds.width * 0.8, y: -size / 2 + bounds.height * 0.2)
        band.position = from
        guard !reduceMotion else { return band }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = [from, from, to].map { NSValue(point: $0) }
        move.keyTimes = [0, 0.3, 1]
        move.duration = 26
        move.repeatCount = .infinity
        band.add(move, forKey: "sweep")
        return band
    }

    private func spreadRipple() {
        guard !reduceMotion, ripple.mask != nil else { return }
        let grow = CABasicAnimation(keyPath: "locations")
        grow.fromValue = [0, 0.01, 0.06]
        grow.toValue = [0.94, 0.99, 1]
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let ring = CAAnimationGroup()
        ring.animations = [grow, fade]
        ring.duration = hypot(bounds.width, bounds.height) / 620
        rippleRing.add(ring, forKey: "ripple")
    }

    /// A random byte, outside the page's contents, flashes as if overwritten.
    private func flash() {
        guard let flashes, window?.occlusionState.contains(.visible) == true else { return }
        let point = CGPoint(x: .random(in: 0..<bounds.width), y: .random(in: 0..<bounds.height))
        let dx = (point.x - focus.x) / (bounds.width * 0.37), dy = (point.y - focus.y) / (bounds.height * 0.4)
        guard (dx * dx + dy * dy).squareRoot() > 1, point.y > 80 else { return }
        // Where that point is in the scrolling layer now, snapped to a cell.
        let elapsed = CACurrentMediaTime() - scrollStart
        let offset = CGFloat(elapsed * Double(Self.speed)).truncatingRemainder(dividingBy: tileHeight)
        let local = CGPoint(x: point.x - flashes.frame.minX, y: point.y - flashes.frame.minY - offset)
        let column = Int(local.x / Self.cell.width)
        let rowFromTop = Int((flashes.bounds.height - local.y) / Self.cell.height)
        guard column >= 0, column < columns, rowFromTop >= 0 else { return }
        let frame = CGRect(x: CGFloat(column) * Self.cell.width, y: flashes.bounds.height - CGFloat(rowFromTop + 1) * Self.cell.height,
                           width: Self.cell.width, height: Self.cell.height).insetBy(dx: 1.5, dy: 2.5)

        let box = CALayer()
        box.frame = frame
        box.cornerRadius = 4
        let text = CATextLayer()
        text.frame = box.bounds.offsetBy(dx: 0, dy: -1.5)
        text.string = welcomeHex(.random(in: 0...255))
        text.font = Self.font
        text.fontSize = Self.font.pointSize
        text.alignmentMode = .center
        text.contentsScale = window?.backingScaleFactor ?? 2
        box.addSublayer(text)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Opaque, so the byte it replaces doesn't show through.
            box.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.22, of: HexTheme.modified)?.cgColor
            text.foregroundColor = HexTheme.modified.cgColor
        }
        box.opacity = 0
        flashes.addSublayer(box)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.45, 1]
        fade.duration = 1.6
        CATransaction.begin()
        CATransaction.setCompletionBlock { box.removeFromSuperlayer() }
        box.add(fade, forKey: "flash")
        CATransaction.commit()
    }

    // MARK: Colors

    /// The bytes' color: light text on a dark window stands out more than dark text on a light one.
    private static func ink(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        .dynamic(light: .black.withAlphaComponent(light), dark: .white.withAlphaComponent(dark))
    }

    private func recolor() {
        // The SwiftUI veil over the field is this color; the window's own background may differ.
        layer.map { recolor($0, .windowBackgroundColor) }
        for (layer, color) in strips { recolor(layer, color()) }
    }

    private func recolor(_ layer: CALayer, _ color: NSColor) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = color.cgColor
            CATransaction.commit()
        }
    }
}
