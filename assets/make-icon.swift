// Renders the JuiceLeft app icon: `swift assets/make-icon.swift`
// Writes assets/icon-1024.png, assets/icon-512.png and assets/AppIcon.icns (via iconutil).
// The menu-bar glyph's battery (same 14 × 8 proportions and corner radius) seen large on deep teal, filled with
// juice — lime to amber — that sloshes at the level line and throws a drop off the crest.
import AppKit

let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func render(_ pixels: Int, _ draw: (CGContext, CGFloat) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(pixels) / 1024)   // everything below is laid out on a 1024 canvas
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "couldn't write \(url.path)")
}

// The palette. Panel.swift's `Brand` uses the same teal, lime and amber.
let tealLight: UInt32 = 0x1C7A73, teal: UInt32 = 0x0E4F4E, tealDeep: UInt32 = 0x082C36
let cream: UInt32 = 0xF6F8EF, lime: UInt32 = 0xB9F26A, sun: UInt32 = 0xF5D84A, amber: UInt32 = 0xFFB23E, orange: UInt32 = 0xFF8F3A

/// The icon on Apple's grid: 824 pt body centred on a 1024 canvas, soft shadow.
func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    ctx.scaleBy(x: s, y: s)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: srgb(0x000000, 0.32))
    ctx.addPath(shape); ctx.setFillColor(srgb(0x0B2F33)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Deep teal, lighter at the top, and a lime glow behind the juice.
    ctx.drawLinearGradient(gradient([(0, srgb(tealLight)), (0.55, srgb(teal)), (1, srgb(tealDeep))]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.drawRadialGradient(gradient([(0, srgb(lime, 0.34)), (1, srgb(lime, 0))]),
                           startCenter: CGPoint(x: 440, y: 512), startRadius: 0, endCenter: CGPoint(x: 440, y: 512), endRadius: 440, options: [])

    // The battery: the glyph's 14 × 8 body with its 2.2 corner, at 588 × 336, stroked in cream; the terminal on the right.
    let batt = CGRect(x: 166, y: 344, width: 588, height: 336)
    let stroke: CGFloat = 40, corner = batt.height * 2.2 / 8
    let inner = batt.insetBy(dx: stroke / 2 + 26, dy: stroke / 2 + 26)
    let innerCorner = corner - stroke / 2 - 26 + 22

    // The well the juice sits in: a shade darker than the ground, with an inner shadow along the top.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerCorner, cornerHeight: innerCorner, transform: nil)); ctx.clip()
    ctx.setFillColor(srgb(tealDeep, 0.35)); ctx.fill(inner)
    ctx.drawLinearGradient(gradient([(0, srgb(0x000000, 0.28)), (1, srgb(0x000000, 0))]),
                           start: CGPoint(x: inner.midX, y: inner.maxY), end: CGPoint(x: inner.midX, y: inner.maxY - 60), options: [])
    ctx.restoreGState()

    // The juice: lime → sun → amber left to right, up to the level line, which sloshes.
    let level: CGFloat = 0.64, edge = inner.minX + inner.width * level
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: edge - 6, y: inner.minY - 30))
    for i in 0...96 {
        let y = inner.minY - 30 + (inner.height + 60) * CGFloat(i) / 96
        let t = (y - inner.minY) / inner.height
        wave.addLine(to: CGPoint(x: edge + 24 * sin(t * 1.25 * 2 * .pi + 0.9) - 10 * t, y: y))
    }
    let liquid = CGMutablePath()
    liquid.addPath(wave)
    liquid.addLine(to: CGPoint(x: inner.minX - 30, y: inner.maxY + 30))
    liquid.addLine(to: CGPoint(x: inner.minX - 30, y: inner.minY - 30))
    liquid.closeSubpath()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerCorner, cornerHeight: innerCorner, transform: nil)); ctx.clip()
    ctx.saveGState()
    ctx.addPath(liquid); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, srgb(lime)), (0.5, srgb(sun)), (1, srgb(amber))]),
                           start: CGPoint(x: inner.minX, y: inner.midY), end: CGPoint(x: edge + 30, y: inner.midY), options: [.drawsAfterEndLocation])
    // Depth: brighter at the top, a warm shade at the bottom.
    ctx.drawLinearGradient(gradient([(0, srgb(0xFFFFFF, 0.45)), (0.35, srgb(0xFFFFFF, 0)), (1, srgb(orange, 0.32))]),
                           start: CGPoint(x: inner.midX, y: inner.maxY), end: CGPoint(x: inner.midX, y: inner.minY), options: [])
    // A gloss strip along the top of the liquid.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: inner.minX + 34, y: inner.maxY - 62, width: edge - inner.minX - 90, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, srgb(0xFFFFFF, 0.55)), (1, srgb(0xFFFFFF, 0.05))]),
                           start: CGPoint(x: inner.minX, y: 0), end: CGPoint(x: edge, y: 0), options: [])
    ctx.restoreGState()
    // Bubbles rising through the amber.
    ctx.setFillColor(srgb(0xFFFFFF, 0.45))
    for (x, y, r) in [(edge - 74, inner.minY + 78, 15.0), (edge - 130, inner.minY + 138, 10.0), (edge - 52, inner.minY + 176, 7.5), (edge - 168, inner.minY + 52, 6.5)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    ctx.restoreGState()
    // The meniscus: a bright edge along the slosh.
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.8)); ctx.setLineWidth(10); ctx.setLineCap(.round)
    ctx.addPath(wave); ctx.strokePath()
    // A drop thrown off the crest.
    let crestY = inner.minY + inner.height * 0.82, crestX = edge + 24 * sin(0.82 * 1.25 * 2 * .pi + 0.9) - 10 * 0.82
    let drop = CGPoint(x: crestX + 58, y: crestY + 20)
    ctx.setFillColor(srgb(sun))
    ctx.fillEllipse(in: CGRect(x: drop.x - 13, y: drop.y - 13, width: 26, height: 26))
    ctx.setFillColor(srgb(0xFFFFFF, 0.55))
    ctx.fillEllipse(in: CGRect(x: drop.x - 9, y: drop.y + 1, width: 8, height: 8))
    ctx.setFillColor(srgb(amber))
    ctx.fillEllipse(in: CGRect(x: drop.x + 26, y: drop.y - 22, width: 12, height: 12))
    ctx.restoreGState()

    // The outline and the terminal, glowing lime.
    ctx.saveGState()
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setShadow(offset: .zero, blur: 32, color: srgb(lime, 0.4))
    ctx.setStrokeColor(srgb(cream)); ctx.setLineWidth(stroke)
    ctx.addPath(CGPath(roundedRect: batt, cornerWidth: corner, cornerHeight: corner, transform: nil)); ctx.strokePath()
    ctx.setFillColor(srgb(cream))
    ctx.addPath(CGPath(roundedRect: CGRect(x: batt.maxX + stroke / 2 + 26, y: batt.midY - 59, width: 50, height: 118), cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()

    // Glass edge highlight.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setLineWidth(4); ctx.setStrokeColor(srgb(0xFFFFFF, 0.14)); ctx.strokePath()
    ctx.restoreGState()
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("JuiceLeftAppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(render(points * scale, drawIcon), iconset.appendingPathComponent(name))
    }
}
writePNG(render(1024, drawIcon), assets.appendingPathComponent("icon-1024.png"))
writePNG(render(512, drawIcon), assets.appendingPathComponent("icon-512.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("Wrote icon-1024.png, icon-512.png, AppIcon.icns")
