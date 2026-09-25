import AppKit

/// The menu-bar item, drawn as one image so it lays out exactly like Apple's battery item: optional time-left text,
/// the percent, then the battery glyph — a 22 × 12 pt body with a 1 pt outline at half strength, the charge inset
/// 2 pt, a rounded terminal, and the charging bolt cut out of the charge with a halo. Text is the 12 pt system
/// font Apple uses there. Below the warning level the whole item pulses red — a 1 Hz cosine between full and 50 %
/// red, four frames a second, as a coloured (non-template) image so it reads on light and dark menu bars alike;
/// Reduce Motion gets a steady red. Monitoring off dims the item and puts a slash through the glyph. Nothing is
/// drawn while nothing changes, and the pulse pauses while the screens sleep.
@MainActor final class MenuIcon: ObservableObject {
    struct Frame: Equatable {
        var level: Int              // 0…100
        var plugged = false         // on the charger: bolt
        var armed = true            // monitoring on; off = dimmed with a slash
        var missing = false         // no battery
        var percent: String?        // "84%", to the left of the glyph
        var trailing: String?       // "2 Hours 10 Min Remaining" / "2:10", to the right of the glyph
        var red: CGFloat = 0        // 0 = the ordinary template image; > 0 = red at this alpha
    }

    @Published private(set) var frame = Frame(level: 100)
    @Published private(set) var image = MenuIcon.draw(Frame(level: 100))
    private var wanted = Frame(level: 100)
    private var flashing = false
    private var phase = 0.0
    private var timer: Timer?
    private var screensAsleep = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    static let pulseHz = 1.0
    static let fps = 4.0                  // ponytail: 4 frames a second keeps the pulse under 1 % CPU; it is a pulse, not a strobe
    static let dimmest: CGFloat = 0.5     // the dim half of the pulse still reads on a light menu bar

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.screensAsleep = asleep; self.run() }
            }
        }
        center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.run()
            }
        }
    }

    func show(_ frame: Frame, phase: Alerts.Phase) {
        var f = frame
        f.red = 0
        let flashing = phase != .clear
        guard f != wanted || flashing != self.flashing else { return }
        wanted = f
        self.flashing = flashing
        run()
    }

    private func run() {
        if !flashing || reduceMotion || screensAsleep {
            timer?.invalidate()
            timer = nil
            var f = wanted
            f.red = flashing ? 1 : 0
            render(f)
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 1 / Self.fps, repeats: true) { _ in MainActor.assumeIsolated { self.step() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            phase = 0
        }
        step()
    }

    private func step() {
        var f = wanted
        f.red = Self.dimmest + (1 - Self.dimmest) * CGFloat(1 + cos(phase)) / 2
        phase = (phase + 2 * .pi * Self.pulseHz / Self.fps).truncatingRemainder(dividingBy: 2 * .pi)
        render(f)
    }

    private func render(_ f: Frame) {
        guard f != frame else { return }
        frame = f
        image = Self.draw(f)
    }

    // MARK: Drawing

    /// Apple's geometry, in points.
    static let body = NSRect(x: 0, y: 0, width: 22, height: 12)
    static let outlineWidth: CGFloat = 1, outlineAlpha: CGFloat = 0.5, outerRadius: CGFloat = 2.5
    static let chargeInset: CGFloat = 2, chargeRadius: CGFloat = 1.25
    static let terminal = NSRect(x: 23, y: 4, width: 1.5, height: 4)
    static let glyphWidth: CGFloat = 24.5
    static let height: CGFloat = 22           // the image; the status bar centres it
    static let font = NSFont.systemFont(ofSize: 12)
    static let textKern: CGFloat = 0          // tracking across the text
    static let textStroke: CGFloat = -2.5     // fill + stroke, as a percent of the size: the stem darkening Apple's rendering has
    static let textGap: CGFloat = 3.5         // from the percent's advance to the glyph
    static let trailingGap: CGFloat = 6       // from the glyph's terminal to the time
    static let baseline: CGFloat = 1          // the text's baseline above the glyph's bottom edge
    static let percentKern: CGFloat = -1.3    // Apple's % sits a touch tighter than SF's default

    /// The bolt, on the body's coordinates: a lightning flash the full height of the glyph.
    static let bolt: NSBezierPath = {   // traced from Apple's item at 2x: blunt tips, a near-vertical upper arm
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 12.0, y: 12.0))
        p.line(to: NSPoint(x: 12.8, y: 12.0))
        p.line(to: NSPoint(x: 11.9, y: 7.3))
        p.line(to: NSPoint(x: 15.0, y: 6.7))
        p.line(to: NSPoint(x: 10.0, y: 0.0))
        p.line(to: NSPoint(x: 9.0, y: 0.0))
        p.line(to: NSPoint(x: 10.0, y: 4.9))
        p.line(to: NSPoint(x: 7.0, y: 5.6))
        p.close()
        return p
    }()

    static func attributed(_ s: String, kernBeforePercent: Bool = false) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .kern: textKern]
        if textStroke != 0 { attributes[.strokeWidth] = textStroke; attributes[.strokeColor] = NSColor.black }
        let a = NSMutableAttributedString(string: s, attributes: attributes)
        if kernBeforePercent, s.hasSuffix("%"), s.count >= 2 {
            a.addAttribute(.kern, value: percentKern + textKern, range: NSRange(location: s.count - 2, length: 1))
        }
        return a
    }

    /// The whole item: percent, glyph, time. Template unless red.
    static func draw(_ f: Frame) -> NSImage {
        let percent = f.percent.map { attributed($0, kernBeforePercent: true) }, trailing = f.trailing.map { attributed($0) }
        let percentX: CGFloat = 0
        let glyphX = percent.map { round($0.size().width + textGap) } ?? 0
        let trailingX = glyphX + glyphWidth + trailingGap
        let width = trailing.map { ceil(trailingX + $0.size().width) } ?? glyphX + glyphWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let color = f.red > 0 ? NSColor.systemRed.withAlphaComponent(f.red) : NSColor.black
            let dim: CGFloat = f.armed ? 1 : 0.5
            let paint = { (alpha: CGFloat) in color.withAlphaComponent(color.alphaComponent * alpha * dim).set() }
            let glyphY = (height - body.height) / 2
            let textY = glyphY + baseline + font.descender   // draw(at:) takes the line box's bottom-left; the descender is negative
            for (text, tx) in [(percent, percentX), (trailing, trailingX)] {
                guard let text else { continue }
                let t = NSMutableAttributedString(attributedString: text)
                t.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * dim), range: NSRange(location: 0, length: t.length))
                t.draw(at: NSPoint(x: tx, y: textY))
            }
            NSGraphicsContext.saveGraphicsState()
            let shift = NSAffineTransform()
            shift.translateX(by: glyphX, yBy: glyphY)
            shift.concat()
            drawGlyph(f, paint: paint)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = f.red == 0
        return image
    }

    /// The glyph alone, at `side` points, for the panel header.
    static func glyph(_ f: Frame, side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let color = NSColor.black
            let dim: CGFloat = f.armed ? 1 : 0.5
            let paint = { (alpha: CGFloat) in color.withAlphaComponent(alpha * dim).set() }
            let scale = side / 26
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: scale * 0.5, yBy: (side - body.height * scale) / 2)
            t.scale(by: scale)
            t.concat()
            drawGlyph(f, paint: paint)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The battery on its own coordinates (body at the origin), painted with `paint(alpha)`.
    private static func drawGlyph(_ f: Frame, paint: (CGFloat) -> Void) {
        let ring = NSBezierPath(roundedRect: body, xRadius: outerRadius, yRadius: outerRadius)
        ring.append(NSBezierPath(roundedRect: body.insetBy(dx: outlineWidth, dy: outlineWidth), xRadius: outerRadius - outlineWidth, yRadius: outerRadius - outlineWidth).reversed)
        paint(outlineAlpha)
        ring.fill()
        NSBezierPath(roundedRect: terminal, xRadius: terminal.width / 2, yRadius: terminal.width / 2).fill()

        let inner = body.insetBy(dx: chargeInset, dy: chargeInset)
        paint(1)
        if f.missing {
            NSBezierPath(rect: NSRect(x: inner.midX - 3, y: inner.midY - 0.5, width: 6, height: 1)).fill()
        } else if f.level > 0 {
            let width = max(inner.width * CGFloat(min(f.level, 100)) / 100, 1.5)
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: width, height: inner.height), xRadius: chargeRadius, yRadius: chargeRadius).fill()
        }
        if f.plugged, !f.missing {
            knockout(bolt, width: 2)
            paint(1)
            bolt.fill()
        }
        if !f.armed {   // monitoring off: a slash through the glyph, with its own halo
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 5, y: -1))
            slash.line(to: NSPoint(x: 17, y: 13))
            knockout(slash, width: 3.5)
            paint(2)   // full strength despite the dimming
            slash.lineWidth = 1.5
            slash.lineCapStyle = .round
            slash.stroke()
        }
    }

    /// Clears a halo around `path`, so what is drawn on top stays legible over the charge.
    private static func knockout(_ path: NSBezierPath, width: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
