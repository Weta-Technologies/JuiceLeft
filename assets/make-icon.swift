// Renders the JuiceLeft app icon: `swift assets/make-icon.swift`
// Writes assets/icon-1024.png, assets/icon-512.png and assets/AppIcon.icns (via iconutil).
// A battery seen from the front on deep teal, its charge running lime to amber, with three forecast arcs
// sweeping out of the terminal — the "cast" in JuiceLeft.
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

/// The icon on Apple's grid: 824 pt body centred on a 1024 canvas, soft shadow.
func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    ctx.scaleBy(x: s, y: s)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: srgb(0x000000, 0.32))
    ctx.addPath(shape); ctx.setFillColor(srgb(0x0B2F33)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // Deep teal, lighter at the top, with a soft glow behind the battery.
    ctx.drawLinearGradient(gradient([(0, srgb(0x1C7A73)), (0.55, srgb(0x0E4F4E)), (1, srgb(0x082C36))]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.drawRadialGradient(gradient([(0, srgb(0x9BE36A, 0.28)), (1, srgb(0x9BE36A, 0))]),
                           startCenter: CGPoint(x: 470, y: 512), startRadius: 0, endCenter: CGPoint(x: 470, y: 512), endRadius: 430, options: [])

    // The battery: a rounded body 560 × 300 with a terminal on the right, stroked in cream.
    let batt = CGRect(x: 172, y: 362, width: 560, height: 300)
    let stroke: CGFloat = 40
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: srgb(0xB7F06A, 0.35))
    ctx.setStrokeColor(srgb(0xF4F7EE)); ctx.setLineWidth(stroke)
    ctx.addPath(CGPath(roundedRect: batt, cornerWidth: 64, cornerHeight: 64, transform: nil)); ctx.strokePath()
    ctx.setFillColor(srgb(0xF4F7EE))
    ctx.addPath(CGPath(roundedRect: CGRect(x: batt.maxX + 28, y: 462, width: 46, height: 100), cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.fillPath()
    ctx.restoreGState()

    // The charge: lime to amber, about two thirds full, with a glossy top.
    let inner = batt.insetBy(dx: stroke / 2 + 30, dy: stroke / 2 + 30)
    let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width * 0.68, height: inner.height)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 34, cornerHeight: 34, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, srgb(0xB9F26A)), (1, srgb(0xFFC24A))]),
                           start: CGPoint(x: fill.minX, y: fill.midY), end: CGPoint(x: fill.maxX, y: fill.midY), options: [])
    ctx.drawLinearGradient(gradient([(0, srgb(0xFFFFFF, 0.35)), (0.5, srgb(0xFFFFFF, 0)), (1, srgb(0x000000, 0.10))]),
                           start: CGPoint(x: fill.midX, y: fill.maxY), end: CGPoint(x: fill.midX, y: fill.minY), options: [])
    ctx.restoreGState()

    // Three forecast arcs sweeping out of the terminal, fading as they go.
    let origin = CGPoint(x: batt.maxX + 20, y: 512)
    for (i, radius) in [128.0, 200.0, 272.0].enumerated() {
        ctx.setStrokeColor(srgb(0xF4F7EE, [0.9, 0.6, 0.35][i]))
        ctx.setLineWidth(30)
        ctx.addArc(center: origin, radius: radius, startAngle: -.pi / 3.6, endAngle: .pi / 3.6, clockwise: false)
        ctx.strokePath()
    }
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
