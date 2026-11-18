// Renders the DMG window background: pale paper, a trace along the bottom (rails, and one line crossing them), and
// where to drag the app. Light, because Finder draws the icon labels in dark text over a custom background.
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
let paper = CGGradient(colorsSpace: cs, colors: [hex(0xF8F8FC), hex(0xEFEFF6)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// The trace, as on the app icon, kept below the icon labels: three rails and the line that crosses them.
let rails: [CGFloat] = [100, 68, 36]
for (i, y) in rails.enumerated() {
    ctx.setStrokeColor(hex([0x5F45E0, 0x2C6BD0, 0x0E8C99][i], 0.3)); ctx.setLineWidth(1); ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [1, 6])
    ctx.move(to: CGPoint(x: 36, y: y)); ctx.addLine(to: CGPoint(x: W - 36, y: y)); ctx.strokePath()
}
ctx.setLineDash(phase: 0, lengths: [])
func run(_ from: CGPoint, _ to: CGPoint, bend: CGFloat, _ color: UInt32) {
    // Along the rail, then an S-curve over to the next one.
    let p = CGMutablePath()
    p.move(to: from)
    p.addLine(to: CGPoint(x: bend, y: from.y))
    p.addCurve(to: CGPoint(x: bend + 44, y: to.y), control1: CGPoint(x: bend + 22, y: from.y), control2: CGPoint(x: bend + 22, y: to.y))
    p.addLine(to: to)
    for (width, alpha) in [(9.0, 0.10), (2.6, 1.0)] {
        ctx.addPath(p); ctx.setStrokeColor(hex(color, alpha)); ctx.setLineWidth(width); ctx.setLineJoin(.round); ctx.strokePath()
    }
}
run(CGPoint(x: 60, y: rails[0]), CGPoint(x: 250, y: rails[1]), bend: 150, 0x5F45E0)
run(CGPoint(x: 250, y: rails[1]), CGPoint(x: 420, y: rails[2]), bend: 300, 0x0C8A5E)
run(CGPoint(x: 420, y: rails[2]), CGPoint(x: 580, y: rails[0]), bend: 470, 0xB87400)
for (x, y, c) in [(60.0, rails[0], 0x5F45E0), (250.0, rails[1], 0x0C8A5E), (420.0, rails[2], 0xB87400)] as [(CGFloat, CGFloat, UInt32)] {
    let dot = CGRect(x: x - 4.5, y: y - 4.5, width: 9, height: 9)
    ctx.setFillColor(hex(0xF4F4FA)); ctx.fillEllipse(in: dot)
    ctx.setStrokeColor(hex(c)); ctx.setLineWidth(2.2); ctx.strokeEllipse(in: dot)
}
ctx.setFillColor(hex(0xB87400)); ctx.fillEllipse(in: CGRect(x: 580 - 6, y: rails[0] - 6, width: 12, height: 12))

// The way in: a slim arrow between the app and Applications.
ctx.setStrokeColor(hex(0x8E9AAD)); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 268, y: 214)); ctx.addLine(to: CGPoint(x: 372, y: 214)); ctx.strokePath()
ctx.move(to: CGPoint(x: 360, y: 224)); ctx.addLine(to: CGPoint(x: 373, y: 214)); ctx.addLine(to: CGPoint(x: 360, y: 204)); ctx.strokePath()

func centered(_ s: String, font: NSFont, color: NSColor, y: CGFloat) {
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    str.draw(at: NSPoint(x: (W - str.size().width) / 2, y: y))
}
centered("Drag Tracer into Applications", font: .systemFont(ofSize: 21, weight: .semibold), color: NSColor(srgbRed: 0.09, green: 0.12, blue: 0.17, alpha: 1), y: 336)
centered("Then open it. It helps you set up the GitHub CLI and Claude Code.", font: .systemFont(ofSize: 12),
         color: NSColor(srgbRed: 0.36, green: 0.40, blue: 0.46, alpha: 1), y: 314)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
