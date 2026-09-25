// Renders assets/banner.png (1280x640, also the GitHub social preview): `swift assets/make-banner.swift`
// Needs assets/icon-1024.png from make-icon.swift.
import AppKit

let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let W = 1280, H = 640

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

func text(_ string: String, _ font: NSFont, _ color: CGColor, at point: CGPoint, tracking: CGFloat = 0) {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: tracking]).draw(at: point)
}

let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

// The icon's teal, lit from the top left, with the lime glow spilling out from behind the icon.
ctx.drawLinearGradient(gradient([(0, srgb(0x1C7A73)), (0.5, srgb(0x0E4F4E)), (1, srgb(0x082C36))]),
                       start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
ctx.drawRadialGradient(gradient([(0, srgb(0xB9F26A, 0.32)), (0.5, srgb(0xB9F26A, 0.08)), (1, srgb(0xB9F26A, 0))]),
                       startCenter: CGPoint(x: 300, y: 320), startRadius: 0, endCenter: CGPoint(x: 300, y: 320), endRadius: 560, options: [])
// Faint bubbles drifting up the right-hand side.
ctx.setFillColor(srgb(0xFFFFFF, 0.10))
for (x, y, r) in [(1180, 560, 10), (1120, 470, 6), (1230, 420, 7), (1060, 590, 4), (1200, 300, 5), (980, 545, 5), (1150, 180, 4), (1245, 120, 6)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
// The charge bar along the very bottom: lime → amber → red, the app's three states.
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: 6))
ctx.drawLinearGradient(gradient([(0, srgb(0xB9F26A)), (0.7, srgb(0xFFB23E)), (1, srgb(0xFF5A4E))]),
                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: 0), options: [])
ctx.restoreGState()

// Icon (already has its own shadow), left of centre.
let icon = NSImage(contentsOf: assets.appendingPathComponent("icon-1024.png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
ctx.draw(icon, in: CGRect(x: 96, y: 108, width: 424, height: 424))

// Wordmark + tagline.
text("JuiceLeft", rounded(132, weight: .bold), srgb(0xFFFFFF), at: CGPoint(x: 536, y: 318), tracking: -3)
text("Know exactly how much juice is left.", rounded(36, weight: .medium), srgb(0xB9F26A), at: CGPoint(x: 544, y: 254))
text("Free battery monitor for the macOS menu bar · by CyborgFingers", rounded(25, weight: .regular), srgb(0xA9D6CF), at: CGPoint(x: 546, y: 206))

let out = assets.appendingPathComponent("banner.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest), "couldn't write banner")
print("Wrote banner.png")
