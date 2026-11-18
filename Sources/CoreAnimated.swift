// The continuous motion — pings, the scan line, loading shimmer — runs as Core Animation in the render server,
// so the app does no work per frame. (A SwiftUI TimelineView re-renders the window every tick, ~20% CPU.)

import AppKit
import QuartzCore
import SwiftUI

/// A layer-hosting view that rebuilds its layers when its size changes. Layer space is y-up (AppKit keeps the
/// hosted layer unflipped), which only matters for direction: angles grow counter-clockwise on screen.
class LayerCanvas: NSView {
    private var builtSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.size != builtSize, bounds.width > 1, bounds.height > 1 else { return }
        builtSize = bounds.size
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        // Layers hold fixed colours, so they're drawn for the current appearance and redrawn when it changes.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            build(in: layer!, size: bounds.size)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    func rebuild() {
        builtSize = .zero
        needsLayout = true
    }

    func build(in root: CALayer, size: CGSize) {}

    var scale: CGFloat { window?.backingScaleFactor ?? 2 }
}

// MARK: - Ping

/// Rings rippling out from a dot.
struct PingView: NSViewRepresentable {
    var color: Color = .signal
    var rings = 2
    var period: Double = 1.4
    var squash: CGFloat = 1
    var dot: CGFloat = 4
    var ringAlpha: Float = 0.9

    func makeNSView(context: Context) -> PingCanvas { PingCanvas(self) }
    func updateNSView(_ view: PingCanvas, context: Context) {}
}

final class PingCanvas: LayerCanvas {
    let config: PingView

    init(_ config: PingView) {
        self.config = config
        super.init()
    }

    override func build(in root: CALayer, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width / 2, size.height / 2 / max(config.squash, 0.01))
        let color = NSColor(config.color).cgColor
        let now = CACurrentMediaTime()
        for k in 0..<config.rings {
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r * config.squash, width: r * 2, height: r * 2 * config.squash), transform: nil)
            ring.position = c
            ring.fillColor = nil
            ring.strokeColor = color
            ring.lineWidth = 1
            ring.opacity = 0
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.06
            grow.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = config.ringAlpha
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = config.period
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.beginTime = now - Double(k) * config.period / Double(config.rings)
            ring.add(group, forKey: "ping")
            root.addSublayer(ring)
        }
        if config.dot > 0 {
            let d = CAShapeLayer()
            d.path = CGPath(ellipseIn: CGRect(x: c.x - config.dot / 2, y: c.y - config.dot / 2, width: config.dot, height: config.dot), transform: nil)
            d.fillColor = color
            root.addSublayer(d)
        }
    }
}

// MARK: - Shimmer

/// A rounded placeholder bar with light passing across it.
struct ShimmerBar: NSViewRepresentable {
    var radius: CGFloat = 6

    func makeNSView(context: Context) -> ShimmerCanvas { ShimmerCanvas(radius) }
    func updateNSView(_ view: ShimmerCanvas, context: Context) {}
}

final class ShimmerCanvas: LayerCanvas {
    let radius: CGFloat

    init(_ radius: CGFloat) {
        self.radius = radius
        super.init()
    }

    override func build(in root: CALayer, size: CGSize) {
        let g = CAGradientLayer()
        g.frame = CGRect(origin: .zero, size: size)
        g.cornerRadius = radius
        g.masksToBounds = true
        let base = NSColor(Color.wash(0.045)).cgColor
        let lit = NSColor(Color.signal).withAlphaComponent(0.13).cgColor
        g.colors = [base, base, lit, base, base]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.locations = [0, 0, 0.1, 0.2, 1]
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [0, -0.2, -0.1, 0, 1]
        move.toValue = [0, 1, 1.1, 1.2, 1]
        move.duration = 2.4
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        g.add(move, forKey: "shimmer")
        root.addSublayer(g)
    }
}

// MARK: - Scan

/// A thin line with a bright run passing along it: something is being read.
struct ScanBar: NSViewRepresentable {
    var color: Color = .signal

    func makeNSView(context: Context) -> ScanCanvas { ScanCanvas(color) }
    func updateNSView(_ view: ScanCanvas, context: Context) {}
}

final class ScanCanvas: LayerCanvas {
    let color: Color

    init(_ color: Color) {
        self.color = color
        super.init()
    }

    override func build(in root: CALayer, size: CGSize) {
        let track = CALayer()
        track.frame = CGRect(origin: .zero, size: size)
        track.cornerRadius = size.height / 2
        track.backgroundColor = NSColor(Color.wash(0.08)).cgColor
        track.masksToBounds = true
        root.addSublayer(track)

        let run = CAGradientLayer()
        let w = max(size.width * 0.38, 24)
        run.frame = CGRect(x: -w, y: 0, width: w, height: size.height)
        let lit = NSColor(color)
        run.colors = [lit.withAlphaComponent(0).cgColor, lit.cgColor, lit.withAlphaComponent(0).cgColor]
        run.startPoint = CGPoint(x: 0, y: 0.5)
        run.endPoint = CGPoint(x: 1, y: 0.5)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -w / 2
        move.toValue = size.width + w / 2
        move.duration = 1.25
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        run.add(move, forKey: "scan")
        track.addSublayer(run)
    }
}

/// A tiny ping, for "working".
struct Pip: View {
    var body: some View {
        PingView(rings: 2, period: 1.4, dot: 4)
    }
}
