// Draws the Installer window background (620×418 pt, drawn @2x) in the JuiceLeft teal: the app icon over a lime glow
// in the bottom-left corner, behind Installer's step list, with the icon's charge bar under it; everything else is
// clear, so the panes read as usual. One file per appearance — the step list's text is dark on light and light on
// dark, so is ours.
// Used by make-pkg.sh:  make-pkg-background <icon.png> <out-dir>  →  <out-dir>/background.png, <out-dir>/background-dark.png
import AppKit

let icon = NSImage(contentsOfFile: CommandLine.arguments[1])!, outDir = CommandLine.arguments[2]
let size = NSSize(width: 620, height: 418)
let centreX: CGFloat = 96   // the middle of Installer's step list

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
let cream = hex(0xF6F8EF), lime = hex(0xB9F26A), teal = hex(0x0E4F4E)

func rounded(_ pointSize: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: pointSize, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? base
}

func text(_ string: String, _ font: NSFont, _ color: NSColor, centreX: CGFloat, y: CGFloat) {
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    attributed.draw(at: NSPoint(x: centreX - attributed.size().width / 2, y: y))
}

func draw(dark: Bool) {
    // The lime glow behind the icon: brighter on dark, a soft wash on light.
    let glow = NSPoint(x: centreX, y: 128)
    NSGradient(starting: lime.withAlphaComponent(dark ? 0.30 : 0.22), ending: lime.withAlphaComponent(0))!
        .draw(fromCenter: glow, radius: 0, toCenter: glow, radius: 165, options: [])
    // The charge bar from the icon: lime → amber → red, under the icon.
    NSGradient(colorsAndLocations: (lime, 0.0), (hex(0xFFB23E), 0.7), (hex(0xFF5A4E), 1.0))!
        .draw(in: NSRect(x: 30, y: 66, width: 132, height: 3), angle: 0)
    // A few bubbles rising past the icon (light ones on dark, teal ones on light).
    for (x, y, r) in [(26.0, 150.0, 2.0), (172, 120, 2.5), (40, 200, 1.5), (166, 196, 1.5), (156, 84, 1.2)] as [(CGFloat, CGFloat, CGFloat)] {
        (dark ? hex(0xFFFFFF, 0.14) : teal.withAlphaComponent(0.12)).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
    }
    // The app icon, with a soft shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.25)
    shadow.shadowBlurRadius = 10
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    shadow.set()
    icon.draw(in: NSRect(x: centreX - 54, y: 74, width: 108, height: 108), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    text("JuiceLeft", rounded(17, .semibold), dark ? cream : teal, centreX: centreX, y: 42)
    text("by CyborgFingers", rounded(11, .medium), (dark ? cream : teal).withAlphaComponent(0.7), centreX: centreX, y: 26)
}

for dark in [false, true] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size   // points: the PNG carries 144 dpi, and Installer scales it to the window anyway
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(dark: dark)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(dark ? "background-dark.png" : "background.png"))
}
