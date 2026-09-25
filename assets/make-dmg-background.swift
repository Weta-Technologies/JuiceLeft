// Draws the DMG window background (640×400 pt, @1x + @2x) in the JuiceLeft teal.
// Used by make-dmg.sh:  make-dmg-background <version> <out-dir>  →  <out-dir>/bg.png, <out-dir>/bg@2x.png
// Finder draws icon labels black in Light mode and white in Dark mode, so the band the labels sit on is a
// mid-tone teal (≈4.5:1 against white, ≈4.5:1 against black) — both stay readable.
import AppKit

let version = CommandLine.arguments[1], outDir = CommandLine.arguments[2]
let size = NSSize(width: 640, height: 400)
let appX: CGFloat = 160, appsX: CGFloat = 480, iconY: CGFloat = 180   // Finder icon centres, from the top

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
let cream = hex(0xF6F8EF), lime = hex(0xB9F26A)

func rounded(_ pointSize: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: pointSize, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? base
}

func text(_ string: String, _ font: NSFont, _ color: NSColor, centreX: CGFloat, top: CGFloat) {
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    let w = attributed.size()
    attributed.draw(at: NSPoint(x: centreX - w.width / 2, y: size.height - top - w.height))
}

func draw() {
    // Teal: light at the top, a mid-tone band where the icons and their labels sit, deep at the bottom.
    NSGradient(colorsAndLocations:
        (hex(0x1C7A73), 0.0), (hex(0x1F6E69), 0.34), (hex(0x2A6F6B), 0.60), (hex(0x1E5F5C), 0.74), (hex(0x114744), 0.88), (hex(0x082C36), 1.0)
    )!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    // The lime glow behind the app icon.
    NSGradient(starting: lime.withAlphaComponent(0.28), ending: lime.withAlphaComponent(0))!
        .draw(fromCenter: NSPoint(x: appX, y: size.height - iconY), radius: 0, toCenter: NSPoint(x: appX, y: size.height - iconY), radius: 150, options: [])
    // The charge bar along the bottom: lime → amber → red.
    NSGradient(colorsAndLocations: (lime, 0.0), (hex(0xFFB23E), 0.7), (hex(0xFF5A4E), 1.0))!
        .draw(in: NSRect(x: 0, y: 0, width: size.width, height: 4), angle: 0)
    // A few bubbles.
    for (x, y, r) in [(560.0, 40.0, 3.0), (600, 92, 2), (520, 120, 2.5), (612, 150, 1.5), (40, 60, 2), (86, 110, 1.5), (300, 30, 1.5)] as [(CGFloat, CGFloat, CGFloat)] {
        hex(0xFFFFFF, 0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: size.height - y - r, width: 2 * r, height: 2 * r)).fill()
    }

    text("Drag JuiceLeft into Applications", rounded(20, .semibold), cream, centreX: size.width / 2, top: 50)

    // Arrow from the app to Applications.
    let y = size.height - iconY
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: appX + 84, y: y))
    arrow.line(to: NSPoint(x: appsX - 88, y: y))
    arrow.move(to: NSPoint(x: appsX - 102, y: y + 12))
    arrow.line(to: NSPoint(x: appsX - 88, y: y))
    arrow.line(to: NSPoint(x: appsX - 102, y: y - 12))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    let glow = NSShadow()
    glow.shadowColor = lime.withAlphaComponent(0.7)
    glow.shadowBlurRadius = 8
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    cream.setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()

    text("JuiceLeft \(version)  ·  by CyborgFingers  ·  github.com/CyborgFingers/JuiceLeft",
         rounded(11, .medium), cream.withAlphaComponent(0.75), centreX: size.width / 2, top: 368)
}

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size   // points, so @2x carries 144 dpi for tiffutil -cathidpicheck
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "bg.png" : "bg@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
