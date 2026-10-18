// The design page: the system the change lives in, drawn as a blueprint (each process a box, its parts inside, and
// what crosses between them), then the engineering idea it rests on, boxed the way a journal boxes an explainer,
// and the names a newcomer would trip on.

import SwiftUI

struct DesignPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let s = session.story
        PageFrame(page: .design, title: s.move, dek: dek(s), waiting: session.storyState.isRunning) {
            VStack(alignment: .leading, spacing: 44) {
                if !s.parts.isEmpty {
                    Figure(number: 2, caption: caption(s)) {
                        Blueprint(parts: s.parts, links: s.links, order: s.flow.flatMap { [$0.from, $0.to] })
                    }
                } else if session.storyState.isRunning {
                    Skeleton(lines: [0.8, 0.6], height: 14, spacing: 16).frame(maxWidth: 900)
                }
                if s.concept != nil || !s.terms.isEmpty {
                    HStack(alignment: .top, spacing: 40) {
                        if let c = s.concept {
                            ConceptBox(number: 1, concept: c)
                                .frame(maxWidth: 640, alignment: .leading)
                        }
                        if !s.terms.isEmpty {
                            Nomenclature(terms: s.terms)
                                .frame(minWidth: 240, maxWidth: 340, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }

    private func dek(_ s: Story) -> Text? {
        guard let c = s.concept else { return nil }
        return Text("An instance of ") + Text(Prose.lower(c.name)).font(.serif(20)) + Text(" — see Box 1.")
    }

    private func caption(_ s: Story) -> String {
        var places: [String] = []
        for p in s.parts where !p.place.isEmpty && !places.contains(p.place) { places.append(p.place) }
        let tail = " Green is new in this change; a solid frame, changed; dashed, untouched context it talks to. Point at a part to see only what it touches."
        if places.count >= 2 {
            return "Where each part runs, and what crosses between them. Each box is a process; an arrow that leaves one crosses a process boundary, marked where it meets the edge." + tail
        }
        let within = places.first.map { ", all within \($0)" } ?? ""
        return "The parts by layer\(within), and what passes between them." + tail
    }
}

/// The parts of the system as a blueprint: each process (or, when everything runs in one, each layer of the stack)
/// a dashed box with its name in small capitals on the edge, the parts inside it on a shared grid so a part sits
/// over what it talks to, and arrows labelled with what crosses. Where an arrow leaves a box it crosses a process
/// boundary, and the crossing is marked on the box's edge.
struct Blueprint: View {
    let parts: [Story.Part]
    let links: [Story.Link]
    /// Actor names in the order the journey meets them, to order the parts.
    var order: [String] = []

    @State private var drawn = false
    @State private var focus: String?

    private let nodeH: CGFloat = 64
    private let laneHead: CGFloat = 34
    private let lanePad: CGFloat = 20
    private let laneGap: CGFloat = 66
    private let rowGap: CGFloat = 42
    private let perRow = 4

    struct Plan {
        var lanes: [(name: String, rect: CGRect)] = []
        var at: [String: CGPoint] = [:]
        var lane: [String: Int] = [:]
        var routes: [Int: Route] = [:]
        var nodeW: CGFloat = 220
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Up or down between rows; within a row, an arc over the cards (left to right, between neighbours) or under
    /// them (right to left, or past a card in between).
    enum Route: Equatable { case vertical, over, under(deep: Bool) }

    private let arcRise: CGFloat = 40
    private let arcDeep: CGFloat = 60

    struct Edge {
        var s: CGPoint
        var e: CGPoint
        var c1: CGPoint
        var c2: CGPoint
        var dir: CGVector
        var route: Route
        var crossing: Bool
    }

    private func lit(_ l: Story.Link) -> Bool { focus == nil || l.from == focus || l.to == focus }
    private func lit(_ p: Story.Part) -> Bool {
        focus == nil || focus == p.id || links.contains { ($0.from == focus && $0.to == p.id) || ($0.to == focus && $0.from == p.id) }
    }

    var body: some View {
        GeometryReader { geo in
            let p = plan(geo.size.width)
            let es = edges(p)
            let spots = labelSpots(p, es)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for lane in p.lanes {
                        ctx.stroke(Path(lane.rect), with: .color(.wash(0.3)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                    }
                    for (i, l) in links.enumerated() {
                        guard let e = es[i] else { continue }
                        let st = style(l, e)
                        var c = ctx
                        c.opacity = lit(l) ? 1 : 0.12
                        c.stroke(path(e), with: .color(st.color), style: StrokeStyle(lineWidth: st.width, lineCap: .round, dash: st.dash))
                        Self.head(&c, at: e.e, dir: e.dir, color: st.color)
                        if e.crossing {
                            // Where it crosses a process boundary, a small square on the box's edge.
                            for y in crossings(e, p, l) {
                                let pt = point(e, t: tAt(e, y: y))
                                let r = CGRect(x: pt.x - 2.5, y: y - 2.5, width: 5, height: 5)
                                c.fill(Path(r), with: .color(Color.paper))
                                c.stroke(Path(r), with: .color(st.color), lineWidth: 0.9)
                            }
                        }
                    }
                }
                .opacity(drawn ? 1 : 0)

                ForEach(Array(p.lanes.enumerated()), id: \.offset) { _, lane in
                    Text(lane.name)
                        .font(.smallCaps(12))
                        .tracking(1.3)
                        .foregroundStyle(Color.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .background(Rectangle().fill(Color.paper))
                        .fixedSize()
                        .offset(x: lane.rect.minX + 12, y: lane.rect.minY - 8)
                }

                ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                    if let spot = spots[i] {
                        Text(l.label)
                            .font(.serifItalic(13.5))
                            .foregroundStyle(l.change == .added ? Color.added : l.change == .removed ? Color.removed : Color.text2)
                            .strikethrough(l.change == .removed, color: Color.removed.opacity(0.6))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Rectangle().fill(Color.paper))
                            .fixedSize()
                            .position(spot)
                            .opacity(drawn ? (lit(l) ? 1 : 0.12) : 0)
                    }
                }

                ForEach(parts) { part in
                    if let c = p.at[part.id] {
                        // Hover goes on the card itself: after .position it would cover the whole figure.
                        PartCard(part: part, focused: focus == part.id)
                            .frame(width: p.nodeW, height: nodeH)
                            .contentShape(Rectangle())
                            .onHover { h in
                                withAnimation(.easeOut(duration: 0.18)) { focus = QA.hover(h) ? part.id : (focus == part.id ? nil : focus) }
                            }
                            .scaleEffect(drawn ? 1 : 0.94)
                            .opacity(drawn ? (lit(part) ? 1 : 0.3) : 0)
                            .position(c)
                    }
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .topLeading)
        }
        .frame(height: height + 8)
        .frame(maxWidth: 1080)
        .padding(.top, 8)
        .onAppear { withAnimation(.smooth(duration: 0.6).delay(0.1)) { drawn = true } }
    }

    // MARK: Lanes

    /// The processes, in the order the journey meets them; when there's only one, the layers of the stack instead.
    private var grouping: (names: [String], members: [[String]]) {
        let ranked = self.ranked
        var names: [String] = []
        for p in ranked where !names.contains(place(p)) { names.append(place(p)) }
        if names.count >= 2 {
            return (names, names.map { n in ranked.filter { place($0) == n }.map(\.id) })
        }
        let tiers: [(String, Set<String>)] = [("Interface", ["ui"]), ("Logic", ["service", "state", "job", "library", "test"]),
                                              ("Boundary", ["api", "external"]), ("Data", ["store", "config"])]
        var out: [(String, [String])] = []
        for (name, kinds) in tiers {
            let ids = ranked.filter { kinds.contains($0.kind) }.map(\.id)
            if !ids.isEmpty { out.append((name, ids)) }
        }
        let known = Set(out.flatMap(\.1))
        let rest = ranked.filter { !known.contains($0.id) }.map(\.id)
        if !rest.isEmpty { out.append(("Other", rest)) }
        return (out.map(\.0), out.map(\.1))
    }

    private func place(_ p: Story.Part) -> String {
        let s = p.place.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Elsewhere" : s
    }

    /// Parts in the order the journey meets them, then the rest as named.
    private var ranked: [Story.Part] {
        func norm(_ x: String) -> String { x.lowercased().filter { $0.isLetter || $0.isNumber } }
        func same(_ a: String, _ b: String) -> Bool {
            guard !a.isEmpty, !b.isEmpty else { return false }
            if a == b { return true }
            let (short, long) = a.count < b.count ? (a, b) : (b, a)
            return short.count >= 4 && long.contains(short)
        }
        let names = order.map(norm)
        func rank(_ i: Int) -> Int {
            let n = norm(parts[i].name)
            return names.firstIndex { same($0, n) } ?? 1000 + i
        }
        return parts.indices.sorted { (rank($0), $0) < (rank($1), $1) }.map { parts[$0] }
    }

    /// The figure's height doesn't depend on its width: every lane, row and arc is the same at any width.
    private var height: CGFloat { plan(1000).height }

    /// Every part's place: the lanes stacked down the figure; within a lane, parts on a shared grid of columns,
    /// each in the free column nearest to what it talks to. Rows with arcs over or under them get room for the arcs.
    private func plan(_ width: CGFloat) -> Plan {
        let g = grouping
        var plan = Plan()
        plan.width = width
        let widest = min(max(g.members.map(\.count).max() ?? 1, 1), perRow)
        let inner = width - 2 * lanePad
        plan.nodeW = max(150, min(236, (inner - CGFloat(widest - 1) * 64) / CGFloat(widest)))
        let slot = inner / CGFloat(widest)
        let slotX: (Int) -> CGFloat = { k in self.lanePad + (CGFloat(k) + 0.5) * slot }

        // Across: the columns.
        var rowsOf: [[[String]]] = []
        var rowOf: [String: Int] = [:]
        var x: [String: CGFloat] = [:]
        var slotOf: [String: Int] = [:]
        var rowCount = 0
        for (li, members) in g.members.enumerated() {
            let rows = stride(from: 0, to: members.count, by: perRow).map { Array(members[$0..<min($0 + perRow, members.count)]) }
            for row in rows {
                // A part that talks to one already placed sits over or under it; the rest take the columns left,
                // nearest the middle first.
                var anchored: [(String, CGFloat)] = []
                var free: [String] = []
                for id in row {
                    let xs = links.compactMap { l -> CGFloat? in
                        if l.from == id { return x[l.to] }
                        if l.to == id { return x[l.from] }
                        return nil
                    }
                    if xs.isEmpty { free.append(id) } else { anchored.append((id, xs.reduce(0, +) / CGFloat(xs.count))) }
                }
                anchored.sort { $0.1 < $1.1 }
                // Columns where a lane in between already has a part: a link straight down them would pass behind it.
                var blocked = Set<Int>()
                for (id, _) in anchored {
                    for l in links where l.from == id || l.to == id {
                        let other = l.from == id ? l.to : l.from
                        guard let lo = plan.lane[other], lo < li - 1 else { continue }
                        for (pid, lane) in plan.lane where lane > lo && lane < li { if let k = slotOf[pid] { blocked.insert(k) } }
                    }
                }
                var taken = Set<Int>()
                if !anchored.isEmpty {
                    let slots = bestSlots(anchored.map(\.1), count: widest, slotX: slotX, blocked: blocked, penalty: inner)
                    for (k, item) in anchored.enumerated() {
                        x[item.0] = slotX(slots[k])
                        slotOf[item.0] = slots[k]
                        taken.insert(slots[k])
                    }
                }
                let middle = CGFloat(widest - 1) / 2
                var open = (0..<widest).filter { !taken.contains($0) }
                if anchored.isEmpty && free.count < widest {
                    // Nothing to line up with: centre the row.
                    let start = (widest - free.count) / 2
                    open = Array(start..<start + free.count)
                } else {
                    open = Array(open.sorted { abs(CGFloat($0) - middle) < abs(CGFloat($1) - middle) }.prefix(free.count)).sorted()
                }
                for (id, k) in zip(free, open) {
                    x[id] = slotX(k)
                    slotOf[id] = k
                }
                for id in row {
                    plan.lane[id] = li
                    rowOf[id] = rowCount
                }
                rowCount += 1
            }
            rowsOf.append(rows)
        }

        // How each link runs, and so how much room each row needs above and below.
        var over = Set<Int>(), under: [Int: CGFloat] = [:]
        for (i, l) in links.enumerated() {
            guard let ra = rowOf[l.from], let rb = rowOf[l.to], let xa = x[l.from], let xb = x[l.to] else { continue }
            if ra != rb {
                plan.routes[i] = .vertical
                continue
            }
            let between = x.contains { id, v in rowOf[id] == ra && v > min(xa, xb) + 1 && v < max(xa, xb) - 1 }
            if !between && xb > xa {
                plan.routes[i] = .over
                over.insert(ra)
            } else {
                plan.routes[i] = .under(deep: between)
                under[ra] = max(under[ra] ?? 0, between ? arcDeep : arcRise)
            }
        }

        // Down: the lanes and their rows.
        var y: CGFloat = 1
        var row = 0
        for (li, rows) in rowsOf.enumerated() {
            let top = y
            var cursor = top + laneHead
            for members in rows {
                if over.contains(row) { cursor += arcRise + 6 }
                let cy = cursor + nodeH / 2
                for id in members { plan.at[id] = CGPoint(x: x[id] ?? 0, y: cy) }
                cursor = cy + nodeH / 2
                if let dip = under[row] { cursor += dip + 14 }
                cursor += rowGap
                row += 1
            }
            let bottom = cursor - rowGap + lanePad
            plan.lanes.append((g.names[li], CGRect(x: 0.5, y: top, width: width - 1, height: bottom - top)))
            y = bottom + laneGap
        }
        plan.height = y - laneGap + 2
        return plan
    }

    /// `want.count` of the grid's columns, in order, nearest to where the parts want to be (ties go to the middle).
    private func bestSlots(_ want: [CGFloat], count: Int, slotX: (Int) -> CGFloat, blocked: Set<Int> = [], penalty: CGFloat = 0) -> [Int] {
        let n = want.count
        guard n < count else { return Array(0..<n) }
        var best = Array(0..<n)
        var bestCost = CGFloat.infinity
        func search(_ start: Int, _ picked: [Int]) {
            if picked.count == n {
                let cost = zip(picked, want).reduce(CGFloat(0)) { $0 + abs(slotX($1.0) - $1.1) + (blocked.contains($1.0) ? penalty : 0) }
                let centre = abs(CGFloat(picked.reduce(0, +)) / CGFloat(n) - CGFloat(count - 1) / 2)
                if cost + centre * 0.5 < bestCost {
                    bestCost = cost + centre * 0.5
                    best = picked
                }
                return
            }
            guard start < count else { return }
            for k in start..<count { search(k + 1, picked + [k]) }
        }
        search(0, [])
        return best
    }

    // MARK: Edges

    /// Each link's curve. Ends sharing a card's edge spread out, in the order of where they're going.
    private func edges(_ p: Plan) -> [Int: Edge] {
        var groups: [String: [(slot: Int, toward: CGFloat)]] = [:]
        for (i, l) in links.enumerated() {
            guard let a = p.at[l.from], let b = p.at[l.to], let route = p.routes[i] else { continue }
            switch route {
            case .vertical:
                let down = b.y > a.y
                groups["\(l.from)>\(down ? "B" : "T")", default: []].append((i * 2, b.x))
                groups["\(l.to)>\(down ? "T" : "B")", default: []].append((i * 2 + 1, a.x))
            case .over:
                groups["\(l.from)>T", default: []].append((i * 2, b.x))
                groups["\(l.to)>T", default: []].append((i * 2 + 1, a.x))
            case .under:
                groups["\(l.from)>B", default: []].append((i * 2, b.x))
                groups["\(l.to)>B", default: []].append((i * 2 + 1, a.x))
            }
        }
        var offset: [Int: CGFloat] = [:]
        for (_, members) in groups {
            let sorted = members.enumerated().sorted { ($0.element.toward, $0.offset) < ($1.element.toward, $1.offset) }.map(\.element)
            let n = sorted.count
            let spread = min(p.nodeW - 60, CGFloat(n - 1) * 18)
            for (j, m) in sorted.enumerated() {
                offset[m.slot] = n == 1 ? 0 : -spread / 2 + spread * CGFloat(j) / CGFloat(n - 1)
            }
        }
        var out: [Int: Edge] = [:]
        for (i, l) in links.enumerated() {
            guard let a = p.at[l.from], let b = p.at[l.to], let route = p.routes[i] else { continue }
            let da = offset[i * 2] ?? 0, db = offset[i * 2 + 1] ?? 0
            let crossing = p.lane[l.from] != p.lane[l.to]
            switch route {
            case .vertical:
                let down = b.y > a.y
                let s = CGPoint(x: a.x + da, y: a.y + (down ? nodeH / 2 : -nodeH / 2))
                let e = CGPoint(x: b.x + db, y: b.y + (down ? -nodeH / 2 - 2 : nodeH / 2 + 2))
                let dy = e.y - s.y
                out[i] = Edge(s: s, e: e, c1: CGPoint(x: s.x, y: s.y + dy * 0.5), c2: CGPoint(x: e.x, y: e.y - dy * 0.5),
                              dir: CGVector(dx: 0, dy: down ? 1 : -1), route: route, crossing: crossing)
            case .over:
                let s = CGPoint(x: a.x + da, y: a.y - nodeH / 2)
                let e = CGPoint(x: b.x + db, y: b.y - nodeH / 2 - 2)
                out[i] = Edge(s: s, e: e, c1: CGPoint(x: s.x, y: s.y - arcRise), c2: CGPoint(x: e.x, y: e.y - arcRise),
                              dir: CGVector(dx: 0, dy: 1), route: route, crossing: crossing)
            case .under(let deep):
                let dip = deep ? arcDeep : arcRise
                let s = CGPoint(x: a.x + da, y: a.y + nodeH / 2)
                let e = CGPoint(x: b.x + db, y: b.y + nodeH / 2 + 2)
                out[i] = Edge(s: s, e: e, c1: CGPoint(x: s.x, y: s.y + dip), c2: CGPoint(x: e.x, y: e.y + dip),
                              dir: CGVector(dx: 0, dy: -1), route: route, crossing: crossing)
            }
        }
        return out
    }

    private func end(_ e: Edge) -> CGPoint { CGPoint(x: e.e.x - e.dir.dx * 5, y: e.e.y - e.dir.dy * 5) }

    private func path(_ e: Edge) -> Path {
        var p = Path()
        p.move(to: e.s)
        p.addCurve(to: end(e), control1: e.c1, control2: e.c2)
        return p
    }

    private func point(_ e: Edge, t: CGFloat) -> CGPoint {
        let z = end(e)
        let u = 1 - t
        let x = u * u * u * e.s.x + 3 * u * u * t * e.c1.x + 3 * u * t * t * e.c2.x + t * t * t * z.x
        let y = u * u * u * e.s.y + 3 * u * u * t * e.c1.y + 3 * u * t * t * e.c2.y + t * t * t * z.y
        return CGPoint(x: x, y: y)
    }

    /// Where along an up-or-down curve it reaches height `y` (such curves only ever move one way).
    private func tAt(_ e: Edge, y: CGFloat) -> CGFloat {
        var lo: CGFloat = 0, hi: CGFloat = 1
        let rising = end(e).y > e.s.y
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if (point(e, t: mid).y < y) == rising { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// The heights at which a link leaves its own process's box and enters the other's.
    private func crossings(_ e: Edge, _ p: Plan, _ l: Story.Link) -> [CGFloat] {
        guard e.route == .vertical, let la = p.lane[l.from], let lb = p.lane[l.to] else { return [] }
        let a = p.lanes[la].rect, b = p.lanes[lb].rect
        return e.e.y > e.s.y ? [a.maxY, b.minY] : [a.minY, b.maxY]
    }

    private func style(_ l: Story.Link, _ e: Edge) -> (color: Color, width: CGFloat, dash: [CGFloat]) {
        let extra: CGFloat = e.crossing ? 0.15 : 0
        switch l.change {
        case .added: return (Color.added.opacity(0.9), 1.2 + extra, [])
        case .removed: return (Color.removed.opacity(0.7), 1 + extra, [4, 3])
        case .modified: return (Color.stroke.opacity(0.85), 1.05 + extra, [])
        case .unchanged: return (Color.stroke.opacity(0.42), 0.85 + extra, [])
        }
    }

    /// A narrow, sharp head, as in an engineering drawing.
    static func head(_ ctx: inout GraphicsContext, at tip: CGPoint, dir: CGVector, color: Color) {
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - dir.dx * 9 - dir.dy * 3.2, y: tip.y - dir.dy * 9 + dir.dx * 3.2))
        head.addLine(to: CGPoint(x: tip.x - dir.dx * 7, y: tip.y - dir.dy * 7))
        head.addLine(to: CGPoint(x: tip.x - dir.dx * 9 + dir.dy * 3.2, y: tip.y - dir.dy * 9 - dir.dx * 3.2))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }

    /// Where each label sits: on its link, at the first spot clear of the parts, the lanes' names and the other
    /// labels; links that cross a boundary choose first. A label with no room is left off until you point at a part.
    private func labelSpots(_ p: Plan, _ es: [Int: Edge]) -> [Int: CGPoint] {
        let font = NSFont(name: "STIXTwoText-Italic", size: 13.5) ?? NSFont.systemFont(ofSize: 13.5)
        let caps = NSFont(name: "STIXTwoText", size: 12) ?? NSFont.systemFont(ofSize: 12)
        var taken = p.at.values.map { CGRect(x: $0.x - p.nodeW / 2 - 4, y: $0.y - nodeH / 2 - 4, width: p.nodeW + 8, height: nodeH + 8) }
        for lane in p.lanes {
            let w = (lane.name as NSString).size(withAttributes: [.font: caps]).width * 1.2 + 24
            taken.append(CGRect(x: lane.rect.minX + 8, y: lane.rect.minY - 10, width: w, height: 20))
            // Keep labels off the boxes' edges, where the crossings are marked.
            taken.append(CGRect(x: lane.rect.minX, y: lane.rect.minY - 3, width: lane.rect.width, height: 6))
            taken.append(CGRect(x: lane.rect.minX, y: lane.rect.maxY - 3, width: lane.rect.width, height: 6))
        }
        var out: [Int: CGPoint] = [:]
        let order = links.indices.sorted { a, b in
            let ca = es[a]?.crossing ?? false, cb = es[b]?.crossing ?? false
            return ca != cb ? ca : a < b
        }
        for i in order where lit(links[i]) {
            guard let e = es[i], !links[i].label.isEmpty else { continue }
            let w = (links[i].label as NSString).size(withAttributes: [.font: font]).width + 12, h: CGFloat = 19
            var candidates: [CGPoint] = []
            switch e.route {
            case .over:
                let m = point(e, t: 0.5)
                candidates = [CGPoint(x: m.x, y: m.y - 11), m]
            case .under:
                let m = point(e, t: 0.5)
                candidates = [CGPoint(x: m.x, y: m.y + 11), m, CGPoint(x: m.x, y: m.y + 26)]
            case .vertical:
                // A link between processes is labelled out on the wire, between the two boxes, when there's room.
                let edges = crossings(e, p, links[i])
                if edges.count == 2 {
                    let q = point(e, t: tAt(e, y: (edges[0] + edges[1]) / 2))
                    candidates.append(q)
                }
                for nudge in [0, 0.55, -0.55] as [CGFloat] {
                    for t in [0.5, 0.4, 0.6, 0.32, 0.68] as [CGFloat] {
                        let q = point(e, t: t)
                        candidates.append(CGPoint(x: q.x + nudge * w, y: q.y))
                    }
                }
            }
            for q in candidates {
                let r = CGRect(x: q.x - w / 2, y: q.y - h / 2, width: w, height: h)
                guard r.minX >= 0, r.maxX <= p.width, !taken.contains(where: { $0.intersects(r) }) else { continue }
                taken.append(r.insetBy(dx: -3, dy: -2))
                out[i] = q
                break
            }
        }
        return out
    }
}

/// A part of the system as a box in a figure: its name as written in the code, what it does in italics, and in
/// small capitals whether it's new, changed, or what kind of thing it is. Context the change only talks to is dashed.
struct PartCard: View {
    let part: Story.Part
    var focused = false

    var body: some View {
        let context = part.change == .unchanged
        VStack(alignment: .leading, spacing: 4) {
            Text(part.name)
                .font(.mono(12.5, .medium))
                .foregroundStyle(context ? Color.text2 : Color.text1)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.middle)
            Text(part.role)
                .font(.serifItalic(14))
                .foregroundStyle(context ? Color.text3 : Color.text2)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Rectangle().fill(Color.paper))
        .overlay {
            switch part.change {
            case .added:
                Rectangle().strokeBorder(Color.added.opacity(focused ? 0.95 : 0.65), lineWidth: focused ? 1.1 : 0.8)
            case .unchanged:
                Rectangle().strokeBorder(Color.wash(focused ? 0.45 : 0.28), style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 2.5]))
            default:
                Rectangle().strokeBorder(Color.wash(focused ? 0.6 : 0.38), lineWidth: focused ? 1.1 : 0.8)
            }
        }
        .overlay(alignment: .topTrailing) {
            // What it is, lettered on the frame as a drawing labels a part.
            Text(tag)
                .font(.smallCaps(11))
                .tracking(0.9)
                .foregroundStyle(part.change == .added ? Color.added : Color.text3)
                .padding(.horizontal, 5)
                .background(Rectangle().fill(Color.paper))
                .fixedSize()
                .offset(x: -10, y: -7)
        }
        .help(help)
    }

    private var tag: String { part.change == .added ? "new" : ActorHead.word(part.kind) }

    private var help: String {
        switch part.change {
        case .added: "\(part.name) — new in this pull request"
        case .modified: "\(part.name) — its code changes"
        default: "\(part.name) — unchanged; the change talks to it"
        }
    }
}

/// The engineering idea the change rests on, boxed as a journal boxes an explainer: a heavy rule, "Box 1" and the
/// idea's usual name, the idea in general, then how this change uses it and where else you've met it.
struct ConceptBox: View {
    let number: Int
    let concept: Story.Concept

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.text1.opacity(0.7)).frame(height: 1.5)
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Box \(number)")
                        .font(.smallCaps(13.5))
                        .tracking(1.2)
                        .foregroundStyle(Color.sonar)
                    Text(concept.name)
                        .font(.serif(22))
                        .foregroundStyle(Color.text1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !concept.gist.isEmpty {
                    Text(Prose.sentence(concept.gist))
                        .font(.serif(17))
                        .lineSpacing(4)
                        .foregroundStyle(Color.text1.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !concept.here.isEmpty {
                    (Text("In this change. ").font(.runIn(16)) + Text(Prose.sentence(concept.here)))
                        .font(.serif(16))
                        .lineSpacing(3)
                        .foregroundStyle(Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !concept.kin.isEmpty {
                    (Text("Elsewhere. ").font(.runIn(16)) + Text(Prose.sentence(concept.kin)))
                        .font(.serif(16))
                        .lineSpacing(3)
                        .foregroundStyle(Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            Rule(opacity: 0.16)
        }
        .background(Color.wash(0.022))
    }
}

/// The names a newcomer would trip on, set as a paper's nomenclature: the name in code, its meaning in italics.
struct Nomenclature: View {
    let terms: [Story.Term]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Nomenclature")
                .padding(.top, 2)
            ForEach(terms, id: \.self) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.term)
                        .font(.mono(12, .medium))
                        .foregroundStyle(Color.text1)
                    Text(Prose.sentence(t.meaning))
                        .font(.serifItalic(15))
                        .foregroundStyle(Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rule(opacity: 0.06) }
            }
        }
        .textSelection(.enabled)
    }
}
