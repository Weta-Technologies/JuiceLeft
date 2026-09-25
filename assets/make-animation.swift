// Renders assets/menubar-animation.gif and docs/assets/menubar-animation.gif from the real menu-bar item:
//   swiftc -O -target arm64-apple-macosx13.0 -o build/make-animation MenuIcon.swift Alerts.swift assets/make-animation.swift && build/make-animation
// The cycle: on battery with the time left → the level falls → the red pulse below the warning level (the engine's
// own 1 Hz cosine at 4 fps) → the charger goes in → press-and-hold turns monitoring off → back on. Each frame is
// drawn as macOS would: the template item tinted on a light and a dark 2x menu bar beside a system glyph and the
// clock, and the same item large beneath it.
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct MakeAnimation {
    static func main() { MainActor.assumeIsolated { render() } }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    struct Beat { let frame: MenuIcon.Frame, delay: Double, caption: String }

    @MainActor static func cycle() -> [Beat] {
        var beats: [Beat] = []
        func hold(_ f: MenuIcon.Frame, _ seconds: Double, _ caption: String) { beats.append(Beat(frame: f, delay: seconds, caption: caption)) }
        hold(MenuIcon.Frame(level: 84, percent: "84%", trailing: "2 Hours 10 Min Remaining"), 1.6, "On battery: the time to flat, from JuiceLeft's forecast")
        for (level, words) in [(72, "1 Hour 50 Min Remaining"), (58, "1 Hour 30 Min Remaining"), (44, "1 Hour 5 Min Remaining"), (31, "50 Min Remaining"), (22, "35 Min Remaining")] {
            hold(MenuIcon.Frame(level: level, percent: "\(level)%", trailing: words), 0.45, "The level falls, the forecast follows")
        }
        // The red pulse: the engine's own timing, two cycles.
        let steps = Int(2 * MenuIcon.fps / MenuIcon.pulseHz)
        for i in 0..<steps {
            let phase = 2 * .pi * MenuIcon.pulseHz / MenuIcon.fps * Double(i)
            let red = MenuIcon.dimmest + (1 - MenuIcon.dimmest) * CGFloat(1 + cos(phase)) / 2
            hold(MenuIcon.Frame(level: 18, percent: "18%", trailing: "30 Min Remaining", red: red), 1 / MenuIcon.fps, "Below the warning level (20 %): it pulses red until you plug in")
        }
        hold(MenuIcon.Frame(level: 18, plugged: true, percent: "18%", trailing: "1 Hour 45 Min Until Full"), 1.6, "Charger in: the bolt, and the time until full")
        hold(MenuIcon.Frame(level: 84, armed: false, percent: "84%", trailing: "2 Hours 10 Min Remaining"), 1.6, "Press and hold the item: monitoring off")
        hold(MenuIcon.Frame(level: 84, percent: "84%", trailing: "2 Hours 10 Min Remaining"), 1.0, "Press and hold again: monitoring on")
        return beats
    }

    /// A `w`×`h` point bitmap at `scale` with an AppKit context installed.
    static func bitmap(_ w: Int, _ h: Int, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(CGFloat(w) * scale), height: Int(CGFloat(h) * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// What macOS does with a template image: keep its alpha, replace its colour. A coloured (red) image is left alone.
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))!
    }

    /// A 360 pt mock menu bar, drawn in place: the item, a system glyph and the clock.
    static func menuBar(_ item: NSImage, dark: Bool, at origin: NSPoint) {
        let ink = NSColor(white: dark ? 1 : 0, alpha: 0.85)
        var x = origin.x + 12
        for image in [item, symbol("wifi")] {
            tinted(image, ink).draw(in: NSRect(x: x.rounded(), y: origin.y + ((24 - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height))
            x += image.size.width + 14
        }
        NSAttributedString(string: "Thu 9:41 AM", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink]).draw(at: NSPoint(x: x + 2, y: origin.y + 4))
    }

    @MainActor static func render() {
        let beats = cycle()
        var frames: [CGImage] = []
        for beat in beats {
            let item = MenuIcon.draw(beat.frame)
            frames.append(bitmap(720, 250, scale: 2) { ctx in   // 2x, so the item is as crisp as on a Retina menu bar
                for (i, dark) in [false, true].enumerated() {
                    let x0 = CGFloat(i) * 360, ink = NSColor(white: dark ? 1 : 0, alpha: 0.85)
                    NSColor(white: dark ? 0.17 : 0.925, alpha: 1).set()
                    NSRect(x: x0, y: 0, width: 360, height: 250).fill()
                    NSColor(white: dark ? 0.13 : 0.885, alpha: 1).set()
                    NSRect(x: x0, y: 226, width: 360, height: 24).fill()
                    menuBar(item, dark: dark, at: NSPoint(x: x0, y: 226))
                    // The same item, large.
                    let big = tinted(item, ink), scale: CGFloat = 1.55
                    let w = item.size.width * scale, h = item.size.height * scale
                    ctx.saveGState()
                    ctx.interpolationQuality = .high
                    big.draw(in: NSRect(x: x0 + 180 - w / 2, y: 116, width: w, height: h))
                    ctx.restoreGState()
                    let caption = NSAttributedString(string: beat.caption, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink])
                    let lines = caption.boundingRect(with: NSSize(width: 330, height: 60), options: [.usesLineFragmentOrigin])
                    caption.draw(with: NSRect(x: x0 + 180 - 165, y: 92 - lines.height, width: 330, height: lines.height), options: [.usesLineFragmentOrigin])
                    let sub = NSAttributedString(string: dark ? "Dark menu bar" : "Light menu bar", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink.withAlphaComponent(0.5)])
                    sub.draw(at: NSPoint(x: x0 + 180 - sub.size().width / 2, y: 30))
                }
            })
        }
        for path in ["assets/menubar-animation.gif", "docs/assets/menubar-animation.gif"] {
            let url = root.appendingPathComponent(path)
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for (frame, beat) in zip(frames, beats) {
                CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: beat.delay, kCGImagePropertyGIFUnclampedDelayTime: beat.delay]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(dest), "couldn't write \(url.path)")
            print("wrote \(path): \(frames.count) frames, \(String(format: "%.1f", beats.map(\.delay).reduce(0, +))) s")
        }
    }
}
