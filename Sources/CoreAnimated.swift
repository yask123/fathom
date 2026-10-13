// The continuous motion — pings, the sonar sweep, loading shimmer — runs as Core Animation in the render server,
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
        build(in: layer!, size: bounds.size)
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
    var color: Color = .sonar
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
        let base = NSColor.white.withAlphaComponent(0.045).cgColor
        let lit = NSColor(Color.sonar).withAlphaComponent(0.13).cgColor
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

// MARK: - Sonar

/// One changed file as a return on the scope.
struct ScopeFile: Equatable {
    var path: String
    var name: String
    var weight: Double   // 0...1, by lines changed
    var tint: Color
}

/// The sonar scope while Claude reads: a rotating sweep, a return per changed file that brightens as the beam
/// passes, a ping where Claude opens a file, and context it reaches for outside the diff at the rim.
struct SonarScope: NSViewRepresentable {
    let files: [ScopeFile]
    let opened: [String]     // repo paths Claude has read, oldest first

    func makeNSView(context: Context) -> SonarCanvas { SonarCanvas() }

    func updateNSView(_ view: SonarCanvas, context: Context) {
        if view.files != files {
            view.files = files
            view.rebuild()
        }
        view.reveal(opened)
    }
}

final class SonarCanvas: LayerCanvas {
    var files: [ScopeFile] = []
    private let period = 3.6
    private var start: CFTimeInterval = 0
    private var center: CGPoint = .zero
    private var radius: CGFloat = 0
    private var dots: [String: (dot: CAShapeLayer, label: CATextLayer, point: CGPoint)] = [:]
    private var shown = Set<String>()
    private var contextCount = 0
    private weak var root: CALayer?

    override func build(in root: CALayer, size: CGSize) {
        self.root = root
        dots = [:]
        shown = []
        contextCount = 0
        center = CGPoint(x: size.width / 2, y: size.height * 0.54)
        radius = max(20, min(size.width * 0.42, size.height * 0.4))
        start = CACurrentMediaTime()
        let sonar = NSColor(Color.sonar)

        // Range rings and cross.
        for k in 1...4 {
            let r = radius * CGFloat(k) / 4
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = sonar.withAlphaComponent(k == 4 ? 0.12 : 0.055).cgColor
            ring.lineWidth = 0.75
            if k < 4 { ring.lineDashPattern = [2, 5] }
            root.addSublayer(ring)
        }
        let cross = CAShapeLayer()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: center.x - radius, y: center.y)); p.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        p.move(to: CGPoint(x: center.x, y: center.y - radius)); p.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        cross.path = p
        cross.strokeColor = sonar.withAlphaComponent(0.05).cgColor
        cross.lineWidth = 0.75
        root.addSublayer(cross)

        // The sweep: a conic glow trailing the beam, rotating forever.
        let sweep = CALayer()
        sweep.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        sweep.position = center
        let glow = CAGradientLayer()
        glow.type = .conic
        glow.frame = sweep.bounds
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        let clear = sonar.withAlphaComponent(0).cgColor
        // The glow trails the beam: brightest just behind it, gone a fifth of a turn later.
        glow.colors = [clear, clear, sonar.withAlphaComponent(0.2).cgColor]
        glow.locations = [0, 0.82, 1]
        let disc = CAShapeLayer()
        disc.path = CGPath(ellipseIn: sweep.bounds, transform: nil)
        glow.mask = disc
        sweep.addSublayer(glow)
        let beam = CAShapeLayer()
        let bp = CGMutablePath()
        bp.move(to: CGPoint(x: radius, y: radius))
        bp.addLine(to: CGPoint(x: radius * 2, y: radius))
        beam.path = bp
        beam.strokeColor = sonar.withAlphaComponent(0.55).cgColor
        beam.lineWidth = 1
        sweep.addSublayer(beam)
        // Turns the same way the dots' angles grow, so each return lights as the beam crosses it.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = period
        spin.repeatCount = .infinity
        spin.beginTime = start
        sweep.add(spin, forKey: "spin")
        root.addSublayer(sweep)

        // A return per changed file.
        for (i, f) in files.enumerated() {
            let angle = (Double(i) * 2.399963 + 0.6).truncatingRemainder(dividingBy: 2 * .pi)
            let frac = (Double(i) * 0.618034).truncatingRemainder(dividingBy: 1)
            let r = radius * CGFloat(0.28 + 0.62 * frac)
            let pt = CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
            let s = CGFloat(2.4 + f.weight * 3)
            let dot = CAShapeLayer()
            dot.path = CGPath(ellipseIn: CGRect(x: pt.x - s, y: pt.y - s, width: s * 2, height: s * 2), transform: nil)
            dot.fillColor = NSColor(f.tint).cgColor
            dot.opacity = 0.28
            dot.add(sweepFlash(at: angle, low: 0.28, high: 0.9), forKey: "sweep")
            root.addSublayer(dot)
            let label = textLayer(f.name, size: 10, color: NSColor(Color.text2))
            label.frame = CGRect(x: pt.x + 8, y: pt.y - 7, width: 220, height: 14)
            label.opacity = 0
            label.add(sweepFlash(at: angle, low: 0, high: 0.85), forKey: "sweep")
            root.addSublayer(label)
            dots[f.path] = (dot, label, pt)
        }

        // The ship, and its own slow ping.
        let ship = CAShapeLayer()
        ship.path = CGPath(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6), transform: nil)
        ship.fillColor = sonar.cgColor
        root.addSublayer(ship)
        let wave = CAShapeLayer()
        wave.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        wave.position = center
        wave.fillColor = nil
        wave.strokeColor = sonar.withAlphaComponent(0.22).cgColor
        wave.lineWidth = 1
        wave.opacity = 0
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.02
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 2.4
        g.repeatCount = .infinity
        wave.add(g, forKey: "wave")
        root.addSublayer(wave)
    }

    /// Opacity that peaks when the beam crosses `angle` and fades over the next ~1.6 radians.
    private func sweepFlash(at angle: Double, low: Float, high: Float) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [high, low, low]
        a.keyTimes = [0, NSNumber(value: 1.6 / (2 * .pi)), 1]
        a.duration = period
        a.repeatCount = .infinity
        a.beginTime = start + angle / (2 * .pi) * period
        return a
    }

    /// Pings the files Claude has opened since the last call.
    func reveal(_ opened: [String]) {
        guard let root else { return }
        for path in opened where !shown.contains(path) {
            shown.insert(path)
            if let hit = dots.first(where: { matches($0.key, path) }) {
                hit.value.dot.removeAnimation(forKey: "sweep")
                hit.value.dot.opacity = 0.85
                hit.value.label.removeAnimation(forKey: "sweep")
                hit.value.label.opacity = 0.95
                ping(at: hit.value.point, in: root)
            } else {
                // Context outside the diff: a mark at the rim whose name fades.
                let angle = Double(stableHash(path) % 6283) / 1000
                let r = radius * (1.04 + CGFloat(contextCount % 3) * 0.05)
                contextCount += 1
                let pt = CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
                let tint = NSColor(Color.depth(2))
                let dot = CAShapeLayer()
                dot.path = CGPath(ellipseIn: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4), transform: nil)
                dot.fillColor = tint.withAlphaComponent(0.75).cgColor
                root.addSublayer(dot)
                let label = textLayer((path as NSString).lastPathComponent, size: 9.5, color: tint)
                label.frame = CGRect(x: pt.x + 6, y: pt.y - 6, width: 200, height: 13)
                label.opacity = 0
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 6
                label.add(fade, forKey: "fade")
                root.addSublayer(label)
                ping(at: pt, in: root)
            }
        }
    }

    private func ping(at pt: CGPoint, in root: CALayer) {
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -26, y: -26, width: 52, height: 52), transform: nil)
        ring.position = pt
        ring.fillColor = nil
        ring.strokeColor = NSColor(Color.sonar).cgColor
        ring.lineWidth = 1
        ring.opacity = 0
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.1
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 1.6
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(g, forKey: "ping")
        root.addSublayer(ring)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { ring.removeFromSuperlayer() }
    }

    private func textLayer(_ text: String, size: CGFloat, color: NSColor) -> CATextLayer {
        let t = CATextLayer()
        t.string = text
        t.font = NSFont.systemFont(ofSize: size, weight: .medium)
        t.fontSize = size
        t.foregroundColor = color.cgColor
        t.contentsScale = scale
        t.alignmentMode = .left
        return t
    }

    private func matches(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("/" + b) || b.hasSuffix("/" + a)
    }

    /// FNV-1a, stable across launches (unlike hashValue).
    private func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return Int(h % UInt64(Int.max))
    }
}

// MARK: - Flow pulse

/// A flow playing through the map: the steps so far stay lit, the current step's wire fills with a bright head,
/// and the receiving part pings. All of it is Core Animation, started once per step.
struct FlowPulse: NSViewRepresentable {
    /// Wires already travelled, in the map's top-left coordinates.
    var trail: [StrataLayout.Wire]
    /// The wire for the step playing now.
    var current: StrataLayout.Wire?
    /// The part the step arrives at.
    var target: CGRect?
    /// When this step's pulse starts (it may wait for the map to settle).
    var startedAt: Date
    /// Changes whenever the step does, so the animation restarts.
    var key: String

    func makeNSView(context: Context) -> PulseCanvas { PulseCanvas() }
    func updateNSView(_ view: PulseCanvas, context: Context) { view.show(self) }
}

final class PulseCanvas: LayerCanvas {
    private var config: FlowPulse?
    private var shownKey = ""
    private let container = CALayer()
    private let trailLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let haloLayer = CAGradientLayer()
    private let dotLayer = CALayer()
    private let pingLayer = CAShapeLayer()

    static let travel: Double = 1.15
    static let ping: Double = 0.9

    override func build(in root: CALayer, size: CGSize) {
        let sonar = NSColor(Color.sonar).cgColor
        // Layer space is y-up here; the container flips it so paths use the map's coordinates as they are.
        container.frame = CGRect(origin: .zero, size: size)
        // (A sublayer transform turns about the layer's centre, so a plain flip is enough.)
        container.sublayerTransform = CATransform3DMakeScale(1, -1, 1)
        root.addSublayer(container)
        for l in [trailLayer, glowLayer, strokeLayer, pingLayer] {
            l.fillColor = nil
            l.lineCap = .round
            l.strokeColor = sonar
            container.addSublayer(l)
        }
        trailLayer.lineWidth = 1.6
        trailLayer.opacity = 0.28
        glowLayer.lineWidth = 7
        glowLayer.opacity = 0.35
        strokeLayer.lineWidth = 2
        strokeLayer.opacity = 0.85
        pingLayer.lineWidth = 1.2
        pingLayer.opacity = 0
        haloLayer.type = .radial
        haloLayer.colors = [NSColor(Color.sonar).withAlphaComponent(0.55).cgColor, NSColor(Color.sonar).withAlphaComponent(0).cgColor]
        haloLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        haloLayer.endPoint = CGPoint(x: 1, y: 1)
        haloLayer.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        haloLayer.opacity = 0
        dotLayer.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        dotLayer.cornerRadius = 3.5
        dotLayer.backgroundColor = NSColor.white.cgColor
        dotLayer.opacity = 0
        container.addSublayer(haloLayer)
        container.addSublayer(dotLayer)
        shownKey = ""
        if let config { show(config) }
    }

    func show(_ c: FlowPulse) {
        config = c
        guard container.superlayer != nil, c.key != shownKey else { return }
        shownKey = c.key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let trail = CGMutablePath()
        for w in c.trail { trail.addPath(Self.path(w)) }
        trailLayer.path = trail
        for l in [glowLayer, strokeLayer, haloLayer, dotLayer, pingLayer] { l.removeAllAnimations() }
        guard let w = c.current else {
            strokeLayer.path = nil
            glowLayer.path = nil
            CATransaction.commit()
            return
        }
        let path = Self.path(w)
        strokeLayer.path = path
        glowLayer.path = path
        let begin = CACurrentMediaTime() + max(0, c.startedAt.timeIntervalSinceNow)
        let samples = Self.samples(w, count: 36)

        // The wire fills in, eased; the glowing head trails 30% behind the tip.
        func keyframes(_ keyPath: String, _ values: [Any], on layer: CALayer, from: Any, to: Any) {
            let a = CAKeyframeAnimation(keyPath: keyPath)
            a.values = values
            a.keyTimes = (0..<values.count).map { NSNumber(value: Double($0) / Double(values.count - 1)) }
            a.duration = Self.travel
            a.beginTime = begin
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: keyPath)
        }
        keyframes("strokeEnd", samples.map { $0.t }, on: strokeLayer, from: 0, to: 1)
        keyframes("strokeEnd", samples.map { $0.t }, on: glowLayer, from: 0, to: 1)
        keyframes("strokeStart", samples.map { max(0, $0.t - 0.3) }, on: glowLayer, from: 0, to: 0.7)
        keyframes("position", samples.map { NSValue(point: $0.point) }, on: dotLayer, from: 0, to: 0)
        keyframes("position", samples.map { NSValue(point: $0.point) }, on: haloLayer, from: 0, to: 0)
        // Head and glow show while travelling, then go.
        for l in [dotLayer, haloLayer, glowLayer] {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            let peak: Float = l === glowLayer ? 0.35 : 1
            a.values = [0, peak, peak, 0]
            a.keyTimes = [0, 0.02, 0.92, 1]
            a.duration = Self.travel
            a.beginTime = begin
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            l.add(a, forKey: "opacity")
        }
        // The arrival ping.
        if let r = c.target {
            pingLayer.path = CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil)
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil)
            grow.toValue = CGPath(roundedRect: r.insetBy(dx: -10, dy: -10), cornerWidth: 19, cornerHeight: 19, transform: nil)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.6
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [grow, fade]
            g.duration = Self.ping
            g.beginTime = begin + Self.travel
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            pingLayer.add(g, forKey: "ping")
        }
        CATransaction.commit()
    }

    static func path(_ w: StrataLayout.Wire) -> CGPath {
        let p = CGMutablePath()
        p.move(to: w.p0)
        p.addCurve(to: w.p3, control1: w.p1, control2: w.p2)
        return p
    }

    /// Points along the wire at an eased pace, with the share of its length reached at each (what strokeEnd means).
    static func samples(_ w: StrataLayout.Wire, count: Int) -> [(t: Double, point: CGPoint)] {
        // Arc length table.
        let n = 96
        var pts: [CGPoint] = []
        var lengths: [CGFloat] = [0]
        for i in 0...n {
            let p = w.point(CGFloat(i) / CGFloat(n))
            if let last = pts.last { lengths.append(lengths.last! + hypot(p.x - last.x, p.y - last.y)) }
            pts.append(p)
        }
        let total = max(lengths.last!, 0.001)
        func at(_ share: CGFloat) -> CGPoint {
            let target = share * total
            var i = 1
            while i < lengths.count && lengths[i] < target { i += 1 }
            if i >= lengths.count { return pts.last! }
            let span = max(lengths[i] - lengths[i - 1], 0.0001)
            let f = (target - lengths[i - 1]) / span
            return CGPoint(x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f, y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * f)
        }
        return (0...count).map { k in
            let raw = Double(k) / Double(count)
            let e = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
            return (e, at(CGFloat(e)))
        }
    }
}
