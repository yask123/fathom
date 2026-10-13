// The diagrams under the map: flows as sequence diagrams, the interfaces whose shape changes, and the footprint —
// where the change lands. All of them light up the map when hovered.

import SwiftUI

// MARK: - Helpers shared by the diagrams

extension PRSession {
    /// The layer depth (0 = surface) of a component, for its colour.
    func depth(of componentID: String) -> Int {
        guard let c = map.component(componentID) else { return 0 }
        return map.layers.firstIndex { $0.id == c.layer } ?? 0
    }

    /// The change on the edge a flow step follows, if the map has one.
    func edgeChange(from: String, to: String) -> Change {
        map.edges.first { $0.from == from && $0.to == to }?.change
            ?? map.edges.first { $0.from == to && $0.to == from }?.change
            ?? .unchanged
    }

    /// The most specific changed component a file belongs to.
    func component(forPath path: String) -> Component? {
        let owners = map.components.filter { c in
            c.files.contains { f in path == f || path.hasSuffix("/" + f) || f.hasSuffix("/" + path) }
        }
        return owners.first { $0.change != .unchanged } ?? owners.first
    }

    /// The component an interface belongs to: one named like it, else the one owning its file.
    func owner(of contract: Contract) -> Component? {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let n = norm(contract.name)
        if let byName = map.components.first(where: { c in
            let m = norm(c.name)
            return !m.isEmpty && (m == n || (n.count > 3 && (m.contains(n) || n.contains(m))))
        }) { return byName }
        return component(forPath: contract.file)
    }

    /// Every component a file belongs to, changed ones first.
    func owners(ofPath path: String) -> [Component] {
        let all = map.components.filter { c in
            c.files.contains { f in path == f || path.hasSuffix("/" + f) || f.hasSuffix("/" + path) }
        }
        return all.filter { $0.change != .unchanged } + all.filter { $0.change == .unchanged }
    }

    /// Lines changed per component, 0...1 against the busiest one.
    var componentWeights: [String: Double] {
        guard let diff else { return [:] }
        var lines: [String: Int] = [:]
        for f in diff.files where f.noise == nil {
            for c in map.components where c.files.contains(where: { f.path == $0 || f.path.hasSuffix("/" + $0) || $0.hasSuffix("/" + f.path) }) {
                lines[c.id, default: 0] += f.additions + f.deletions
            }
        }
        let top = Double(lines.values.max() ?? 1)
        return lines.mapValues { top > 0 ? sqrt(Double($0) / top) : 0 }
    }
}

// MARK: - Flows

/// Lifelines for the components a flow passes through, and an arrow per step.
struct SequenceDiagram: View {
    @Bindable var session: PRSession
    let flow: Flow
    let active: Int?

    private let rowH: CGFloat = 34
    @State private var width: CGFloat = 600

    /// Two staggered rows of names when lifelines are too close for one.
    private var staggered: Bool { width / CGFloat(max(parts.count, 1)) < 150 }
    private var headerH: CGFloat { staggered ? 54 : 26 }

    private var parts: [String] {
        var seen: [String] = []
        for s in flow.steps {
            if !seen.contains(s.from) { seen.append(s.from) }
            if !seen.contains(s.to) { seen.append(s.to) }
        }
        return seen
    }

    var body: some View {
        let parts = self.parts
        let lit = session.litComponents
        GeometryReader { geo in
            let colW = geo.size.width / CGFloat(max(parts.count, 1))
            let x: (String) -> CGFloat = { id in (CGFloat(parts.firstIndex(of: id) ?? 0) + 0.5) * colW }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for id in parts {
                        let cx = x(id)
                        var p = Path()
                        p.move(to: CGPoint(x: cx, y: headerH + 6))
                        p.addLine(to: CGPoint(x: cx, y: size.height - 4))
                        ctx.stroke(p, with: .color(Color.depth(session.depth(of: id)).opacity(0.3)),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    }
                    for (k, step) in flow.steps.enumerated() {
                        let y = rowY(k)
                        let x0 = x(step.from), x1 = x(step.to)
                        let on = active == k
                        let done = active.map { k < $0 } ?? false
                        let change = session.edgeChange(from: step.from, to: step.to)
                        var color: Color = change == .unchanged ? .white : change.color
                        var alpha = change == .unchanged ? 0.38 : 0.85
                        if on { color = .sonar; alpha = 1 } else if done { color = .sonar; alpha = 0.45 }
                        var path = Path()
                        if step.from == step.to {
                            path.move(to: CGPoint(x: x0, y: y - 6))
                            path.addCurve(to: CGPoint(x: x0, y: y + 6),
                                          control1: CGPoint(x: x0 + 30, y: y - 10), control2: CGPoint(x: x0 + 30, y: y + 10))
                        } else {
                            path.move(to: CGPoint(x: x0, y: y))
                            path.addLine(to: CGPoint(x: x1 + (x1 > x0 ? -5 : 5), y: y))
                        }
                        if on {
                            ctx.stroke(path, with: .color(Color.sonar.opacity(0.3)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        }
                        ctx.stroke(path, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: on ? 2 : 1.3, lineCap: .round))
                        // Arrowhead.
                        let dir: CGFloat = step.from == step.to ? -1 : (x1 > x0 ? 1 : -1)
                        let tip = step.from == step.to ? CGPoint(x: x0 + 1, y: y + 6) : CGPoint(x: x1 - dir * 2, y: y)
                        var head = Path()
                        head.move(to: tip)
                        head.addLine(to: CGPoint(x: tip.x - dir * 6, y: tip.y - 3.5))
                        head.addLine(to: CGPoint(x: tip.x - dir * 6, y: tip.y + 3.5))
                        head.closeSubpath()
                        ctx.fill(head, with: .color(color.opacity(alpha)))
                        // Activation dot where the call lands.
                        ctx.fill(Path(ellipseIn: CGRect(x: x1 - 2.5, y: y - 2.5, width: 5, height: 5)),
                                 with: .color(Color.depth(session.depth(of: step.to)).opacity(on ? 1 : 0.6)))
                    }
                }

                ForEach(Array(parts.enumerated()), id: \.element) { index, id in
                    let c = session.map.component(id)
                    let depth = session.depth(of: id)
                    let dim = lit.map { !$0.contains(id) } ?? false
                    let room = staggered ? colW * 2 - 10 : colW - 6
                    let y: CGFloat = staggered && index % 2 == 1 ? 39 : 11
                    Text(c?.name ?? id)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.depth(depth))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.middle)
                        .help(c.map { "\($0.name) — \($0.summary)" } ?? id)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.depth(depth).opacity(0.1)))
                        .overlay(Capsule().strokeBorder((c?.change ?? .unchanged) == .unchanged ? Color.white.opacity(0.08) : (c?.change ?? .unchanged).color.opacity(0.55), lineWidth: 0.75))
                        .frame(maxWidth: room)
                        .position(x: min(max(x(id), room / 2), geo.size.width - room / 2), y: y)
                        .opacity(dim ? 0.4 : 1)
                        .onHover { h in
                            guard !QA.noHover else { return }
                            withAnimation(Motion.snappy) {
                                session.hoveredComponent = h ? id : (session.hoveredComponent == id ? nil : session.hoveredComponent)
                            }
                        }
                }

                ForEach(Array(flow.steps.enumerated()), id: \.offset) { k, step in
                    let x0 = x(step.from), x1 = x(step.to)
                    let on = active == k
                    let labelW = min(StrataLayout.textWidth(step.label) * 0.9 + 30, geo.size.width - 8)
                    let mid = step.from == step.to ? x0 + 14 + labelW / 2 : (x0 + x1) / 2
                    HStack(spacing: 5) {
                        Text("\(k + 1)")
                            .font(.mono(9, .bold))
                            .foregroundStyle(on ? Color.ink : Color.text3)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(on ? Color.sonar : Color.white.opacity(0.07)))
                        Text(step.label)
                            .font(.system(size: 11, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Color.text1 : Color.text2)
                            .lineLimit(1)
                    }
                    .frame(width: labelW)
                    .position(x: min(max(mid, labelW / 2 + 2), geo.size.width - labelW / 2 - 2), y: rowY(k) - 11)
                    .contentShape(Rectangle())
                    .onTapGesture { session.jump(toStep: k, in: flow.id) }
                }
            }
        }
        .frame(height: headerH + 22 + CGFloat(flow.steps.count) * rowH)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(Motion.soft, value: active)
    }

    private func rowY(_ k: Int) -> CGFloat { headerH + 30 + CGFloat(k) * rowH }
}

// MARK: - Interfaces

struct InterfaceCard: View {
    @Bindable var session: PRSession
    let contract: Contract
    var fill = false
    @State private var hover = false

    var body: some View {
        let owner = session.owner(of: contract)
        let depth = owner.map { session.depth(of: $0.id) }
        let lit = session.litComponents.map { set in owner.map { set.contains($0.id) } ?? false }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(depth.map { Color.depth($0) } ?? Color.text2)
                Text(contract.name)
                    .font(.mono(12.5, .semibold))
                    .foregroundStyle(Color.text1)
                    .lineLimit(contract.name.contains(" ") ? 2 : 1)
                    .minimumScaleFactor(0.72)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                ChangeTag(change: contract.change)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background((depth.map { Color.depth($0) } ?? Color.white).opacity(0.07))

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(contract.members.prefix(8).enumerated()), id: \.offset) { _, m in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(sign(m.change))
                            .font(.mono(11, .bold))
                            .foregroundStyle(m.change == .unchanged ? Color.text3 : m.change.color)
                            .frame(width: 10)
                        Text(m.name)
                            .font(.mono(11))
                            .foregroundStyle(m.change == .unchanged ? Color.text3 : Color.text1.opacity(0.9))
                            .strikethrough(m.change == .removed, color: Color.removed.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if contract.members.count > 8 {
                    Text("+\(contract.members.count - 8) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                        .padding(.leading, 17)
                }
                if contract.members.isEmpty {
                    Text(contract.change == .added ? "new" : contract.change == .removed ? "removed" : "changed")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let owner {
                HStack(spacing: 5) {
                    Image(systemName: Glyph.component(owner.kind)).font(.system(size: 8.5, weight: .bold))
                    Text(owner.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Color.depth(depth ?? 0).opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: fill ? .infinity : 252, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x0B0F16).opacity(0.9)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hover ? (depth.map { Color.depth($0) } ?? Color.sonar).opacity(0.6) : Color.white.opacity(0.08), lineWidth: 0.9)
        }
        .opacity(lit == false ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { h in
            guard !QA.noHover else { return }
            hover = h
            withAnimation(Motion.snappy) {
                session.hoveredFile = h ? contract.file : (session.hoveredFile == contract.file ? nil : session.hoveredFile)
            }
        }
        .onTapGesture {
            if let owner, owner.id != session.selectedComponent {
                session.select(owner.id)
            } else {
                session.go(toFile: contract.file, containing: contract.name)
            }
        }
        .help(owner.map { "\(contract.file) — click to see \($0.name)'s code" } ?? "\(contract.file) — click to read it in Changes")
        .animation(Motion.snappy, value: hover)
    }

    private var icon: String {
        switch contract.kind {
        case "endpoint": "network"
        case "type": "curlybraces"
        case "table": "tablecells"
        case "event": "bolt.horizontal"
        case "config": "slider.horizontal.3"
        case "function": "function"
        case "cli": "terminal"
        default: "square.on.square"
        }
    }

    private func sign(_ c: Change) -> String {
        switch c {
        case .added: "+"
        case .removed: "−"
        case .modified: "~"
        case .unchanged: "·"
        }
    }
}

struct ChangeTag: View {
    let change: Change

    var body: some View {
        if change != .unchanged {
            Text(change == .added ? "NEW" : change == .removed ? "GONE" : "CHANGED")
                .font(.system(size: 8, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(change.color))
        }
    }
}

// MARK: - Footprint

struct Footprint: View {
    @Bindable var session: PRSession
    @State private var hover: String?

    struct Group {
        var id: String
        var label: String
        var color: Color
        var component: String?
        var files: [DiffFile]
        var mechanical = false
        var owners: [String] = []
        var weight: Double { files.reduce(0) { $0 + Double(max($1.additions + $1.deletions, 1)) } }
    }

    struct Tile {
        var file: DiffFile
        var rect: CGRect
        var group: Group
    }

    var body: some View {
        GeometryReader { geo in
            let (groupRects, tiles) = layout(in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 10, dy: 10))
            let lit = session.litComponents
            let maxLines = Double(tiles.map { $0.file.additions + $0.file.deletions }.max() ?? 1)
            Canvas { ctx, _ in
                for (g, r) in groupRects where r.width > 4 && r.height > 4 {
                    if g.files.count > 1 || r.height > 30 {
                        ctx.stroke(Path(roundedRect: r, cornerRadius: 8), with: .color(g.color.opacity(g.mechanical ? 0.15 : 0.22)), lineWidth: 0.75)
                    }
                    if r.width > 70 && r.height > 34 {
                        ctx.draw(Text(g.label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8)
                                    .foregroundColor(g.color.opacity(g.mechanical ? 0.55 : 0.9)),
                                 in: CGRect(x: r.minX + 7, y: r.minY + 3, width: r.width - 14, height: 13))
                    }
                }
                for t in tiles {
                    let r = t.rect.insetBy(dx: 1.5, dy: 1.5)
                    guard r.width > 1, r.height > 1 else { continue }
                    let lines = Double(t.file.additions + t.file.deletions)
                    let intensity = sqrt(lines / max(maxLines, 1))
                    let isHover = hover == t.file.path
                    let dim = lit.map { set in !t.group.owners.contains { set.contains($0) } } ?? false
                    let base = t.group.mechanical ? Color.white : t.group.color
                    var fill = t.group.mechanical ? 0.04 : 0.08 + 0.2 * intensity
                    if isHover { fill += 0.15 }
                    if dim { fill *= 0.4 }
                    let shape = Path(roundedRect: r, cornerRadius: 5)
                    ctx.fill(shape, with: .color(base.opacity(fill)))
                    ctx.stroke(shape, with: .color(base.opacity(isHover ? 0.8 : dim ? 0.12 : 0.3)), lineWidth: isHover ? 1.2 : 0.6)
                    // Added vs removed, along the bottom.
                    if r.width > 14 && r.height > 12 && !t.group.mechanical {
                        let total = max(Double(t.file.additions + t.file.deletions), 1)
                        let wAdd = (r.width - 8) * CGFloat(Double(t.file.additions) / total)
                        let y = r.maxY - 5
                        ctx.fill(Path(roundedRect: CGRect(x: r.minX + 4, y: y, width: max(wAdd, 0), height: 2), cornerRadius: 1),
                                 with: .color(Color.added.opacity(dim ? 0.3 : 0.85)))
                        ctx.fill(Path(roundedRect: CGRect(x: r.minX + 4 + wAdd, y: y, width: max(r.width - 8 - wAdd, 0), height: 2), cornerRadius: 1),
                                 with: .color(Color.removed.opacity(dim ? 0.3 : 0.85)))
                    }
                    if r.width > 58 && r.height > 26 {
                        ctx.draw(Text(t.file.name).font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(Color.text1.opacity(dim ? 0.35 : t.group.mechanical ? 0.5 : 0.88)),
                                 in: CGRect(x: r.minX + 6, y: r.minY + 5, width: r.width - 12, height: 14))
                    }
                    if r.width > 58 && r.height > 44 {
                        ctx.draw(Text("+\(t.file.additions) −\(t.file.deletions)").font(.mono(9.5))
                                    .foregroundColor(Color.text3.opacity(dim ? 0.5 : 1)),
                                 at: CGPoint(x: r.minX + 6, y: r.minY + 26), anchor: .leading)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !QA.noHover else { return }
                switch phase {
                case .active(let p):
                    let path = tiles.first { $0.rect.contains(p) }?.file.path
                    if path != hover {
                        hover = path
                        session.hoveredFile = path
                    }
                case .ended:
                    hover = nil
                    session.hoveredFile = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                guard let t = tiles.first(where: { $0.rect.contains(p) }) else { return }
                if let owner = session.owners(ofPath: t.file.path).first, !t.group.mechanical {
                    session.select(owner.id)
                } else {
                    session.go(toFile: t.file.path, containing: "")
                }
            }
            .help(hover.map { path in
                let f = session.diff?.file(path: path)
                return "\(path)\n+\(f?.additions ?? 0) −\(f?.deletions ?? 0)"
            } ?? "")
        }
    }

    private func groups() -> [Group] {
        guard let diff = session.diff else { return [] }
        // Files whose every change sits in a "skip" chapter are set aside with the lockfiles.
        let skipped = Set(session.brief.chapters.filter { $0.attention == .skip }.flatMap(\.hunks))
        var byKey: [String: Group] = [:]
        var order: [String] = []
        for f in diff.files {
            let key: String, label: String, color: Color, comp: String?
            var ownerIDs: [String] = []
            let skipOnly = !f.hunks.isEmpty && f.hunks.allSatisfy { skipped.contains($0.id) }
            if f.noise != nil || skipOnly {
                key = "~mechanical"; label = "Set aside"; color = .text3; comp = nil
            } else if let c = session.owners(ofPath: f.path).first {
                let owners = session.owners(ofPath: f.path)
                key = "c:" + owners.map(\.id).sorted().joined(separator: "+")
                label = owners.count > 1 ? "\(c.name) +\(owners.count - 1)" : c.name
                color = Color.depth(session.depth(of: c.id))
                comp = c.id
                ownerIDs = owners.map(\.id)
            } else {
                let parts = f.path.split(separator: "/")
                let dir = parts.count > 1 ? parts.prefix(min(2, parts.count - 1)).joined(separator: "/") : "/"
                key = "d:" + dir; label = dir; color = .calm; comp = nil
            }
            if byKey[key] == nil {
                byKey[key] = Group(id: key, label: label, color: color, component: comp, files: [], mechanical: key == "~mechanical",
                                   owners: ownerIDs)
                order.append(key)
            }
            byKey[key]!.files.append(f)
        }
        return order.compactMap { byKey[$0] }
    }

    private func layout(in rect: CGRect) -> ([(Group, CGRect)], [Tile]) {
        let gs = groups()
        guard !gs.isEmpty, rect.width > 10, rect.height > 10 else { return ([], []) }
        // Mechanical changes are real but not where attention goes: cap their area.
        let signal = gs.filter { !$0.mechanical }.reduce(0) { $0 + $1.weight }
        let weights = gs.map { g in g.mechanical && signal > 0 ? min(g.weight, signal * 0.14) : g.weight }
        let groupRects = Treemap.squarify(weights, in: rect)
        var tiles: [Tile] = []
        var placed: [(Group, CGRect)] = []
        for (g, r) in zip(gs, groupRects) {
            placed.append((g, r))
            let labelled = r.width > 70 && r.height > 34
            let inner = CGRect(x: r.minX + 3, y: r.minY + (labelled ? 18 : 3), width: r.width - 6, height: r.height - (labelled ? 21 : 6))
            guard inner.width > 2, inner.height > 2 else { continue }
            let fileRects = Treemap.squarify(g.files.map { Double(max($0.additions + $0.deletions, 1)) }, in: inner)
            for (f, fr) in zip(g.files, fileRects) { tiles.append(Tile(file: f, rect: fr, group: g)) }
        }
        return (placed, tiles)
    }
}

/// Squarified treemap (Bruls, Huizing & van Wijk): rectangles close to square, areas proportional to weight.
enum Treemap {
    static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let order = weights.indices.sorted { weights[$0] > weights[$1] }
        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { max(weights[$0], 0) * scale }
        var remaining = rect
        var row: [Int] = []

        func worst(_ idx: [Int], _ side: Double) -> Double {
            let a = idx.map { areas[$0] }
            let s = a.reduce(0, +)
            guard s > 0, let mx = a.max(), let mn = a.min(), mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), s * s / (side * side * mn))
        }

        func place(_ idx: [Int]) {
            let s = idx.reduce(0) { $0 + areas[$1] }
            guard s > 0 else { return }
            if remaining.width >= remaining.height {
                let w = CGFloat(s) / max(remaining.height, 0.0001)
                var y = remaining.minY
                for i in idx {
                    let h = CGFloat(areas[i]) / max(w, 0.0001)
                    result[order[i]] = CGRect(x: remaining.minX, y: y, width: w, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: max(remaining.width - w, 0), height: remaining.height)
            } else {
                let h = CGFloat(s) / max(remaining.width, 0.0001)
                var x = remaining.minX
                for i in idx {
                    let w = CGFloat(areas[i]) / max(h, 0.0001)
                    result[order[i]] = CGRect(x: x, y: remaining.minY, width: w, height: h)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: max(remaining.height - h, 0))
            }
        }

        var i = 0
        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [i], side) <= worst(row, side) {
                row.append(i)
                i += 1
            } else {
                place(row)
                row = []
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}
