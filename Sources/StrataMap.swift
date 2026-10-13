// The system map: the layers a PR cuts through, drawn as strata from surface (closest to the user) to abyss
// (storage, external services). Components glow by what the PR does to them; flows play as pulses along the wires.
// Every band, wire and node is its own view, so when the layout changes (the side panel opens, the map streams in)
// everything glides to its new place instead of jumping.

import AppKit
import SwiftUI

// MARK: - Canvas

/// The map in its card, with the era switch and a dock of flows and lenses along the bottom.
struct MapCanvas: View {
    @Bindable var session: PRSession

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if !session.map.isEmpty {
                    StrataMap(session: session)
                        .transition(.opacity)
                } else if let failure = session.mapState.failure {
                    VStack(spacing: 12) {
                        Text("No map this time")
                            .font(.serif(19))
                            .foregroundStyle(Color.text1)
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.text3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                        Button("Read again") { session.sound() }
                            .buttonStyle(.glass)
                    }
                } else {
                    SonarView(session: session)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !session.map.isEmpty {
                MapDock(session: session)
                    .transition(.opacity)
            }
        }
        .background(Surface(radius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(Motion.soft, value: session.map.isEmpty)
    }
}

/// What the colours mean, and Before / After when the PR adds or removes parts.
struct MapKey: View {
    @Bindable var session: PRSession

    var body: some View {
        HStack(spacing: 12) {
            lines
            HStack(spacing: 10) {
                dot(.added)
                dot(.modified)
                if session.map.components.contains(where: { $0.change == .removed }) { dot(.removed) }
            }
            if session.map.components.contains(where: { $0.change == .added || $0.change == .removed }) {
                EraSwitch(session: session)
            }
        }
    }

    /// The line styles this map uses, when it uses more than plain calls.
    @ViewBuilder private var lines: some View {
        let kinds = Set(session.map.edges.map(\.how))
        let shown: [(String, [CGFloat])] = [
            ("call", Edge.How.call.dash),
            ("HTTP", kinds.contains(.http) ? Edge.How.http.dash : nil),
            ("event", kinds.contains(.event) ? Edge.How.event.dash : nil),
            ("data", kinds.contains(.read) || kinds.contains(.write) ? Edge.How.read.dash : nil),
        ].compactMap { name, dash in dash.map { (name, $0) } }
        if shown.count > 1 {
            HStack(spacing: 10) {
                ForEach(shown, id: \.0) { name, dash in
                    HStack(spacing: 5) {
                        HLine()
                            .stroke(Color.text2.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: dash))
                            .frame(width: 16, height: 4)
                        Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.text3)
                    }
                }
            }
            .help("How parts reach each other. Click a wire or its tag to see the call and what travels.")
        }
    }

    private func dot(_ c: Change) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c.color).frame(width: 5, height: 5)
            Text(c.word).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.text3)
        }
    }
}

struct EraSwitch: View {
    @Bindable var session: PRSession
    @Namespace private var space

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Era.allCases) { era in
                let on = session.era == era
                Button {
                    withAnimation(.smooth(duration: 0.6)) { session.era = era }
                } label: {
                    Text(era.title)
                        .font(.system(size: 11, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.text1 : Color.text3)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if on {
                                Capsule().fill(Color.white.opacity(0.1)).matchedGeometryEffect(id: "era", in: space)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        .help("See the system before and after this PR")
    }
}

/// Flows to play, and the two other ways to look at the change.
struct MapDock: View {
    @Bindable var session: PRSession
    @State private var width: CGFloat = 1000

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(session.map.flows) { flow in
                        let on = session.panel == .flow(flow.id)
                        DockPill(on: on, help: "Play this flow through the map") {
                            session.toggleFlow(flow.id)
                        } label: {
                            Image(systemName: on ? "stop.fill" : "play.fill")
                                .font(.system(size: 7.5, weight: .heavy))
                                .foregroundStyle(Color.ink)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(Color.sonar.opacity(on ? 1 : 0.85)))
                            Text(flow.title)
                        }
                    }
                }
                .padding(.vertical, 1)
                .padding(.trailing, 16)
            }
            .scrollIndicators(.never)
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                }
            }
            // The lenses keep their words when there's room, and fold to icons when there isn't.
            lenses(words: width > 760)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder
    private func lenses(words: Bool) -> some View {
        HStack(spacing: 8) {
            if !session.brief.contracts.isEmpty {
                DockPill(on: session.panel == .interfaces, help: "Every interface whose shape changes") {
                    session.toggle(.interfaces)
                } label: {
                    Image(systemName: "curlybraces").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.calm)
                    if words { Text("Interfaces") }
                    Text("\(session.brief.contracts.count)").foregroundStyle(Color.text3).monospacedDigit()
                }
            }
            DockPill(on: session.panel == .footprint, help: "Where the change lands, file by file") {
                session.toggle(.footprint)
            } label: {
                Image(systemName: "square.grid.2x2").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.calm)
                if words { Text("Footprint") }
            }
        }
    }
}

struct DockPill<Label: View>: View {
    let on: Bool
    var help = ""
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { label }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.text1.opacity(on || hover ? 1 : 0.85))
                .lineLimit(1)
                .padding(.leading, 6)
                .padding(.trailing, 11)
                .frame(height: 29)
                .background(Capsule().fill(Color.white.opacity(on ? 0.09 : hover ? 0.07 : 0.04)))
                .overlay(Capsule().strokeBorder(on ? Color.sonar.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
        .animation(Motion.snappy, value: on)
        .help(help)
    }
}

// MARK: - Layout


struct StrataLayout {
    struct Band {
        let layer: Layer
        let index: Int
        let rect: CGRect
    }

    struct Node {
        let id: String
        var rect: CGRect
        let band: Int
    }

    struct Wire {
        let id: String
        let from: String
        let to: String
        let change: Change
        let label: String
        let p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint

        func point(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
        }

        func tangent(_ t: CGFloat) -> CGVector {
            let u = 1 - t
            let dx = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
            let dy = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
            return CGVector(dx: dx, dy: dy)
        }

        var path: Path {
            var p = Path()
            p.move(to: p0)
            p.addCurve(to: p3, control1: p1, control2: p2)
            return p
        }

        func segment(_ a: CGFloat, _ b: CGFloat) -> Path {
            var p = Path()
            let lo = max(0, min(a, b)), hi = min(1, max(a, b))
            guard hi > lo else { return p }
            let n = 18
            for i in 0...n {
                let pt = point(lo + (hi - lo) * CGFloat(i) / CGFloat(n))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }

        var reversed: Wire {
            Wire(id: id + "~r", from: to, to: from, change: change, label: label, p0: p3, p1: p2, p2: p1, p3: p0)
        }
    }

    static let nodeHeight: CGFloat = 36
    static let margin: CGFloat = 28

    var size: CGSize
    var bands: [Band] = []
    var nodes: [String: Node] = [:]
    var wires: [Wire] = []

    init(map: SystemMap, size: CGSize) {
        self.size = size
        let layers = map.layers.isEmpty ? [Layer(id: "_all", name: "System", role: "")] : map.layers
        let bandH = size.height / CGFloat(layers.count)
        bands = layers.enumerated().map { i, l in
            Band(layer: l, index: i, rect: CGRect(x: 0, y: CGFloat(i) * bandH, width: size.width, height: bandH))
        }

        var bandOf: [String: Int] = [:]
        for c in map.components {
            bandOf[c.id] = layers.firstIndex { $0.id == c.layer }
                ?? layers.firstIndex { $0.name.lowercased() == c.layer.lowercased() }
                ?? (layers.count - 1)
        }
        var rows: [[String]] = Array(repeating: [], count: layers.count)
        for c in map.components { rows[bandOf[c.id] ?? 0].append(c.id) }

        var neighbours: [String: [String]] = [:]
        for e in map.edges {
            neighbours[e.from, default: []].append(e.to)
            neighbours[e.to, default: []].append(e.from)
        }

        var width: [String: CGFloat] = [:]
        for c in map.components { width[c.id] = min(max(Self.textWidth(c.name) + 62, 96), 250) }

        // Order each band by the mean position of its neighbours in other bands, sweeping down and up.
        for _ in 0..<4 {
            for order in [Array(rows.indices), Array(rows.indices.reversed())] {
                for b in order {
                    var pos: [String: CGFloat] = [:]
                    for r in rows {
                        for (i, id) in r.enumerated() { pos[id] = (CGFloat(i) + 0.5) / CGFloat(r.count) }
                    }
                    let keyed = rows[b].enumerated().map { i, id -> (String, CGFloat, Int) in
                        let others = (neighbours[id] ?? []).filter { bandOf[$0] != b }.compactMap { pos[$0] }
                        let bary = others.isEmpty ? (pos[id] ?? 0.5) : others.reduce(0, +) / CGFloat(others.count)
                        return (id, bary, i)
                    }
                    rows[b] = keyed.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }.map(\.0)
                }
            }
        }

        // Place: rows wrap when a band is too crowded; nodes start evenly spread.
        let margin = Self.margin
        let avail = max(size.width - margin * 2, 100)
        var lines: [[String]] = []
        let minGap: CGFloat = 24
        for (b, r) in rows.enumerated() {
            var bandLines: [[String]] = [[]]
            var lw: CGFloat = 0
            for id in r {
                let w = width[id] ?? 100
                if !(bandLines.last?.isEmpty ?? true) && lw + minGap + w > avail {
                    bandLines.append([])
                    lw = 0
                }
                lw += (bandLines[bandLines.count - 1].isEmpty ? 0 : minGap) + w
                bandLines[bandLines.count - 1].append(id)
            }
            let band = bands[b].rect
            let lineH = Self.nodeHeight + 18
            let totalH = CGFloat(bandLines.count) * lineH - 18
            let top = band.midY + 8 - totalH / 2
            for (li, line) in bandLines.enumerated() where !line.isEmpty {
                let total = line.reduce(0) { $0 + (width[$1] ?? 100) }
                let gap = min((avail - total) / CGFloat(line.count + 1), 150)
                let groupW = total + gap * CGFloat(line.count - 1)
                var x = margin + (avail - groupW) / 2
                for id in line {
                    let w = width[id] ?? 100
                    nodes[id] = Node(id: id, rect: CGRect(x: x, y: top + CGFloat(li) * lineH, width: w, height: Self.nodeHeight), band: b)
                    x += w + gap
                }
                lines.append(line)
            }
        }

        // Pull each node toward its neighbours so wires run straighter, keeping order and spacing.
        for _ in 0..<3 {
            for line in lines {
                var xs = line.map { nodes[$0]!.rect.midX }
                let ws = line.map { width[$0] ?? 100 }
                for (i, id) in line.enumerated() {
                    let band = nodes[id]!.band
                    let others = (neighbours[id] ?? []).compactMap { nodes[$0] }.filter { $0.band != band }.map(\.rect.midX)
                    if !others.isEmpty { xs[i] += (others.reduce(0, +) / CGFloat(others.count) - xs[i]) * 0.45 }
                }
                Self.resolve(&xs, ws, gap: 28, lo: margin, hi: size.width - margin)
                for (i, id) in line.enumerated() { nodes[id]!.rect.origin.x = xs[i] - ws[i] / 2 }
            }
        }

        // Centre the whole drawing, keeping the alignment the pull just found.
        if let lo = nodes.values.map(\.rect.minX).min(), let hi = nodes.values.map(\.rect.maxX).max() {
            let shift = (size.width - (hi - lo)) / 2 - lo
            for id in Array(nodes.keys) { nodes[id]!.rect.origin.x += shift }
        }

        // Ports: spread wires that leave the same side of a node, ordered by where they're going.
        enum Side { case top, bottom }
        var ports: [String: [(edge: Int, side: Side, otherX: CGFloat)]] = [:]
        var sides: [Int: (Side, Side)] = [:]
        for (i, e) in map.edges.enumerated() {
            guard let a = nodes[e.from], let c = nodes[e.to] else { continue }
            let s: (Side, Side)
            if a.rect.midY < c.rect.midY - 4 { s = (.bottom, .top) }
            else if a.rect.midY > c.rect.midY + 4 { s = (.top, .bottom) }
            else { s = (.top, .top) }
            sides[i] = s
            ports[e.from, default: []].append((i, s.0, c.rect.midX))
            ports[e.to, default: []].append((i, s.1, a.rect.midX))
        }
        var offset: [String: CGFloat] = [:]   // "edge:from" / "edge:to"
        for (id, list) in ports {
            guard let n = nodes[id] else { continue }
            for side in [Side.top, Side.bottom] {
                let here = list.filter { $0.side == side }.sorted { $0.otherX < $1.otherX }
                guard here.count > 1 else {
                    if let only = here.first { offset["\(only.edge):\(id)"] = 0 }
                    continue
                }
                let spacing = min(14, (n.rect.width - 28) / CGFloat(here.count - 1))
                for (k, p) in here.enumerated() {
                    offset["\(p.edge):\(id)"] = (CGFloat(k) - CGFloat(here.count - 1) / 2) * spacing
                }
            }
        }
        for (i, e) in map.edges.enumerated() {
            guard let a = nodes[e.from], let c = nodes[e.to], let s = sides[i] else { continue }
            if s.0 == s.1 && abs(a.rect.midY - c.rect.midY) < 4 {
                let lo = min(a.rect.maxX, c.rect.maxX), hi = max(a.rect.minX, c.rect.minX)
                let between = nodes.values.contains { n in
                    n.id != a.id && n.id != c.id && abs(n.rect.midY - a.rect.midY) < 4 && n.rect.midX > lo && n.rect.midX < hi
                }
                if !between {
                    let leftToRight = a.rect.midX < c.rect.midX
                    let p0 = CGPoint(x: leftToRight ? a.rect.maxX : a.rect.minX, y: a.rect.midY)
                    let p3 = CGPoint(x: leftToRight ? c.rect.minX : c.rect.maxX, y: c.rect.midY)
                    let dx = p3.x - p0.x
                    wires.append(Wire(id: e.id, from: e.from, to: e.to, change: e.change, label: e.label, p0: p0,
                                      p1: CGPoint(x: p0.x + dx * 0.35, y: p0.y), p2: CGPoint(x: p3.x - dx * 0.35, y: p3.y), p3: p3))
                    continue
                }
            }
            let p0 = CGPoint(x: a.rect.midX + (offset["\(i):\(e.from)"] ?? 0), y: s.0 == .top ? a.rect.minY : a.rect.maxY)
            let p3 = CGPoint(x: c.rect.midX + (offset["\(i):\(e.to)"] ?? 0), y: s.1 == .top ? c.rect.minY : c.rect.maxY)
            let ceiling = bands[a.band].rect.minY + 26
            wires.append(Self.curve(id: e.id, from: e.from, to: e.to, change: e.change, label: e.label, p0, p3,
                                    sameRow: s.0 == s.1, ceiling: ceiling))
        }
    }

    /// A wire for a flow step, reusing the edge's own curve when there is one.
    func wire(from: String, to: String) -> Wire? {
        if let w = wires.first(where: { $0.from == from && $0.to == to }) { return w }
        if let w = wires.first(where: { $0.from == to && $0.to == from }) { return w.reversed }
        guard let a = nodes[from], let c = nodes[to] else { return nil }
        let down = a.rect.midY < c.rect.midY - 4, up = a.rect.midY > c.rect.midY + 4
        let p0 = CGPoint(x: a.rect.midX, y: down ? a.rect.maxY : a.rect.minY)
        let p3 = CGPoint(x: c.rect.midX, y: up ? c.rect.maxY : c.rect.minY)
        return Self.curve(id: "\(from)>\(to)~flow", from: from, to: to, change: .unchanged, label: "", p0, p3, sameRow: !down && !up)
    }

    static func curve(id: String, from: String, to: String, change: Change, label: String, _ p0: CGPoint, _ p3: CGPoint,
                      sameRow: Bool, ceiling: CGFloat = -.infinity) -> Wire {
        if sameRow {
            let dx = p3.x - p0.x
            // A cubic peaks at 3/4 of its control lift; keep that below the layer's label line.
            let room = max(14, (min(p0.y, p3.y) - ceiling) / 0.75)
            let lift = min(30 + min(abs(dx) * 0.12, 42), room)
            return Wire(id: id, from: from, to: to, change: change, label: label, p0: p0,
                        p1: CGPoint(x: p0.x + dx * 0.15, y: p0.y - lift), p2: CGPoint(x: p3.x - dx * 0.15, y: p3.y - lift), p3: p3)
        }
        let dy = p3.y - p0.y
        return Wire(id: id, from: from, to: to, change: change, label: label, p0: p0,
                    p1: CGPoint(x: p0.x, y: p0.y + dy * 0.5), p2: CGPoint(x: p3.x, y: p3.y - dy * 0.5), p3: p3)
    }

    static func resolve(_ xs: inout [CGFloat], _ ws: [CGFloat], gap: CGFloat, lo: CGFloat, hi: CGFloat) {
        guard !xs.isEmpty else { return }
        xs[0] = max(xs[0], lo + ws[0] / 2)
        for i in 1..<max(xs.count, 1) where i < xs.count {
            xs[i] = max(xs[i], xs[i - 1] + ws[i - 1] / 2 + gap + ws[i] / 2)
        }
        let last = xs.count - 1
        xs[last] = min(xs[last], hi - ws[last] / 2)
        for i in stride(from: last - 1, through: 0, by: -1) {
            xs[i] = min(xs[i], xs[i + 1] - ws[i + 1] / 2 - gap - ws[i] / 2)
        }
        xs[0] = max(xs[0], lo + ws[0] / 2)
    }

    static func textWidth(_ s: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        return ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }
}


extension StrataLayout.Wire: Identifiable {}

// MARK: - Map

struct StrataMap: View {
    @Bindable var session: PRSession
    @State private var drawn = false

    var body: some View {
        GeometryReader { geo in
            let layout = StrataLayout(map: session.map, size: geo.size)
            let focus = focusSet()
            let flowWires = flowWireIDs(layout)
            let weights = session.componentWeights
            ZStack(alignment: .topLeading) {
                BlueprintGrid()
                    .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { session.closePanel() }

                ForEach(layout.bands, id: \.layer.id) { band in
                    let c = Color.depth(band.index)
                    BandShape(index: band.index)
                        .fill(LinearGradient(colors: [c.opacity(0.05), c.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        .overlay {
                            if band.index > 0 {
                                BandShape(index: band.index, edgeOnly: true)
                                    .stroke(c.opacity(0.26), style: StrokeStyle(lineWidth: 0.75, dash: [3, 5]))
                            }
                        }
                        .frame(width: geo.size.width, height: band.rect.height)
                        .offset(y: band.rect.minY)
                        .allowsHitTesting(false)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%02d", band.index + 1))
                            .font(.mono(9.5, .semibold))
                            .foregroundStyle(c.opacity(0.55))
                        Text(band.layer.name.uppercased())
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(1.3)
                            .foregroundStyle(c.opacity(0.9))
                        if !band.layer.role.isEmpty {
                            Text(band.layer.role)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.text3)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: 18, y: band.rect.minY + 12)
                    .allowsHitTesting(false)
                }

                ForEach(layout.wires) { w in
                    WireView(wire: w, look: look(w, focus: focus, flowWires: flowWires), drawn: drawn) {
                        session.selectEdge(w.id)
                    }
                }

                if let pulse = pulse(layout) {
                    pulse
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                ForEach(session.map.components) { comp in
                    if let node = layout.nodes[comp.id] {
                        NodeChip(comp: comp, width: node.rect.width, era: session.era, weight: weights[comp.id] ?? 0,
                                 dim: focus.map { !$0.contains(comp.id) } ?? false,
                                 selected: session.selectedComponent == comp.id,
                                 active: activeInFlow(comp.id))
                            .position(x: node.rect.midX, y: node.rect.midY)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                            .onHover { h in
                                guard !QA.noHover else { return }
                                withAnimation(Motion.snappy) {
                                    session.hoveredComponent = h ? comp.id : (session.hoveredComponent == comp.id ? nil : session.hoveredComponent)
                                }
                            }
                            .onTapGesture { session.select(comp.id) }
                    }
                }

                // Above the nodes: a label that falls between two of them must not hide behind them.
                edgeLabels(layout, focus: focus)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).delay(0.15)) { drawn = true }
        }
    }

    /// The components to keep bright; nil means everything.
    private func focusSet() -> Set<String>? {
        if let id = session.hoveredEdge ?? session.selectedEdge, let e = session.map.edge(id) {
            return [e.from, e.to]
        }
        if let h = session.hoveredComponent ?? session.selectedComponent {
            var s: Set<String> = [h]
            for e in session.map.edges where e.from == h || e.to == h { s.insert(e.from); s.insert(e.to) }
            return s
        }
        return session.litComponents
    }

    /// The flow playing now, handed to Core Animation one step at a time.
    private func pulse(_ layout: StrataLayout) -> FlowPulse? {
        guard let f = session.playingFlow, session.map.flows.indices.contains(f) else { return nil }
        let steps = session.map.flows[f].steps
        guard steps.indices.contains(session.flowStep) else { return nil }
        let step = steps[session.flowStep]
        let trail = steps.prefix(session.flowStep).compactMap { layout.wire(from: $0.from, to: $0.to) }
        return FlowPulse(trail: trail, current: layout.wire(from: step.from, to: step.to), target: layout.nodes[step.to]?.rect,
                         startedAt: session.flowStarted,
                         key: "\(f):\(session.flowStep):\(session.flowStarted.timeIntervalSinceReferenceDate):\(Int(layout.size.width)):\(Int(layout.size.height))")
    }

    private func activeInFlow(_ id: String) -> Bool {
        guard let f = session.playingFlow, session.map.flows.indices.contains(f) else { return false }
        let steps = session.map.flows[f].steps
        guard steps.indices.contains(session.flowStep) else { return false }
        return steps[session.flowStep].from == id || steps[session.flowStep].to == id
    }

    private func flowWireIDs(_ layout: StrataLayout) -> Set<String> {
        guard let f = session.playingFlow, session.map.flows.indices.contains(f) else { return [] }
        var ids: Set<String> = []
        for s in session.map.flows[f].steps.prefix(session.flowStep + 1) {
            if let w = layout.wire(from: s.from, to: s.to) { ids.insert(w.id.replacingOccurrences(of: "~r", with: "")) }
        }
        return ids
    }

    private func look(_ w: StrataLayout.Wire, focus: Set<String>?, flowWires: Set<String>) -> WireLook {
        let era = session.era
        let fromC = session.map.component(w.from), toC = session.map.component(w.to)
        let endsAdded = fromC?.change == .added || toC?.change == .added
        let endsRemoved = fromC?.change == .removed || toC?.change == .removed
        let hidden = era == .before && (w.change == .added || endsAdded)
        let ghost = era == .after && (w.change == .removed || endsRemoved)
        let change: Change = era == .before ? (w.change == .removed ? .removed : .unchanged) : w.change
        let how = session.map.edge(w.id)?.how ?? .call
        var l = WireLook(color: change == .unchanged ? .white : change.color,
                         alpha: change == .unchanged ? 0.2 : 0.75,
                         width: change == .unchanged ? 1.1 : 1.5,
                         glow: change != .unchanged && !ghost,
                         dash: ghost || w.change == .removed ? [4, 4] : how.dash,
                         hidden: hidden)
        if how == .render { l.alpha *= 0.7 }
        if ghost { l.alpha = 0.3 }
        let chosen = session.selectedEdge.map { w.id == $0 } ?? false, pointed = session.hoveredEdge.map { w.id == $0 } ?? false
        if chosen || pointed {
            l.color = chosen ? .sonar : l.color
            l.alpha = 1
            l.width = 2.1
            l.glow = true
        }
        if flowWires.contains(w.id) {
            l.color = .sonar
            l.alpha = 0.55
            l.width = 1.8
        }
        var focused = focus.map { $0.contains(w.from) && $0.contains(w.to) } ?? true
        if let id = session.hoveredEdge ?? session.selectedEdge, !(chosen || pointed) { focused = focused && w.id == id }
        if !focused {
            l.alpha *= 0.22
            l.glow = false
        } else if focus != nil {
            l.alpha = min(1, l.alpha * 1.4)
            l.width += 0.3
        }
        return l
    }

    /// What travels along the wires: on every changed connection at rest, on all of a part's connections when you're
    /// on it, and on the connection you've picked. Placed where they collide with nothing; a tag that can't find room
    /// waits for you to point at its part. While a flow plays, only its step speaks.
    @ViewBuilder
    private func edgeLabels(_ layout: StrataLayout, focus: Set<String>?) -> some View {
        if session.playingFlow == nil {
            ForEach(tagPlacements(layout)) { tag in
                WireTag(token: tag.token, text: tag.text, tint: tag.tint, emphasis: tag.emphasis)
                    .position(tag.center)
                    .onTapGesture { session.selectEdge(tag.id) }
                    .onHover { h in
                        guard !QA.noHover else { return }
                        withAnimation(Motion.snappy) {
                            session.hoveredEdge = h ? tag.id : (session.hoveredEdge == tag.id ? nil : session.hoveredEdge)
                        }
                    }
                    .help(tag.help)
                    .transition(.opacity)
            }
        }
        if let f = session.playingFlow, session.map.flows.indices.contains(f),
           session.map.flows[f].steps.indices.contains(session.flowStep) {
            let step = session.map.flows[f].steps[session.flowStep]
            if let w = layout.wire(from: step.from, to: step.to) {
                HStack(spacing: 6) {
                    Text("\(session.flowStep + 1)")
                        .font(.mono(9.5, .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color.sonar))
                    Text(step.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.text1)
                    if !step.data.isEmpty {
                        Text(step.data)
                            .font(.mono(10, .medium))
                            .foregroundStyle(Color.sonar)
                    }
                }
                .padding(.leading, 3)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: 0x080C13).opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.sonar.opacity(0.45), lineWidth: 0.75))
                .fixedSize()
                .position(clearOfLayerLabels(labelPoint(w, layout, label: step.label + step.data, extra: 44),
                                             width: StrataLayout.textWidth(step.label + step.data) * 0.9 + 44, layout))
                .id("step\(session.flowStep)")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .allowsHitTesting(false)
            }
        }
    }

    /// The corner each layer writes its name in.
    private func layerLabelRects(_ layout: StrataLayout) -> [CGRect] {
        layout.bands.map { band in
            let name = (band.layer.name.uppercased() as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold)]).width
                + 1.3 * CGFloat(band.layer.name.count)
            let role = (band.layer.role as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5)]).width
            return CGRect(x: 10, y: band.rect.minY + 4, width: (44 + name + role) * 1.12 + 12, height: 24)
        }
    }

    /// Slides a label right until it no longer covers a layer's name.
    private func clearOfLayerLabels(_ p: CGPoint, width: CGFloat, _ layout: StrataLayout) -> CGPoint {
        var p = p
        for r in layerLabelRects(layout) where CGRect(x: p.x - width / 2, y: p.y - 11, width: width, height: 22).intersects(r) {
            p.x = min(r.maxX + width / 2 + 8, layout.size.width - width / 2 - 6)
        }
        return p
    }

    struct TagPlacement: Identifiable {
        let id: String
        let token: String?
        let text: String
        let tint: Color
        let emphasis: Bool
        let center: CGPoint
        let help: String
    }

    private func tagPlacements(_ layout: StrataLayout) -> [TagPlacement] {
        let picked = session.selectedEdge, pointed = session.hoveredEdge
        let anchor = session.hoveredComponent ?? session.selectedComponent
        // Who gets a tag, most wanted first.
        var wanted: [Edge] = []
        func add(_ e: Edge?) { if let e, visible(e), !wanted.contains(where: { $0.id == e.id }) { wanted.append(e) } }
        add(picked.flatMap { session.map.edge($0) })
        add(pointed.flatMap { session.map.edge($0) })
        if let anchor {
            session.map.edges.filter { $0.from == anchor || $0.to == anchor }.forEach(add)
        } else if picked == nil {
            // At rest: what the PR changes, the boundaries first (network, events, stores), then calls; never view wiring.
            func rank(_ e: Edge) -> Int {
                let kind = [.http, .event, .write, .read].contains(e.how) ? 0 : 2
                return kind + (e.change == .added ? 0 : 1)
            }
            session.map.edges.filter { $0.change != .unchanged && $0.how != .render && !$0.tagText.isEmpty }
                .enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
                .map(\.element).prefix(9).forEach(add)
        }

        var taken = layout.nodes.values.map { $0.rect.insetBy(dx: -4, dy: -3) }
        taken += layerLabelRects(layout)   // and the layer names in each band's corner
        var out: [TagPlacement] = []
        for e in wanted {
            guard let w = layout.wires.first(where: { $0.id == e.id }) else { continue }
            let text = e.tagText.isEmpty ? e.label : e.tagText
            guard !text.isEmpty else { continue }
            let size = WireTag.size(token: e.how.token(via: e.via), text: text)
            var spot: CGRect?
            for t in [0.5, 0.4, 0.6, 0.3, 0.7, 0.22, 0.78] as [CGFloat] {
                let p = w.point(t)
                for dy in [0, -16, 16] as [CGFloat] {
                    let r = CGRect(x: p.x - size.width / 2, y: p.y + dy - size.height / 2, width: size.width, height: size.height)
                    guard r.minX > 4, r.maxX < layout.size.width - 4, r.minY > 22, r.maxY < layout.size.height - 4 else { continue }
                    if !taken.contains(where: { $0.intersects(r) }) { spot = r; break }
                }
                if spot != nil { break }
            }
            guard let r = spot else { continue }
            taken.append(r.insetBy(dx: -4, dy: -3))
            let tint: Color = e.change == .unchanged ? .text2 : e.change.color
            let ends = "\(session.map.component(e.from)?.name ?? e.from) → \(session.map.component(e.to)?.name ?? e.to)"
            out.append(TagPlacement(id: e.id, token: e.how.token(via: e.via), text: text, tint: tint,
                                    emphasis: e.id == picked || e.id == pointed, center: CGPoint(x: r.midX, y: r.midY),
                                    help: [ends, e.via].filter { !$0.isEmpty }.joined(separator: "\n")))
        }
        return out
    }

    /// Where a wire's label goes: on the wire, unless the wire is a short hop between neighbours in a row — the
    /// label is wider than the gap and would sit on the nodes — in which case it goes just above the row.
    /// Kept inside the map either way.
    private func labelPoint(_ w: StrataLayout.Wire, _ layout: StrataLayout, label: String, extra: CGFloat) -> CGPoint {
        var p = w.point(0.5)
        let width = StrataLayout.textWidth(label) * 0.9 + extra
        let flat = abs(w.p0.y - w.p3.y) < 1 && abs(w.p1.y - w.p0.y) < 1 && abs(w.p2.y - w.p3.y) < 1
        if flat && abs(w.p3.x - w.p0.x) < width + 10 {
            p.y -= StrataLayout.nodeHeight / 2 + 14
        }
        p.x = min(max(p.x, width / 2 + 6), layout.size.width - width / 2 - 6)
        return p
    }

    private func visible(_ e: Edge) -> Bool {
        if session.era == .before && e.change == .added { return false }
        let from = session.map.component(e.from), to = session.map.component(e.to)
        if session.era == .before && (from?.change == .added || to?.change == .added) { return false }
        if session.era == .after && (e.change == .removed || from?.change == .removed || to?.change == .removed) { return false }
        return true
    }
}

/// One stratum: a soft band whose top edge wavers a little. Drawn in its own frame so it can glide.
struct BandShape: Shape {
    let index: Int
    var edgeOnly = false

    func path(in rect: CGRect) -> Path {
        var top = Path()
        let steps = 40
        for s in 0...steps {
            let x = rect.width * CGFloat(s) / CGFloat(steps)
            let y = CGFloat(sin(Double(x) / 170 + Double(index) * 1.9)) * (index == 0 ? 0 : 2.2)
            if s == 0 { top.move(to: CGPoint(x: x, y: y)) } else { top.addLine(to: CGPoint(x: x, y: y)) }
        }
        if edgeOnly { return top }
        var fill = top
        fill.addLine(to: CGPoint(x: rect.width, y: rect.height))
        fill.addLine(to: CGPoint(x: 0, y: rect.height))
        fill.closeSubpath()
        return fill
    }
}

struct WireLook: Equatable {
    var color: Color
    var alpha: Double
    var width: CGFloat
    var glow: Bool
    var dash: [CGFloat]
    var hidden: Bool
}

/// A wire as a shape whose four control points animate, so it follows its nodes when the layout changes.
struct WireShape: Shape {
    var p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint

    init(_ w: StrataLayout.Wire) {
        p0 = w.p0; p1 = w.p1; p2 = w.p2; p3 = w.p3
    }

    var animatableData: AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>,
                                       AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>> {
        get { AnimatablePair(AnimatablePair(p0.animatableData, p1.animatableData), AnimatablePair(p2.animatableData, p3.animatableData)) }
        set {
            p0.animatableData = newValue.first.first
            p1.animatableData = newValue.first.second
            p2.animatableData = newValue.second.first
            p3.animatableData = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: p0)
        p.addCurve(to: p3, control1: p1, control2: p2)
        return p
    }
}

/// The arrowhead at the end of a wire.
struct ArrowShape: Shape {
    var wire: WireShape

    var animatableData: WireShape.AnimatableData {
        get { wire.animatableData }
        set { wire.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t: CGFloat = 0.98, u = 1 - t
        let dx = 3 * u * u * (wire.p1.x - wire.p0.x) + 6 * u * t * (wire.p2.x - wire.p1.x) + 3 * t * t * (wire.p3.x - wire.p2.x)
        let dy = 3 * u * u * (wire.p1.y - wire.p0.y) + 6 * u * t * (wire.p2.y - wire.p1.y) + 3 * t * t * (wire.p3.y - wire.p2.y)
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let ux = dx / len, uy = dy / len
        let tip = wire.p3
        let back = CGPoint(x: tip.x - ux * 6.5, y: tip.y - uy * 6.5)
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: back.x - uy * 3.6, y: back.y + ux * 3.6))
        p.addLine(to: CGPoint(x: back.x + uy * 3.6, y: back.y - ux * 3.6))
        p.closeSubpath()
        return p
    }
}

struct WireView: View {
    let wire: StrataLayout.Wire
    let look: WireLook
    let drawn: Bool
    var tap: (() -> Void)? = nil

    var body: some View {
        let shape = WireShape(wire)
        ZStack {
            shape
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(look.color.opacity(look.glow ? look.alpha * 0.22 : 0), style: StrokeStyle(lineWidth: look.width + 5, lineCap: .round))
            shape
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(look.color.opacity(look.alpha),
                        style: StrokeStyle(lineWidth: look.width, lineCap: .round, dash: look.dash))
            ArrowShape(wire: shape)
                .fill(look.color.opacity(drawn ? look.alpha : 0))
        }
        .opacity(look.hidden ? 0 : 1)
        // Only the line itself takes a click, a little wider than it's drawn.
        .contentShape(shape.stroke(style: StrokeStyle(lineWidth: 12, lineCap: .round)))
        .onTapGesture { tap?() }
        .allowsHitTesting(tap != nil && !look.hidden)
    }
}

/// A connection's tag on the map: how it's called, as a token, and what travels.
struct WireTag: View {
    let token: String?
    let text: String
    let tint: Color
    let emphasis: Bool

    static let height: CGFloat = 19
    static func size(token: String?, text: String) -> CGSize {
        let t = (text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)]).width
        let k = token.map { ($0 as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)]).width + 6 } ?? 0
        return CGSize(width: ceil(t + k + 14), height: height)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let token {
                Text(token)
                    .font(.mono(8, .bold))
                    .foregroundStyle(Color.calm)
            }
            Text(text)
                .font(.mono(9.5, .medium))
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(hex: 0x080C13).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(emphasis ? Color.sonar.opacity(0.75) : Color.white.opacity(0.09), lineWidth: emphasis ? 1 : 0.6))
        .contentShape(Rectangle())
    }
}

extension Edge.How {
    /// The line a wire is drawn with: calls solid, network requests dashed, events dotted, data access dash-dot.
    var dash: [CGFloat] {
        switch self {
        case .call, .async, .render: []
        case .http: [6, 4]
        case .event: [1, 4]
        case .read, .write: [8, 3, 1.5, 3]
        }
    }

    /// A short token on the tag; a plain call needs none. HTTP shows its method when the call names one.
    func token(via: String) -> String? {
        switch self {
        case .call: return nil
        case .async: return "AWAIT"
        case .http:
            let method = via.split(separator: " ").first.map { $0.uppercased() } ?? ""
            return ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) ? method : "HTTP"
        case .event: return "EVENT"
        case .read: return "READ"
        case .write: return "WRITE"
        case .render: return "VIEW"
        }
    }

    var icon: String {
        switch self {
        case .call: "arrow.right"
        case .async: "arrow.triangle.2.circlepath"
        case .http: "network"
        case .event: "bolt"
        case .read: "arrow.down.doc"
        case .write: "square.and.arrow.down"
        case .render: "macwindow"
        }
    }
}

extension Edge {
    /// What a tag says: what travels, shortened to fit on a wire.
    var tagText: String {
        let limit = 40
        guard payload.count > limit else { return payload }
        // Keep what comes back whole; shorten what goes.
        if !returns.isEmpty && !sends.isEmpty && returns.count < limit - 12 {
            return String(sends.prefix(limit - returns.count - 4)).trimmingCharacters(in: .whitespaces) + "… → " + returns
        }
        return String(payload.prefix(limit - 1)) + "…"
    }
}

/// Faint graph paper behind the map, so it reads like a drawing.
struct BlueprintGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let minor: CGFloat = 24
            var fine = Path(), bold = Path()
            var x: CGFloat = 0, i = 0
            while x <= size.width {
                let r = CGRect(x: x, y: 0, width: 0.5, height: size.height)
                if i % 5 == 0 { bold.addRect(r) } else { fine.addRect(r) }
                x += minor; i += 1
            }
            var y: CGFloat = 0
            i = 0
            while y <= size.height {
                let r = CGRect(x: 0, y: y, width: size.width, height: 0.5)
                if i % 5 == 0 { bold.addRect(r) } else { fine.addRect(r) }
                y += minor; i += 1
            }
            ctx.fill(fine, with: .color(Color.white.opacity(0.022)))
            ctx.fill(bold, with: .color(Color.white.opacity(0.045)))
        }
    }
}

// MARK: - Nodes

struct NodeChip: View {
    let comp: Component
    let width: CGFloat
    let era: Era
    var weight: Double = 0     // 0...1, lines changed against the busiest component
    let dim: Bool
    let selected: Bool
    let active: Bool
    @State private var hover = false

    var body: some View {
        let hidden = era == .before && comp.change == .added
        let ghost = era == .after && comp.change == .removed
        let shown: Change = era == .before ? (comp.change == .removed ? .removed : .unchanged) : comp.change
        let tint = shown == .unchanged ? Color.text3 : shown.color
        let lit = selected || hover || active

        HStack(spacing: 7) {
            Image(systemName: Glyph.component(comp.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.sonar : tint)
            Text(comp.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(shown == .unchanged && !lit ? Color.text2 : Color.text1)
                .strikethrough(ghost, color: Color.removed.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: StrataLayout.nodeHeight)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(hex: 0x0D1119).opacity(0.96))
        }
        .background {
            if shown != .unchanged || active {
                // The more of it changed, the brighter it glows.
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill((active ? Color.sonar : tint).opacity(lit ? 0.55 : 0.1 + 0.32 * weight))
                    .blur(radius: lit ? 14 : 6 + 10 * weight)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [(shown == .unchanged ? Color.white : tint).opacity(0.09), .clear],
                                     startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(active ? Color.sonar : selected ? Color.text1.opacity(0.8) : (shown == .unchanged ? Color.white.opacity(0.13) : tint.opacity(0.7)),
                              style: StrokeStyle(lineWidth: selected || active ? 1.3 : 0.9, dash: ghost ? [3, 3] : []))
        }
        .overlay(alignment: .topTrailing) {
            if shown == .added || shown == .removed {
                Text(shown == .added ? "NEW" : "GONE")
                    .font(.system(size: 7.5, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(tint))
                    .offset(x: 6, y: -6)
            }
        }
        .opacity(dim ? 0.42 : ghost ? 0.55 : 1)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(hex: 0x0B0F16))
        }
        .scaleEffect(hidden ? 0.86 : selected ? 1.05 : hover ? 1.03 : 1)
        .opacity(hidden ? 0 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
        .animation(.smooth(duration: 0.5), value: era)
        .animation(Motion.soft, value: dim)
        .help(comp.summary)
    }
}

