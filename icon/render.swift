// Renders Fathom's app icon: strata of a deep sea, a sounding line, and a sonar ping at depth.
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}

// Coordinates are y-up (Core Graphics).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: hex(0x020409, 0.5))
ctx.addPath(shape); ctx.setFillColor(hex(0x0A1020)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// Water: lit teal at the surface, indigo at depth.
let water = CGGradient(colorsSpace: cs, colors: [hex(0x15505A), hex(0x0C2734), hex(0x0A1328), hex(0x110D2A)] as CFArray,
                       locations: [0, 0.38, 0.72, 1])!
ctx.drawLinearGradient(water, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

// Surface light.
let light = CGGradient(colorsSpace: cs, colors: [hex(0x7FF0E6, 0.28), hex(0x7FF0E6, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(light, startCenter: CGPoint(x: 512, y: 980), startRadius: 0, endCenter: CGPoint(x: 512, y: 980), endRadius: 560, options: [])

// Strata.
let hues: [UInt32] = [0x62E6DC, 0x5BB4F2, 0x7F8CF6, 0xA68AF2]
func wave(_ y0: CGFloat, _ amp: CGFloat, _ phase: CGFloat) -> CGMutablePath {
    // Runs past both edges so the round caps fall outside the clip.
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 80, y: y0 + amp * sin(-20 / 824 * .pi * 2 + phase)))
    var x: CGFloat = 80
    while x <= 944 {
        p.addLine(to: CGPoint(x: x, y: y0 + amp * sin((x - 100) / 824 * .pi * 2 + phase)))
        x += 8
    }
    return p
}
let tops: [CGFloat] = [560, 440, 330, 220]
for (i, y0) in tops.enumerated() {
    let edge = wave(y0, 16 - CGFloat(i) * 2, CGFloat(i) * 1.3 + 0.4)
    let fill = edge.mutableCopy()!
    fill.addLine(to: CGPoint(x: 944, y: 80)); fill.addLine(to: CGPoint(x: 80, y: 80)); fill.closeSubpath()
    ctx.saveGState()
    ctx.addPath(fill); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [hex(hues[i], 0.2), hex(hues[i], 0.04)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0 + 20), end: CGPoint(x: 0, y: y0 - 130), options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    // Glowing edge.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: hex(hues[i], 0.8))
    ctx.addPath(edge)
    ctx.setStrokeColor(hex(hues[i], 0.9 - CGFloat(i) * 0.12))
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// The sounding line, from the surface to the third stratum.
let depth = CGPoint(x: 512, y: 300)
ctx.saveGState()
let lineG = CGGradient(colorsSpace: cs, colors: [hex(0xBFFBF5, 0.1), hex(0xBFFBF5, 0.95)] as CFArray, locations: [0, 1])!
ctx.addRect(CGRect(x: 505, y: depth.y, width: 14, height: 924 - depth.y))
ctx.clip()
ctx.drawLinearGradient(lineG, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: depth.y), options: [])
ctx.restoreGState()

// Sonar rings.
for (k, r) in [CGFloat(70), 135, 205].enumerated() {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 12, color: hex(0x62E6DC, 0.7))
    ctx.setStrokeColor(hex(0x9FF5EC, 0.75 - CGFloat(k) * 0.22))
    ctx.setLineWidth(6 - CGFloat(k))
    ctx.strokeEllipse(in: CGRect(x: depth.x - r, y: depth.y - r * 0.42, width: r * 2, height: r * 0.84))
    ctx.restoreGState()
}

// The return.
ctx.saveGState()
let glow = CGGradient(colorsSpace: cs, colors: [hex(0xE9FFFC, 1), hex(0x62E6DC, 0.9), hex(0x62E6DC, 0)] as CFArray, locations: [0, 0.35, 1])!
ctx.drawRadialGradient(glow, startCenter: depth, startRadius: 0, endCenter: depth, endRadius: 70, options: [])
ctx.restoreGState()
ctx.setFillColor(hex(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: depth.x - 22, y: depth.y - 22, width: 44, height: 44))

// Glass sheen along the top edge.
let sheen = CGGradient(colorsSpace: cs, colors: [hex(0xFFFFFF, 0.16), hex(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 760), options: [])
ctx.restoreGState()

// Rim.
ctx.saveGState()
ctx.addPath(shape)
ctx.setStrokeColor(hex(0xFFFFFF, 0.14))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
