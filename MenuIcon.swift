import AppKit

/// The menu-bar glyph: a battery whose fill tracks the level, a bolt while on the charger, a slash when alerts are
/// off. Below the warning level it pulses red — a 1 Hz cosine between full and 35 % red, four frames a second, drawn
/// as a coloured (non-template) image so it reads the same on light and dark menu bars; Reduce Motion gets a steady
/// red instead. Nothing is drawn while nothing changes, and the pulse pauses while the screens sleep.
@MainActor final class MenuIcon: ObservableObject {
    struct Frame: Equatable {
        var level: Int              // 0…100
        var plugged = false         // on the charger: bolt
        var armed = true            // alerts on; off = dimmed with a slash
        var missing = false         // no battery
        var red: CGFloat = 0        // 0 = the ordinary template glyph; > 0 = red at this alpha
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
    static let dimmest: CGFloat = 0.5   // the dim half of the pulse still reads on a light menu bar

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

    /// `side` points square, laid out on an 18-unit grid; the outline and the fill's edges are snapped to device
    /// pixels so it stays crisp at 1x, 2x and at the panel's larger size. Template unless red.
    static func draw(_ f: Frame, side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.scaleBy(x: side / 18, y: side / 18)
            let s = max(abs(cg.ctm.a), 0.001)                          // device pixels per grid unit
            let px = max(1, s.rounded()) / s                            // outline: 1 px at 1x, 2 px at 2x
            let snap = { (v: CGFloat) in (v * s).rounded() / s }
            let color = f.red > 0 ? NSColor.systemRed.withAlphaComponent(f.red) : NSColor.black
            let paint = { (alpha: CGFloat) in color.withAlphaComponent(color.alphaComponent * alpha).set() }
            let knockout = { (path: NSBezierPath, width: CGFloat) in   // clears a halo, so what is drawn on top stays legible
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                path.lineWidth = width
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                path.stroke()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let dim: CGFloat = f.armed ? 1 : 0.4

            // The body: a ring 14 × 8 on the grid, and the terminal on its right.
            let body = NSRect(x: snap(1), y: snap(5), width: snap(15) - snap(1), height: snap(13) - snap(5))
            let ring = NSBezierPath(roundedRect: body, xRadius: 2.2, yRadius: 2.2)
            ring.append(NSBezierPath(roundedRect: body.insetBy(dx: px, dy: px), xRadius: 2.2 - px, yRadius: 2.2 - px).reversed)
            paint(dim)
            ring.fill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + px / 2, y: snap(7.6), width: snap(17.2) - body.maxX - px / 2, height: snap(10.4) - snap(7.6)),
                         xRadius: 0.7, yRadius: 0.7).fill()

            // The charge, or a dash when there is no battery to read.
            let inner = body.insetBy(dx: px + 0.75, dy: px + 0.75)
            if f.missing {
                NSBezierPath(rect: NSRect(x: snap(5.5), y: snap(8.5), width: snap(10.5) - snap(5.5), height: px)).fill()
            } else if f.level > 0 {
                let width = max(snap(inner.width * CGFloat(min(f.level, 100)) / 100), px)
                NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: width, height: inner.height), xRadius: 0.8, yRadius: 0.8).fill()
            }

            // The bolt, cut out of whatever is under it so it reads at any level.
            if f.plugged, !f.missing {
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 8.9, y: 13.8))
                bolt.line(to: NSPoint(x: 5.2, y: 8.4))
                bolt.line(to: NSPoint(x: 7.9, y: 8.4))
                bolt.line(to: NSPoint(x: 7.1, y: 4.2))
                bolt.line(to: NSPoint(x: 10.8, y: 9.6))
                bolt.line(to: NSPoint(x: 8.1, y: 9.6))
                bolt.close()
                knockout(bolt, 1.7)
                paint(dim)
                bolt.fill()
            }

            // Alerts off: a slash through the dimmed battery, with its own halo.
            if !f.armed {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 15))
                slash.line(to: NSPoint(x: 15, y: 3))
                knockout(slash, 3.2)
                paint(1)
                slash.lineWidth = 1.5
                slash.lineCapStyle = .round
                slash.stroke()
            }
            return true
        }
        image.isTemplate = f.red == 0
        return image
    }
}
