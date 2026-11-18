// The Trace tab: a pull request as one picture. Each part of the system is a rail; the request is a single lit line
// that runs along a rail and crosses to the next, left to right through time. Where the change took a new road the
// line is green, where it does something differently it's amber, and the road it used to take is left as a dashed
// ghost. Words are kept off the picture: a caption under it reads out one step at a time as you point at it, step
// through it, or play it. Under that, the forks in the road and the code in chapters.

import SwiftUI

/// Which telling of the journey the stage shows.
enum FlowMode: String, CaseIterable, Identifiable {
    case before, diff, after
    var id: String { rawValue }
}

struct TraceView: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: PRSession
    @State private var mode: FlowMode = FlowMode(rawValue: QA.flow) ?? .diff
    /// The step the playhead is pinned on, by its place in the flow; nil shows the whole journey at once.
    @State private var cursor: Int? = QA.step
    /// The step under the pointer: a preview, gone when the pointer leaves.
    @State private var hover: Int?
    @State private var playing = false
    @State private var player: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if session.trace.isEmpty, let failure = session.traceState.failure {
                TraceFailure(message: failure) { session.sound() }
            } else {
                ScrollView {
                    TracePage(session: session, mode: mode, cursor: cursor, hover: $hover, playing: playing,
                              setMode: set, pick: pick, togglePlay: togglePlay)
                        .padding(.horizontal, 40)
                        .padding(.top, store.focus ? 52 : 24)
                        .padding(.bottom, 34)
                        .frame(maxWidth: 1500)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                // FATHOM_SECTION=end opens the page at its end, for screenshots.
                .defaultScrollAnchor(QA.section == nil ? .top : .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.rightArrow) { key { step(1) } }
        .onKeyPress(.leftArrow) { key { step(-1) } }
        .onKeyPress(.space) { key { togglePlay() } }
        .onKeyPress(.return) { key { openCurrent() } }
        .onKeyPress(.escape) {
            guard !Typing.active, cursor != nil else { return .ignored }
            stop()
            withAnimation(Motion.snappy) { cursor = nil }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "bda"), phases: .down) { press in
            guard !Typing.active, press.modifiers.isEmpty else { return .ignored }
            set(press.characters == "b" ? .before : press.characters == "a" ? .after : .diff)
            return .handled
        }
        .onAppear { focused = true }
        .onChange(of: session.tab) { _, tab in
            focused = tab == .brief
            if tab != .brief { stop() }
        }
        .onChange(of: session.compose == nil) { _, closed in if closed && session.tab == .brief { focused = true } }
        .onDisappear { stop() }
    }

    private func key(_ action: () -> Void) -> KeyPress.Result {
        guard !Typing.active, session.tab == .brief else { return .ignored }
        action()
        return .handled
    }

    // MARK: The playhead

    private var visible: [Trace.Step] {
        session.trace.flow.filter { mode == .before ? $0.inBefore : mode == .after ? $0.inAfter : true }
    }

    private func set(_ next: FlowMode) {
        guard next != mode else { return }
        stop()
        withAnimation(.smooth(duration: 0.4)) {
            mode = next
            // The playhead stays on its step when that step is in the new telling.
            if let c = cursor, !session.trace.flow.contains(where: { $0.id == c && (next == .before ? $0.inBefore : next == .after ? $0.inAfter : true) }) {
                cursor = nil
            }
        }
    }

    private func pick(_ step: Int) {
        StageProbe.picked = step
        stop()
        withAnimation(Motion.snappy) { cursor = cursor == step ? nil : step }
    }

    private func step(_ delta: Int) {
        stop()
        let steps = visible
        guard !steps.isEmpty else { return }
        let here = cursor.flatMap { c in steps.firstIndex { $0.id == c } }
        let next = here.map { min(max($0 + delta, 0), steps.count - 1) } ?? (delta > 0 ? 0 : steps.count - 1)
        withAnimation(Motion.snappy) { cursor = steps[next].id }
    }

    private func togglePlay() {
        if playing { stop(); return }
        let steps = visible
        guard !steps.isEmpty else { return }
        playing = true
        // From the playhead on, or from the top when it's at the end or nowhere.
        var start = cursor.flatMap { c in steps.firstIndex { $0.id == c } }.map { $0 + 1 } ?? 0
        if start >= steps.count { start = 0 }
        player = Task { @MainActor in
            for s in steps[start...] {
                withAnimation(Motion.snappy) { cursor = s.id }
                try? await Task.sleep(for: .milliseconds(1250))
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            withAnimation(Motion.soft) { cursor = nil }
            playing = false
        }
    }

    private func stop() {
        player?.cancel()
        player = nil
        playing = false
    }

    private func openCurrent() {
        guard let c = cursor, let s = session.trace.flow.first(where: { $0.id == c }), !s.hunk.isEmpty else { return }
        session.go(toHunk: s.hunk)
    }
}

/// The page itself, without its scrolling or its keys, so it can also be drawn off screen.
struct TracePage: View {
    @Bindable var session: PRSession
    let mode: FlowMode
    let cursor: Int?
    @Binding var hover: Int?
    let playing: Bool
    let setMode: (FlowMode) -> Void
    let pick: (Int) -> Void
    let togglePlay: () -> Void

    var body: some View {
        let t = session.trace
        let focus = cursor ?? hover
        VStack(alignment: .leading, spacing: 0) {
            TraceHeader(session: session)

            StagePanel {
                if t.flow.isEmpty {
                    // The stage waits for its first step, so the parts take their places once instead of shuffling
                    // along as each is named; until then their names arrive as a line, and the room is kept.
                    Drawing(label: session.traceState.isRunning
                            ? (t.cast.isEmpty ? "tracing" : t.cast.map(\.name).joined(separator: "  ·  "))
                            : "no trace came back")
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: session.traceState.isRunning ? 420 : 120)
                } else {
                    StageView(trace: t, mode: mode, focus: focus, cursor: cursor, hover: $hover, pick: pick)
                }
            }
            .padding(.top, 22)

            CaptionBar(trace: t, mode: mode, focus: focus.flatMap { f in t.flow.first { $0.id == f } }, pinned: cursor != nil,
                       playing: playing, togglePlay: togglePlay, setMode: setMode) { session.go(toHunk: $0.hunk) }
                .padding(.top, 14)
                .opacity(t.flow.isEmpty ? 0.35 : 1)

            if !t.forks.isEmpty {
                ForkStrip(session: session, forks: t.forks, hover: $hover)
                    .padding(.top, 34)
            }

            ChapterRibbon(session: session)
                .padding(.top, 34)
        }
    }
}

// MARK: - Header

/// What the pull request does, in one line.
struct TraceHeader: View {
    @Bindable var session: PRSession

    var body: some View {
        let t = session.trace
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if !t.kind.isEmpty {
                    Text(Glyph.kindWord(t.kind))
                        .foregroundStyle(Color.signal)
                    dot
                }
                if let d = session.diff {
                    DiffStat(additions: d.additions, deletions: d.deletions, bar: false, size: 11)
                    dot
                    Text("\(d.files.count) file\(d.files.count == 1 ? "" : "s")")
                }
                if session.traceState.isRunning {
                    dot
                    ReadingClock(session: session)
                }
            }
            .font(.mono(11, .medium))
            .foregroundStyle(Color.text3)
            .frame(height: 16)

            Text(t.headline.isEmpty ? (session.detail?.title ?? "") : Prose.title(t.headline))
                .font(.display(38, .semibold))
                .tracking(-1.1)
                .lineSpacing(2)
                .foregroundStyle(t.headline.isEmpty
                                 ? AnyShapeStyle(Color.text3)
                                 : AnyShapeStyle(LinearGradient(colors: [.text1, .headlineEnd], startPoint: .leading, endPoint: .trailing)))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1040, alignment: .leading)
                .textSelection(.enabled)
                .animation(nil, value: t.headline)
        }
    }

    private var dot: some View { Text("·").foregroundStyle(Color.text3.opacity(0.6)) }
}

/// "reading 0:04", with a small ping, while Claude works.
struct ReadingClock: View {
    @Bindable var session: PRSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            HStack(alignment: .center, spacing: 6) {
                Pip().frame(width: 10, height: 10)
                Text("reading \(Fmt.clock(tl.date.timeIntervalSince(started)))")
                    .monospacedDigit()
            }
            .frame(height: 16)
        }
    }

    private var started: Date {
        for state in [session.traceState, session.briefState] {
            if case .running(let d) = state { return d }
        }
        return .now
    }
}

/// Something still being written: a scan line and a word.
struct Drawing: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            ScanBar().frame(width: 150, height: 2)
            Text(label)
                .font(.mono(11))
                .foregroundStyle(Color.text3)
                .lineLimit(1)
                .animation(nil, value: label)
        }
        .frame(height: 30)
    }
}

// MARK: - The stage

/// The ground the trace is drawn on: a dark pane with a faint grid that fades towards its edges.
struct StagePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(Color.stage)
                    DotGrid(step: 24)
                        .mask(RadialGradient(colors: [.black.opacity(0.9), .black.opacity(0.15)], center: .center, startRadius: 80, endRadius: 760))
                        .clipShape(shape)
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Color.wash(0.2), Color.wash(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
    }
}

/// Where everything on the stage goes: the rails, the line and its pieces, the dots, and the words beside them.
struct StagePlan {
    enum Style { case live, ghost, handoff }

    /// A piece of line. `at` and `span` say when it's drawn as the trace draws itself, in steps.
    struct Seg {
        var path: Path
        var step: Int?
        var color: Color
        var glow: Color
        var style: Style
        var at: Double
        var span: Double
    }

    enum DotKind { case start, stop, knot, end, ghost, broken }

    struct Dot {
        var p: CGPoint
        var step: Int?
        var kind: DotKind
        var color: Color
        var at: Double
    }

    enum Side { case above, below, beside }

    struct Label: Identifiable {
        var id: Int
        var step: Trace.Step
        var p: CGPoint
        var side: Side
        var width: CGFloat
        var ghost: Bool
        var at: Double
        var color: Color
    }

    struct Lane {
        var name: String
        var hue: Color
        var rect: CGRect
    }

    struct Row: Identifiable {
        var id: String
        var actor: Trace.Actor
        var y: CGFloat
        var hue: Color
    }

    struct Column {
        var step: Int
        var x0: CGFloat
        var dot: CGFloat
        var status: Trace.Status
        var number: Int
    }

    var width: CGFloat = 0
    var height: CGFloat = 0
    var headerW: CGFloat = 0
    var lead: CGFloat = 30
    var colW: CGFloat = 0
    var rows: [Row] = []
    var lanes: [Lane] = []
    var columns: [Column] = []
    var segs: [Seg] = []
    var dots: [Dot] = []
    var labels: [Label] = []
    /// Each step's own crossing, for the spark that runs it.
    var curves: [Int: Path] = [:]
    /// What went wrong, hung by the step where it did, on the side its words aren't.
    var pain: (p: CGPoint, text: String, at: Double)?
    /// How far the trace has to be drawn to be whole.
    var whole: Double { Double(columns.count) + 1.6 }

    static let top: CGFloat = 42
    static let bottom: CGFloat = 64

    static func gap(_ rows: Int) -> CGFloat {
        switch rows {
        case ...3: 82
        case 4: 76
        case 5: 68
        case 6: 62
        default: 56
        }
    }

    static func height(_ trace: Trace) -> CGFloat {
        top + gap(trace.cast.count) * CGFloat(max(trace.cast.count, 1)) + bottom
    }

    /// The cast with parts that run together on neighbouring rails, in the order the journey first meets each
    /// process; the person who starts it on top.
    static func ordered(_ cast: [Trace.Actor]) -> [Trace.Actor] {
        var groups: [(key: String, members: [Trace.Actor])] = []
        for a in cast {
            let key = a.isPerson ? "\u{1}person" : a.place
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].members.append(a) } else { groups.append((key, [a])) }
        }
        return groups.flatMap(\.members)
    }

    func column(at x: CGFloat) -> Column? {
        guard colW > 0, x >= headerW + lead else { return nil }
        let c = Int((x - headerW - lead) / colW)
        return columns.indices.contains(c) ? columns[c] : nil
    }

    init(trace: Trace, mode: FlowMode, width: CGFloat) {
        self.width = width
        let actors = Self.ordered(trace.cast)
        let gap = Self.gap(actors.count)
        height = Self.height(trace)
        headerW = min(max(width * 0.165, 150), 204)

        // Rails, and the processes they belong to.
        var hueOf: [String: Color] = [:]
        for a in actors where !a.isPerson && !a.place.isEmpty && hueOf[a.place] == nil {
            hueOf[a.place] = Color.lanes[hueOf.count % Color.lanes.count]
        }
        for (i, a) in actors.enumerated() {
            let y = Self.top + gap * (CGFloat(i) + 0.5)
            let hue = a.isPerson || a.place.isEmpty ? Color.text2 : (hueOf[a.place] ?? .signal)
            rows.append(Row(id: a.id, actor: a, y: y, hue: hue))
            guard !a.isPerson, !a.place.isEmpty else { continue }
            let band = CGRect(x: 6, y: y - gap / 2 + 3, width: width - 12, height: gap - 6)
            if let l = lanes.last, l.name == a.place, abs(l.rect.maxY + 6 - band.minY) < 1 {
                lanes[lanes.count - 1].rect = l.rect.union(band)
            } else {
                lanes.append(Lane(name: a.place, hue: hue, rect: band))
            }
        }
        let ys = Dictionary(rows.map { ($0.id, $0.y) }, uniquingKeysWith: { a, _ in a })
        func Y(_ id: String) -> CGFloat { ys[id] ?? Self.top }

        // One column per step of the telling.
        let shown = trace.flow.filter { mode == .before ? $0.inBefore : mode == .after ? $0.inAfter : true }
        colW = min((width - headerW - lead - 50) / CGFloat(max(shown.count, 1)), 210)
        let j = min(colW * 0.17, 25)   // half the width of a crossing
        columns = shown.enumerated().map { c, s in
            let x0 = headerW + lead + colW * CGFloat(c)
            return Column(step: s.id, x0: x0, dot: x0 + 2 * j, status: s.status, number: mode == .diff ? s.id + 1 : c + 1)
        }
        let columnOf = Dictionary(columns.enumerated().map { ($0.element.step, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let hurt: Int? = mode == .after || trace.breaks < 0 ? nil : trace.flow.first { $0.id == trace.breaks && $0.inBefore }?.id

        func ink(_ s: Trace.Step) -> (Color, Color) {
            if s.id == hurt && (mode == .before || s.status == .removed) { return (.removed, .removed) }
            if mode == .before { return (.trace, .signal) }
            switch s.status {
            case .added: return (.added, .added)
            case .changed: return (.changed, .changed)
            case .removed: return (.removed, .removed)
            case .same: return (.trace, .signal)
            }
        }
        func crossing(_ s: Trace.Step, _ col: Column) -> (Path, CGPoint, CGPoint) {
            let a = CGPoint(x: col.x0, y: Y(s.from)), b = CGPoint(x: col.dot, y: Y(s.to))
            var p = Path()
            p.move(to: a)
            if s.from == s.to { p.addLine(to: b) }
            else { p.addCurve(to: b, control1: CGPoint(x: col.x0 + j, y: a.y), control2: CGPoint(x: col.x0 + j, y: b.y)) }
            return (p, a, b)
        }
        let labelW = max(colW - 14, 60)
        /// The room for a step's words on a rail: up to the next column, or only up to that column's crossing when
        /// the crossing passes through where the words are.
        func room(_ c: Int, y: CGFloat, side: Side) -> CGFloat {
            guard c + 1 < columns.count, let next = shown.first(where: { $0.id == columns[c + 1].step }), next.from != next.to else { return labelW }
            let lo = min(Y(next.from), Y(next.to)), hi = max(Y(next.from), Y(next.to))
            let band: ClosedRange<CGFloat> = side == .above ? (y - 60)...(y - 6) : side == .below ? (y + 6)...(y + 60) : (y - 24)...(y + 24)
            return band.overlaps(lo...hi) ? max(colW - 2 * j - 16, 56) : labelW
        }

        // The line. It runs along the rail of whoever has the request, and crosses when a step hands it on.
        let live = shown.filter { mode == .before || $0.inAfter }
        var pos: String?
        var open: Int?            // the piece of the main line still being run along its rail
        var end = CGPoint.zero
        func run(to p: CGPoint) {
            guard let open, p.x > end.x else { return }
            segs[open].path.addLine(to: p)
            end = p
        }
        var lastColumn = -1
        var ended = false         // before, the journey can stop where it broke
        for (n, s) in live.enumerated() {
            guard let c = columnOf[s.id] else { continue }
            let col = columns[c]
            let at = Double(c)
            // Where an undescribed hop to this step's rail would go: the start of the first column the line is free in.
            let hopColumn = lastColumn >= 0 && lastColumn + 1 <= c ? lastColumn + 1 : c
            lastColumn = c
            let (color, glow) = ink(s)
            if pos == nil {
                pos = s.from
                let start = CGPoint(x: headerW + 4, y: Y(s.from))
                dots.append(Dot(p: start, step: nil, kind: .start, color: .trace, at: at - 0.7))
                var p = Path()
                p.move(to: start)
                segs.append(Seg(path: p, step: nil, color: .trace, glow: .signal, style: .live, at: at - 0.7, span: 0.7))
                open = segs.count - 1
                end = start
            }
            if pos != s.from {
                // The request turns up somewhere the last step didn't leave it: a hop nobody described.
                let hx = columns[hopColumn].x0 - min(colW * 0.2, 30)
                run(to: CGPoint(x: hx - j * 0.7, y: end.y))
                let from = end, to = CGPoint(x: hx + j * 0.7, y: Y(s.from))
                var hop = Path()
                hop.move(to: from)
                hop.addCurve(to: to, control1: CGPoint(x: hx, y: from.y), control2: CGPoint(x: hx, y: to.y))
                let hopAt = Double(hopColumn) - 0.3
                segs.append(Seg(path: hop, step: nil, color: .trace, glow: .signal, style: .handoff, at: hopAt, span: 0.3))
                var p = Path()
                p.move(to: to)
                segs.append(Seg(path: p, step: nil, color: .trace, glow: .signal, style: .live, at: hopAt + 0.3, span: max(at - hopAt - 0.3, 0.05)))
                open = segs.count - 1
                end = to
                pos = s.from
            }
            let (path, a, b) = crossing(s, col)
            run(to: a)
            curves[s.id] = path
            let next = n + 1 < live.count ? live[n + 1] : nil
            // A call the caller carries on from: the line stays where it is and the call is a spur off it.
            let spur = s.from != s.to && next?.from == s.from
            let broken = s.id == hurt
            if spur {
                segs.append(Seg(path: path, step: s.id, color: color, glow: glow, style: .live, at: at, span: 0.7))
                dots.append(Dot(p: b, step: s.id, kind: broken ? .broken : .stop, color: color, at: at + 0.6))
                var p = Path()
                p.move(to: a)
                segs.append(Seg(path: p, step: nil, color: .trace, glow: .signal, style: .live, at: at, span: 1))
                open = segs.count - 1
                end = a
                labels.append(Label(id: s.id, step: s, p: CGPoint(x: b.x + 10, y: b.y), side: .beside,
                                    width: room(c, y: b.y, side: .beside) - 4, ghost: false, at: at + 0.55, color: color))
            } else {
                segs.append(Seg(path: path, step: s.id, color: color, glow: glow, style: .live, at: at, span: 1))
                open = segs.count - 1
                end = b
                pos = s.to
                dots.append(Dot(p: b, step: s.id, kind: broken ? .broken : s.from == s.to ? .knot : .stop, color: color, at: at + 0.55))
                // Words go above the rail, unless the line leaves upwards from here next (by a crossing or a hop).
                var side = Side.above
                if let next, Y(next.from == s.to ? next.to : next.from) < b.y - 1 { side = .below }
                labels.append(Label(id: s.id, step: s, p: CGPoint(x: b.x + 2, y: b.y), side: side, width: room(c, y: b.y, side: side),
                                    ghost: false, at: at + 0.55, color: color))
            }
            if broken && !trace.pain.isEmpty, let side = labels.last?.side {
                pain = (CGPoint(x: b.x, y: b.y + (side == .below ? -25 : side == .beside ? 40 : 25)), trace.pain, at + 0.8)
            }
            ended = broken && mode == .before
        }
        // Where it lands (unless it never got there).
        if open != nil, !ended {
            let tail = CGPoint(x: min(end.x + min(max(colW * 0.5, 30), 70), width - 20), y: end.y)
            let last = live.last
            let (color, _) = last.map(ink) ?? (.trace, .signal)
            segs[open!].span = max(segs[open!].span, 1)
            run(to: tail)
            dots.append(Dot(p: tail, step: nil, kind: .end, color: mode == .before && hurt != nil ? .trace : color == .trace ? .signal : color,
                            at: Double(lastColumn) + 1.3))
        }

        // The roads it no longer takes, left as ghosts (only the diff shows both tellings at once).
        for s in shown where mode == .diff && !s.inAfter {
            guard let c = columnOf[s.id] else { continue }
            let col = columns[c]
            let (path, _, b) = crossing(s, col)
            curves[s.id] = path
            segs.append(Seg(path: path, step: s.id, color: .removed, glow: .removed, style: .ghost, at: Double(c), span: 0.8))
            dots.append(Dot(p: b, step: s.id, kind: s.id == hurt ? .broken : .ghost, color: .removed, at: Double(c) + 0.6))
            labels.append(Label(id: s.id, step: s, p: CGPoint(x: b.x + 4, y: b.y), side: .above, width: room(c, y: b.y, side: .above),
                                ghost: true, at: Double(c) + 0.55, color: .removed))
            if s.id == hurt && !trace.pain.isEmpty { pain = (CGPoint(x: b.x, y: b.y + 25), trace.pain, Double(c) + 0.8) }
        }

        // The tag for what went wrong hangs by its step, wherever beside it there's room: a little to the right as
        // a rule, or reaching back to the left when the next step's words are in the way.
        if let pain {
            let w = Self.painWidth((mode == .diff ? "before: " : "") + pain.text)
            let lo = headerW + 6 + w / 2, hi = width - 10 - w / 2
            let taken = labels.map { box($0).insetBy(dx: -4, dy: -2) }
            let tries = [pain.p.x + 30, pain.p.x + 14 - w / 2, pain.p.x - 14 + w / 2].map { min(max($0, lo), max(lo, hi)) }
            let x = tries.first { x in
                let r = CGRect(x: x - w / 2, y: pain.p.y - 10, width: w, height: 20)
                return !taken.contains { $0.intersects(r) }
            } ?? tries[0]
            painAt = CGPoint(x: x, y: pain.p.y)
        }
    }

    /// Where the tag for what went wrong is centred.
    var painAt: CGPoint?

    /// About how wide that tag is drawn (11 pt medium, with its cross and padding).
    static func painWidth(_ text: String) -> CGFloat { CGFloat(text.count) * 5.9 + 32 }

    /// The room a step's words may take up: as wide as they're allowed, as tall as two lines and what travels.
    func box(_ l: Label) -> CGRect {
        let h: CGFloat = l.step.data.isEmpty || l.ghost ? 30 : 48
        let y = l.side == .above ? l.p.y - 8 - h : l.side == .below ? l.p.y + 8 : l.p.y - h / 2
        return CGRect(x: l.p.x, y: y, width: l.width, height: h)
    }
}

struct StageView: View {
    let trace: Trace
    let mode: FlowMode
    /// The step lit up: pinned or under the pointer.
    let focus: Int?
    let cursor: Int?
    @Binding var hover: Int?
    let pick: (Int) -> Void

    /// How much of the trace is drawn, in steps; it draws itself in when it arrives.
    @State private var reveal: Double = QA.still ? (QA.env["FATHOM_REVEAL"].flatMap(Double.init) ?? 1000) : 0
    @State private var revealFrom: Double = 0
    @State private var actorFocus: String?
    @Environment(\.colorScheme) private var scheme

    private let perStep = 0.12

    var body: some View {
        GeometryReader { geo in
            let plan = StagePlan(trace: trace, mode: mode, width: geo.size.width)
            let lit: (Int?) -> Bool = { step in
                if let focus { return step == focus }
                if let actorFocus {
                    guard let step, let s = trace.flow.first(where: { $0.id == step }) else { return false }
                    return s.from == actorFocus || s.to == actorFocus
                }
                return true
            }
            ZStack(alignment: .topLeading) {
                StageCanvas(plan: plan, reveal: reveal, focus: focus, pinned: cursor, actorFocus: actorFocus, glow: scheme == .dark, lit: lit)

                ForEach(Array(plan.lanes.enumerated()), id: \.offset) { _, lane in
                    Text(lane.name.uppercased())
                        .font(.mono(9, .semibold))
                        .tracking(1.4)
                        .foregroundStyle(lane.hue.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: lane.rect.minX + 12, y: lane.rect.minY + 6)
                }

                ForEach(plan.rows) { row in
                    // Hover goes on the chip itself: after .position it would cover the whole stage.
                    ActorChip(actor: row.actor, hue: row.hue, lit: actorFocus == row.id || touches(row.id))
                        .frame(width: plan.headerW - 28, alignment: .leading)
                        .contentShape(Rectangle())
                        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { actorFocus = QA.hover(h) ? row.id : (actorFocus == row.id ? nil : actorFocus) } }
                        .opacity(dimmed(row.id, plan) ? 0.4 : 1)
                        .position(x: 16 + (plan.headerW - 28) / 2, y: row.y + (plan.lanes.contains { abs($0.rect.minY - (row.y - StagePlan.gap(plan.rows.count) / 2 + 3)) < 1 } ? 5 : 0))
                }

                ForEach(plan.labels) { l in
                    StepLabel(label: l, mode: mode, focused: focus == l.id,
                              delay: QA.still ? nil : max(l.at - revealFrom, 0) * perStep)
                        .frame(width: l.width, height: 58, alignment: l.side == .above ? .bottomLeading : l.side == .below ? .topLeading : .leading)
                        .opacity(lit(l.id) ? 1 : 0.3)
                        .position(x: l.p.x + l.width / 2, y: l.side == .above ? l.p.y - 40 : l.side == .below ? l.p.y + 40 : l.p.y)
                        .allowsHitTesting(false)
                }

                if let pain = plan.pain {
                    PainNote(text: mode == .diff ? "before: " + pain.text : pain.text)
                        .fixedSize()
                        .opacity(reveal >= pain.at ? (focus == nil || lit(trace.breaks) ? 1 : 0.3) : 0)
                        .position(plan.painAt ?? pain.p)
                        .allowsHitTesting(false)
                }

                if mode == .diff, trace.flow.contains(where: { $0.status != .same }) {
                    Legend()
                        .frame(width: 200, alignment: .leading)
                        .position(x: 18 + 100, y: 18)
                        .allowsHitTesting(false)
                }

                ForEach(plan.columns, id: \.step) { col in
                    Ruler(column: col, mode: mode, on: focus == col.step, pinned: cursor == col.step)
                        .position(x: col.dot, y: plan.height - 22)
                        .allowsHitTesting(false)
                }

                // The playhead: a spark that runs the step's crossing.
                if let c = cursor, let path = plan.curves[c], let seg = plan.segs.first(where: { $0.step == c }) {
                    Spark(path: path, color: seg.glow)
                        .id("spark-\(c)-\(mode.rawValue)")
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: plan.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard !QA.noHover else { return }
                switch phase {
                case .active(let p):
                    let next = p.y < plan.height - 4 ? plan.column(at: p.x)?.step : nil
                    if next != hover { withAnimation(.easeOut(duration: 0.14)) { hover = next } }
                case .ended:
                    if hover != nil { withAnimation(.easeOut(duration: 0.2)) { hover = nil } }
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                if let col = plan.column(at: tap.location.x) { pick(col.step) }
            })
            .animation(.smooth(duration: 0.4), value: mode)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                StageProbe.frame = frame
                StageProbe.columns = plan.columns.map { CGPoint(x: $0.x0 + plan.colW / 2, y: plan.height / 2) }
            }
            .onChange(of: plan.columns.count, initial: true) { _, _ in draw(to: plan.whole, from: reveal) }
            .onChange(of: mode) { _, _ in draw(to: plan.whole, from: 0) }
        }
        .frame(height: StagePlan.height(trace))
    }

    /// The trace draws itself, a step at a time, from where it had got to.
    private func draw(to whole: Double, from start: Double) {
        guard !QA.still else { return }
        var now = Transaction()
        now.disablesAnimations = true
        withTransaction(now) {
            reveal = min(start, whole)
            revealFrom = reveal
        }
        withAnimation(.linear(duration: max((whole - reveal) * perStep, 0.2))) { reveal = whole }
    }

    private func touches(_ actor: String) -> Bool {
        guard let focus, let s = trace.flow.first(where: { $0.id == focus }) else { return false }
        return s.from == actor || s.to == actor
    }

    private func dimmed(_ actor: String, _ plan: StagePlan) -> Bool {
        if focus != nil { return !touches(actor) }
        if let actorFocus {
            return actorFocus != actor && !trace.flow.contains { ($0.from == actorFocus && $0.to == actor) || ($0.to == actorFocus && $0.from == actor) }
        }
        // A part the telling on screen never reaches (one only the other version uses) steps back.
        let shown = Set(plan.columns.map(\.step))
        return !trace.flow.contains { shown.contains($0.id) && ($0.from == actor || $0.to == actor) }
    }
}

/// Where the stage is in its window and where its columns are, for the self-test that clicks on one.
@MainActor
enum StageProbe {
    static var frame = CGRect.zero
    static var columns: [CGPoint] = []
    static var picked: Int?
    static var play = CGRect.zero
}

/// Everything on the stage that's drawn rather than written: the bands, the rails, the line and its dots.
struct StageCanvas: View, Animatable {
    let plan: StagePlan
    var reveal: Double
    let focus: Int?
    let pinned: Int?
    let actorFocus: String?
    let glow: Bool
    let lit: (Int?) -> Bool

    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    private func drawn(_ seg: StagePlan.Seg) -> CGFloat {
        CGFloat(min(max((reveal - seg.at) / max(seg.span, 0.01), 0), 1))
    }

    var body: some View {
        Canvas { ctx, size in
            // The processes: bands the rails run along.
            for lane in plan.lanes {
                let band = Path(roundedRect: lane.rect, cornerRadius: 13, style: .continuous)
                ctx.fill(band, with: .linearGradient(Gradient(colors: [lane.hue.opacity(0.1), lane.hue.opacity(0.025)]),
                                                     startPoint: CGPoint(x: lane.rect.minX, y: 0), endPoint: CGPoint(x: lane.rect.maxX * 0.7, y: 0)))
                ctx.stroke(band, with: .color(lane.hue.opacity(0.16)), lineWidth: 0.75)
            }
            // The rails.
            for row in plan.rows {
                var p = Path()
                p.move(to: CGPoint(x: plan.headerW, y: row.y))
                p.addLine(to: CGPoint(x: size.width - 20, y: row.y))
                let on = actorFocus == row.id
                ctx.stroke(p, with: .color(row.hue.opacity(on ? 0.6 : 0.24)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 6]))
                let socket = CGRect(x: plan.headerW - 3, y: row.y - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: socket), with: .color(Color.canvas))
                ctx.stroke(Path(ellipseIn: socket), with: .color(row.hue.opacity(on ? 0.9 : 0.5)), lineWidth: 1)
            }
            // The step in focus: a soft beam down its column.
            if let focus, let col = plan.columns.first(where: { $0.step == focus }) {
                let beam = CGRect(x: col.x0 - 10, y: 0, width: plan.colW + 8, height: size.height - 34)
                let strength = pinned == focus ? 0.07 : 0.04
                ctx.drawLayer { layer in
                    layer.clipToLayer { mask in
                        mask.fill(Path(beam), with: .linearGradient(Gradient(colors: [.clear, .white, .white, .clear]),
                                                                    startPoint: CGPoint(x: 0, y: beam.minY), endPoint: CGPoint(x: 0, y: beam.maxY)))
                    }
                    layer.fill(Path(beam), with: .linearGradient(Gradient(colors: [.clear, Color.wash(strength), Color.wash(strength), .clear]),
                                                                 startPoint: CGPoint(x: beam.minX, y: 0), endPoint: CGPoint(x: beam.maxX, y: 0)))
                }
            }

            let line = StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
            // Ghosts and hops first, under the line.
            for seg in plan.segs where seg.style != .live {
                let f = drawn(seg)
                guard f > 0 else { continue }
                var c = ctx
                c.opacity = lit(seg.step) || (seg.step == nil && focus == nil && actorFocus == nil) ? 1 : 0.3
                let path = seg.path.trimmedPath(from: 0, to: f)
                if seg.style == .ghost {
                    c.stroke(path, with: .color(seg.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [5, 5]))
                } else {
                    c.stroke(path, with: .color(Color.trace.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1, 4.5]))
                }
            }
            // The light around the line.
            if glow {
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 9))
                    for seg in plan.segs where seg.style == .live {
                        let f = drawn(seg)
                        guard f > 0 else { continue }
                        let on = lit(seg.step) || (seg.step == nil && focus == nil && actorFocus == nil)
                        let strong = focus != nil && seg.step == focus
                        layer.stroke(seg.path.trimmedPath(from: 0, to: f), with: .color(seg.glow.opacity(on ? (strong ? 1 : 0.8) : 0.14)),
                                     style: StrokeStyle(lineWidth: strong ? 9 : 6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            // The line.
            for seg in plan.segs where seg.style == .live {
                let f = drawn(seg)
                guard f > 0 else { continue }
                let on = lit(seg.step) || (seg.step == nil && focus == nil && actorFocus == nil)
                ctx.stroke(seg.path.trimmedPath(from: 0, to: f), with: .color(seg.color.opacity(on ? 1 : 0.28)), style: line)
            }
            // Where it stops along the way.
            for dot in plan.dots where reveal >= dot.at {
                var c = ctx
                c.opacity = lit(dot.step) || (dot.step == nil && focus == nil && actorFocus == nil) ? 1 : 0.3
                Self.draw(dot, in: &c, glow: glow)
            }
        }
    }

    static func draw(_ dot: StagePlan.Dot, in ctx: inout GraphicsContext, glow: Bool) {
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: dot.p.x - r, y: dot.p.y - r, width: r * 2, height: r * 2)) }
        switch dot.kind {
        case .start:
            ctx.fill(circle(6.5), with: .color(Color.canvas))
            ctx.stroke(circle(6.5), with: .color(dot.color), lineWidth: 2.4)
        case .stop:
            ctx.fill(circle(4.6), with: .color(Color.canvas))
            ctx.stroke(circle(4.6), with: .color(dot.color), lineWidth: 2.2)
        case .knot:
            ctx.fill(circle(5.5), with: .color(Color.canvas))
            ctx.stroke(circle(5.5), with: .color(dot.color), lineWidth: 2.2)
            ctx.fill(circle(1.8), with: .color(dot.color))
        case .end:
            if glow {
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 10))
                    layer.fill(circle(13), with: .color(dot.color.opacity(0.75)))
                }
            }
            ctx.fill(circle(7), with: .color(dot.color))
            ctx.fill(circle(2.8), with: .color(Color.white.opacity(0.9)))
        case .ghost:
            ctx.fill(circle(3.8), with: .color(Color.canvas))
            ctx.stroke(circle(3.8), with: .color(dot.color.opacity(0.8)), lineWidth: 1.4)
        case .broken:
            if glow {
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 8))
                    layer.fill(circle(12), with: .color(Color.removed.opacity(0.55)))
                }
            }
            ctx.fill(circle(8.5), with: .color(Color.canvas))
            ctx.stroke(circle(8.5), with: .color(Color.removed), lineWidth: 1.6)
            var x = Path()
            x.move(to: CGPoint(x: dot.p.x - 3.3, y: dot.p.y - 3.3)); x.addLine(to: CGPoint(x: dot.p.x + 3.3, y: dot.p.y + 3.3))
            x.move(to: CGPoint(x: dot.p.x + 3.3, y: dot.p.y - 3.3)); x.addLine(to: CGPoint(x: dot.p.x - 3.3, y: dot.p.y + 3.3))
            ctx.stroke(x, with: .color(Color.removed), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
        }
    }
}

/// A part of the system at the head of its rail: its mark, its name as written in the code, and what it's for.
struct ActorChip: View {
    let actor: Trace.Actor
    let hue: Color
    var lit = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: Glyph.part(actor.isPerson ? "person" : actor.kind))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(hue)
                .frame(width: 27, height: 27)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hue.opacity(lit ? 0.24 : 0.13)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hue.opacity(lit ? 0.8 : 0.34), lineWidth: 0.8))
                .neon(hue, radius: 7, strength: lit ? 0.5 : 0)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    if !actor.isPerson && !actor.change.sign.isEmpty {
                        Text(actor.change.sign).font(.mono(10.5, .bold)).foregroundStyle(actor.change.color)
                    }
                    Text(actor.name)
                        .font(actor.isPerson ? .sans(12.5, .semibold) : .mono(11.5, .medium))
                        .foregroundStyle(Color.text1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                        .truncationMode(.middle)
                }
                if !actor.role.isEmpty {
                    Text(actor.role)
                        .font(.sans(10.5))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .help(help)
    }

    private var help: String {
        if actor.isPerson { return "Point here to follow \(actor.name) alone" }
        switch actor.change {
        case .added: return "\(actor.name) — new in this pull request"
        case .modified: return "\(actor.name) — its code changes"
        default: return "\(actor.name) — unchanged; the change talks to it"
        }
    }
}

/// A step's few words, and what travels, beside where the line arrives.
struct StepLabel: View {
    let label: StagePlan.Label
    let mode: FlowMode
    let focused: Bool
    /// How long after it's placed it fades in, as the line reaches it; nil shows it at once.
    let delay: Double?
    @State private var shown = false

    var body: some View {
        let s = label.step
        VStack(alignment: .leading, spacing: 4) {
            Text(mode == .before ? s.beforeDoes : s.does)
                .font(.sans(12, .medium))
                .foregroundStyle(label.ghost ? Color.text3 : Color.text1)
                .strikethrough(label.ghost, color: Color.removed.opacity(0.7))
                .lineLimit(2)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            if !s.data.isEmpty && !label.ghost {
                Packet(text: s.data, tint: label.color)
            }
        }
        .opacity(delay == nil || shown ? 1 : 0)
        .offset(y: delay == nil || shown ? 0 : 4)
        .onAppear {
            guard let delay else { return }
            withAnimation(.easeOut(duration: 0.3).delay(delay)) { shown = true }
        }
    }
}

/// What travels along with a step.
struct Packet: View {
    let text: String
    var tint: Color = .calm

    var body: some View {
        Text(text)
            .font(.mono(9.5, .medium))
            .foregroundStyle(tint.opacity(0.95))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.1)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 0.6))
    }
}

/// What went wrong, as a tag under the step where it did.
struct PainNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "xmark").font(.system(size: 7.5, weight: .heavy))
            Text(text)
                .font(.sans(11, .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.removed)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Color.canvas))
        .background(Capsule().fill(Color.removed.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.removed.opacity(0.4), lineWidth: 0.7))
    }
}

/// What the line's colours mean, small, in a corner of the diff.
struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            item(.added, "new")
            item(.changed, "changed")
            HStack(spacing: 5) {
                Canvas { ctx, size in
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    ctx.stroke(p, with: .color(Color.removed.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                }
                .frame(width: 14, height: 6)
                Text("gone")
            }
        }
        .font(.mono(9.5))
        .foregroundStyle(Color.text3)
        .fixedSize()
    }

    private func item(_ tint: Color, _ word: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(tint).frame(width: 12, height: 2.5)
            Text(word)
        }
    }
}

/// A step's number under its column, with the mark a diff would give it.
struct Ruler: View {
    let column: StagePlan.Column
    let mode: FlowMode
    let on: Bool
    let pinned: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(String(format: "%02d", column.number))
                .font(.mono(9.5, on ? .bold : .regular))
                .foregroundStyle(pinned ? Color.signal : on ? Color.text1 : Color.text3)
            if mode == .diff, column.status != .same {
                Text(column.status == .added ? "+" : column.status == .removed ? "−" : "~")
                    .font(.mono(10, .bold))
                    .foregroundStyle(column.status == .added ? Color.added : column.status == .removed ? Color.removed : Color.changed)
            }
        }
        .fixedSize()
    }
}

/// The playhead's spark: it runs the step's crossing and stays lit where it lands.
struct Spark: View {
    let path: Path
    let color: Color
    @State private var t: CGFloat = QA.still ? 1 : 0

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color).frame(width: 26, height: 26).blur(radius: 8))
            .modifier(Along(path: path, t: t))
            .onAppear { withAnimation(.easeInOut(duration: 0.7)) { t = 1 } }
    }
}

private struct Along: ViewModifier, Animatable {
    let path: Path
    var t: CGFloat

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    func body(content: Content) -> some View {
        content.position(path.trimmedPath(from: 0, to: min(max(t, 0.001), 1)).currentPoint ?? .zero)
    }
}

// MARK: - Caption

/// Under the stage, the one place the words are: the step in focus read out in a line, or, with nothing in focus,
/// the telling on screen in a sentence. Play on the left, the three tellings on the right.
struct CaptionBar: View {
    let trace: Trace
    let mode: FlowMode
    let focus: Trace.Step?
    let pinned: Bool
    let playing: Bool
    let togglePlay: () -> Void
    let setMode: (FlowMode) -> Void
    let open: (Trace.Step) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            PlayButton(playing: playing, action: togglePlay)
            Group {
                if let s = focus { step(s) } else { overview }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ModeSwitch(mode: mode, pick: setMode)
        }
        .frame(height: 44)
    }

    private func name(_ id: String) -> String { trace.actor(id)?.name ?? id }

    private func step(_ s: Trace.Step) -> some View {
        let tint: Color = s.status == .added ? .added : s.status == .changed ? .changed : s.status == .removed ? .removed : .text2
        let broken = s.id == trace.breaks && mode != .after
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(format: "%02d", s.id + 1))
                .font(.mono(12, .semibold))
                .foregroundStyle(mode == .before ? Color.text2 : tint)
            HStack(spacing: 7) {
                Text(name(s.from))
                if s.from != s.to {
                    Image(systemName: "arrow.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.text3)
                    Text(name(s.to))
                }
            }
            .font(.mono(11.5))
            .foregroundStyle(Color.text2)
            .lineLimit(1)
            .layoutPriority(-1)
            Text(mode == .before ? s.beforeDoes : s.does)
                .font(.sans(16.5, .medium))
                .foregroundStyle(Color.text1)
                .lineLimit(1)
            if mode == .diff, s.status == .changed, !s.was.isEmpty, s.was != s.does {
                Text(s.was)
                    .font(.sans(13.5))
                    .strikethrough(true, color: Color.text3)
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
                    .layoutPriority(-2)
            }
            if !s.data.isEmpty { Packet(text: s.data, tint: tint == .text2 ? .calm : tint).fixedSize() }
            if broken && !trace.pain.isEmpty { PainNote(text: trace.pain).fixedSize() }
            Spacer(minLength: 4)
            if !s.hunk.isEmpty {
                InkButton(title: "code", tint: .text2) { open(s) }
                    .help("Read this step's change" + (pinned ? " (↩)" : ""))
            }
        }
        .id(s.id)
        .transition(.opacity)
    }

    private var overview: some View {
        let (label, text, tint): (String, String, Color) = switch mode {
        case .before: ("before", trace.was, .removed)
        case .after: ("after", trace.now, .added)
        case .diff: ("the idea", trace.how, .signal)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.mono(11, .semibold))
                .foregroundStyle(tint)
                .fixedSize()
            Text(text.isEmpty ? " " : Prose.sentence(text))
                .font(.sans(16.5))
                .foregroundStyle(Color.text1.opacity(0.92))
                .lineLimit(1)
                .textSelection(.enabled)
                .animation(nil, value: text)
        }
        .id(mode.rawValue)
        .transition(.opacity)
    }
}

struct PlayButton: View {
    let playing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(playing || hover ? Color.ink : Color.signal)
                .offset(x: playing ? 0 : 1)
                .frame(width: 36, height: 36)
                .background(Circle().fill(playing || hover ? Color.signal : Color.signal.opacity(0.12)))
                .overlay(Circle().strokeBorder(Color.signal.opacity(0.6), lineWidth: 0.9))
                .neon(.signal, radius: 9, strength: playing || hover ? 0.55 : 0.2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { StageProbe.play = $0 }
        .help(playing ? "Pause (space)" : "Play the journey, a step at a time (space); ← → step by hand")
    }
}

/// before · diff · after, with a thumb that slides to the one on screen.
struct ModeSwitch: View {
    let mode: FlowMode
    let pick: (FlowMode) -> Void
    @Namespace private var space

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FlowMode.allCases) { m in
                let on = m == mode
                Button { pick(m) } label: {
                    Text(m.rawValue)
                        .font(.mono(11.5, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.text1 : Color.text3)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if on {
                                Capsule().fill(Color.wash(0.1))
                                    .overlay(Capsule().strokeBorder(Color.wash(0.16), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "mode", in: space)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(m.rawValue.capitalized) (\(String(m.rawValue.prefix(1)).uppercased()))")
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.wash(0.035)))
        .overlay(Capsule().strokeBorder(Color.wash(0.08), lineWidth: 0.5))
        .animation(Motion.snappy, value: mode)
    }
}

// MARK: - Forks

/// The places where the change took one road and might have taken another.
struct ForkStrip: View {
    @Bindable var session: PRSession
    let forks: [Trace.Fork]
    @Binding var hover: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionMark(title: "Forks", note: "\(forks.count)")
            HStack(alignment: .top, spacing: 14) {
                ForEach(forks) { f in
                    ForkTile(fork: f, lit: { on in
                        // Pointing at a fork lights the step where it shows.
                        guard f.step >= 0, session.trace.flow.indices.contains(f.step), !QA.noHover else { return }
                        withAnimation(.easeOut(duration: 0.15)) { hover = on ? f.step : (hover == f.step ? nil : hover) }
                    }) { session.go(toHunk: f.hunk) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One fork: the road taken, lit, and the ones passed up, dashed; and why, in a few words.
struct ForkTile: View {
    let fork: Trace.Fork
    let lit: (Bool) -> Void
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Text(fork.title)
                    .font(.sans(12.5, .medium))
                    .foregroundStyle(Color.text2)
                    .lineLimit(1)
                Fork(chose: fork.chose, over: fork.over)
                    .padding(.top, 10)
                if !fork.why.isEmpty {
                    Text(Prose.sentence(fork.why))
                        .font(.sans(11.5))
                        .foregroundStyle(Color.text3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 8)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.stage.opacity(hover ? 1 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hover ? Color.signal.opacity(0.5) : Color.wash(0.09), lineWidth: 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            hover = QA.hover(h)
            lit(h)
        }
        .animation(Motion.snappy, value: hover)
        .help(fork.hunk.isEmpty ? "" : "Read where this choice lives")
        .disabled(fork.hunk.isEmpty)
    }
}

/// The road taken runs on, lit; the roads not taken branch off it, dashed, and stop.
struct Fork: View {
    let chose: String
    let over: [String]
    private let row: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Canvas { ctx, size in
                let x: CGFloat = 7
                var trunk = Path()
                trunk.move(to: CGPoint(x: x, y: 0))
                trunk.addLine(to: CGPoint(x: x, y: row / 2))
                ctx.stroke(trunk, with: .color(Color.signal.opacity(0.5)), lineWidth: 1.4)
                for i in over.indices {
                    let y = row * (CGFloat(i) + 1.5)
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: row / 2 + 4))
                    p.addLine(to: CGPoint(x: x, y: y - 7))
                    p.addQuadCurve(to: CGPoint(x: x + 7, y: y), control: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: size.width - 6, y: y))
                    ctx.stroke(p, with: .color(.wash(0.28)), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                    ctx.stroke(Path(ellipseIn: CGRect(x: size.width - 6, y: y - 2.5, width: 5, height: 5)), with: .color(.wash(0.42)), lineWidth: 1)
                }
                let dot = CGRect(x: x - 4.5, y: row / 2 - 4.5, width: 9, height: 9)
                ctx.fill(Path(ellipseIn: dot.insetBy(dx: -4.5, dy: -4.5)), with: .color(Color.signal.opacity(0.18)))
                ctx.fill(Path(ellipseIn: dot), with: .color(Color.signal))
                var lead = Path()
                lead.move(to: CGPoint(x: x + 4, y: row / 2))
                lead.addLine(to: CGPoint(x: size.width, y: row / 2))
                ctx.stroke(lead, with: .color(Color.signal.opacity(0.8)), lineWidth: 1.4)
            }
            .frame(width: 30, height: row * CGFloat(over.count + 1))

            VStack(alignment: .leading, spacing: 0) {
                Text(chose)
                    .font(.sans(13.5, .semibold))
                    .foregroundStyle(Color.text1)
                    .lineLimit(1)
                    .frame(height: row)
                ForEach(over, id: \.self) { alt in
                    Text(alt)
                        .font(.sans(12.5))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                        .frame(height: row)
                }
            }
        }
    }
}

// MARK: - The code, in chapters

/// The way on to the code, as the shape of the change: one bar per chapter, as long as the chapter is, lit where
/// it's worth reading.
struct ChapterRibbon: View {
    @Bindable var session: PRSession

    var body: some View {
        let chapters = session.brief.chapters.isEmpty ? [] : session.chapterInfos
        VStack(alignment: .leading, spacing: 14) {
            SectionMark(title: "Code", note: note(chapters)) {
                if case .done(let s) = session.traceState, s > 0 {
                    Text("\(session.soundedModel ?? session.model) · traced in \(Fmt.seconds(s))")
                        .font(.mono(10))
                        .foregroundStyle(Color.text3.opacity(0.8))
                        .help("How long Claude took to read this pull request")
                }
            }
            if chapters.isEmpty {
                Button {
                    withAnimation(Motion.spring) { session.tab = .changes }
                } label: {
                    HStack(spacing: 10) {
                        if session.briefState.isRunning { ScanBar().frame(width: 110, height: 2) }
                        Text(session.briefState.isRunning ? "sorting the diff into reading order" : "read the diff")
                            .font(.mono(11))
                            .foregroundStyle(Color.text3)
                    }
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                GeometryReader { geo in
                    let weights = chapters.map { max(sqrt(CGFloat($0.additions + $0.deletions)), 4) }
                    let spacing: CGFloat = 8
                    let room = geo.size.width - spacing * CGFloat(chapters.count - 1)
                    let total = max(weights.reduce(0, +), 1)
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { i, ch in
                            ChapterBar(chapter: ch, done: session.reviewed.contains(ch.id)) { session.go(toChapter: ch.id) }
                                .frame(width: max(room * weights[i] / total, 30))
                        }
                    }
                }
                .frame(height: 46)
            }
        }
    }

    private func note(_ chapters: [ChapterInfo]) -> String {
        guard !chapters.isEmpty else { return "" }
        let read = chapters.filter { $0.attention == .focus }.count
        return "\(chapters.count) chapters · \(read) to read · about \(session.reviewMinutes) min"
    }
}

struct ChapterBar: View {
    let chapter: ChapterInfo
    let done: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let tint: Color = done ? .added : chapter.attention == .focus ? .signal : chapter.attention == .skim ? Color.signal.opacity(0.45) : Color.wash(0.22)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Capsule()
                    .fill(tint)
                    .frame(height: hover ? 7 : 5)
                    .neon(chapter.attention == .focus ? .signal : .clear, radius: 6, strength: hover ? 0.7 : 0.35)
                    .frame(height: 7, alignment: .center)
                Text(chapter.title)
                    .font(.sans(11.5, hover ? .medium : .regular))
                    .foregroundStyle(hover ? Color.text1 : chapter.attention == .skip ? Color.text3 : Color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
        .help("\(chapter.title) — \(chapter.attention.word.lowercased()) · +\(chapter.additions) −\(chapter.deletions)")
    }
}

// MARK: - Failure

struct TraceFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("No trace this time")
                .font(.display(20))
                .foregroundStyle(Color.text1)
            Text(message)
                .font(.sans(12.5))
                .foregroundStyle(Color.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
            Button("Trace again", action: retry)
                .buttonStyle(.glass)
        }
    }
}
