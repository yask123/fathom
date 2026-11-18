// Renders Tracer's app icon: a trace on a black board. It leaves a ring, takes the turn the change takes and lands
// lit; the road not taken runs on a little way, dashed, and stops.
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
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: hex(0x020308, 0.55))
ctx.addPath(shape); ctx.setFillColor(hex(0x08090D)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// The board: near-black, a little violet light from where the trace lands.
let board = CGGradient(colorsSpace: cs, colors: [hex(0x12121C), hex(0x0A0B11), hex(0x07080C)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(board, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
let wash = CGGradient(colorsSpace: cs, colors: [hex(0xA88CFF, 0.2), hex(0xA88CFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(wash, startCenter: CGPoint(x: 720, y: 660), startRadius: 0, endCenter: CGPoint(x: 720, y: 660), endRadius: 560, options: [])

// Dots every 56 points.
ctx.setFillColor(hex(0xD2D8FF, 0.1))
var gy: CGFloat = 128
while gy < 924 {
    var gx: CGFloat = 128
    while gx < 924 {
        ctx.fillEllipse(in: CGRect(x: gx - 2.5, y: gy - 2.5, width: 5, height: 5))
        gx += 56
    }
    gy += 56
}

let a = CGPoint(x: 236, y: 372), b = CGPoint(x: 440, y: 372), c = CGPoint(x: 584, y: 652), d = CGPoint(x: 780, y: 652)
let e = CGPoint(x: 660, y: 372)

// The road not taken.
ctx.saveGState()
ctx.setStrokeColor(hex(0xC8CEEA, 0.4))
ctx.setLineWidth(15)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [8, 40])
ctx.move(to: CGPoint(x: b.x + 44, y: b.y)); ctx.addLine(to: e)
ctx.strokePath()
ctx.restoreGState()
ctx.setStrokeColor(hex(0xC8CEEA, 0.5))
ctx.setLineWidth(11)
ctx.strokeEllipse(in: CGRect(x: e.x + 26, y: e.y - 24, width: 48, height: 48))

// The trace, with its glow.
let trace = CGMutablePath()
trace.move(to: a); trace.addLine(to: b); trace.addLine(to: c); trace.addLine(to: d)
for (width, alpha, blur) in [(CGFloat(34), CGFloat(0.9), CGFloat(60)), (34, 1, 22)] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: hex(0x9A78FF, alpha))
    ctx.addPath(trace)
    ctx.setStrokeColor(hex(0xA88CFF))
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}
// A lighter core, so it reads as lit rather than painted.
ctx.addPath(trace)
ctx.setStrokeColor(hex(0xE6DDFF, 0.85))
ctx.setLineWidth(10)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

// Where it starts: a ring.
ctx.setFillColor(hex(0x0A0B11))
ctx.fillEllipse(in: CGRect(x: a.x - 52, y: a.y - 52, width: 104, height: 104))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: hex(0x9A78FF, 0.9))
ctx.setStrokeColor(hex(0xA88CFF))
ctx.setLineWidth(30)
ctx.strokeEllipse(in: CGRect(x: a.x - 52, y: a.y - 52, width: 104, height: 104))
ctx.restoreGState()

// Where it lands: lit green.
let halo = CGGradient(colorsSpace: cs, colors: [hex(0x4DF0A8, 0.55), hex(0x4DF0A8, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: d, startRadius: 0, endCenter: d, endRadius: 190, options: [])
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: hex(0x4DF0A8, 0.95))
ctx.setFillColor(hex(0x4DF0A8))
ctx.fillEllipse(in: CGRect(x: d.x - 62, y: d.y - 62, width: 124, height: 124))
ctx.restoreGState()
ctx.setFillColor(hex(0xDFFFF0, 0.9))
ctx.fillEllipse(in: CGRect(x: d.x - 26, y: d.y - 26, width: 52, height: 52))

// Glass sheen along the top edge.
let sheen = CGGradient(colorsSpace: cs, colors: [hex(0xFFFFFF, 0.1), hex(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 780), options: [])
ctx.restoreGState()

// Rim.
ctx.saveGState()
ctx.addPath(shape)
ctx.setStrokeColor(hex(0xC8BEFF, 0.2))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
