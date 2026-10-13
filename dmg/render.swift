// Renders the DMG window background: pale water, Fathom's strata along the bottom, and where to drag the app.
// Light, because Finder draws the icon labels in dark text over a custom background.
// usage: render <out.png>
import AppKit

let out = CommandLine.arguments[1]
let W: CGFloat = 640, H: CGFloat = 400
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}

// Coordinates are y-up. Finder centres the icons 190 pt from the top, so 210 from the bottom.
let water = CGGradient(colorsSpace: cs, colors: [hex(0xF8FAFC), hex(0xEEF3F8)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(water, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// Strata, as on the app icon, kept below the icon labels.
let hues: [UInt32] = [0x62E6DC, 0x5BB4F2, 0x7F8CF6, 0xA68AF2]
for (i, top) in [104.0, 80.0, 56.0, 32.0].enumerated() {
    let edge = CGMutablePath()
    var x: CGFloat = -10
    edge.move(to: CGPoint(x: x, y: top + 6 * sin(x / 150 + CGFloat(i) * 1.3)))
    while x <= W + 10 {
        x += 6
        edge.addLine(to: CGPoint(x: x, y: top + (6 - CGFloat(i)) * sin(x / 150 + CGFloat(i) * 1.3)))
    }
    let fill = edge.mutableCopy()!
    fill.addLine(to: CGPoint(x: W + 10, y: -10)); fill.addLine(to: CGPoint(x: -10, y: -10)); fill.closeSubpath()
    ctx.saveGState()
    ctx.addPath(fill); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [hex(hues[i], 0.16), hex(hues[i], 0.03)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top + 8), end: CGPoint(x: 0, y: top - 60), options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.addPath(edge)
    ctx.setStrokeColor(hex(hues[i], 0.55)); ctx.setLineWidth(1.2); ctx.strokePath()
}

// The way in: a slim arrow between the app and Applications.
ctx.setStrokeColor(hex(0x8E9AAD)); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 268, y: 214)); ctx.addLine(to: CGPoint(x: 372, y: 214)); ctx.strokePath()
ctx.move(to: CGPoint(x: 360, y: 224)); ctx.addLine(to: CGPoint(x: 373, y: 214)); ctx.addLine(to: CGPoint(x: 360, y: 204)); ctx.strokePath()

func centered(_ s: String, font: NSFont, color: NSColor, y: CGFloat) {
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    str.draw(at: NSPoint(x: (W - str.size().width) / 2, y: y))
}
let serif = NSFont.systemFont(ofSize: 22, weight: .regular).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 22) }
    ?? .systemFont(ofSize: 22)
centered("Drag Fathom into Applications", font: serif, color: NSColor(srgbRed: 0.09, green: 0.12, blue: 0.17, alpha: 1), y: 336)
centered("Then open it. It helps you set up the GitHub CLI and Claude Code.", font: .systemFont(ofSize: 12),
         color: NSColor(srgbRed: 0.36, green: 0.40, blue: 0.46, alpha: 1), y: 314)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
