// The referee's pages: what the change trades (each decision as a scored table), what could go wrong and whether a
// revert undoes it (a risk matrix and the hazards), the questions it leaves open (settle them, ask Fathom, or put
// them to the author), and the passages that carry it, with notes in the margin.

import SwiftUI

// MARK: - Trade-offs

struct TradeoffsPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let c = session.critique
        PageFrame(page: .tradeoffs, title: c.price,
                  dek: c.choices.isEmpty ? nil : Text(dek(c.choices.count)),
                  waiting: session.critiqueState.isRunning) {
            VStack(alignment: .leading, spacing: 46) {
                ForEach(c.choices) { choice in
                    TradeoffBlock(session: session, choice: choice)
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }

    private func dek(_ n: Int) -> String {
        (n == 1 ? "One decision" : "\(Prose.word(n)) decisions") + ", each scored on what separates its options. The road taken is shaded."
    }
}

/// One decision: the question it settled, the options scored side by side in a ruled table, and why this one won.
struct TradeoffBlock: View {
    @Bindable var session: PRSession
    let choice: Critique.Choice

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("3.\(choice.id + 1)")
                    .font(.serif(18))
                    .foregroundStyle(Color.text3)
                Text(choice.title)
                    .font(.serif(23))
                    .foregroundStyle(Color.text1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(choice.stated ? "stated" : "inferred")
                    .font(.smallCaps(12.5))
                    .tracking(1)
                    .foregroundStyle(choice.stated ? Color.calm : Color.text3)
                    .fixedSize()
                    .help(choice.stated ? "The PR description or a code comment says why" : "Fathom's reading of why; the PR doesn't say")
            }
            HStack(alignment: .top, spacing: 40) {
                HarveyTable(choice: choice)
                    .frame(minWidth: 420, maxWidth: 640, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) {
                    if !choice.why.isEmpty {
                        (Text("Why. ").font(.runIn(16.5)) + Text(Prose.sentence(choice.why)))
                            .font(.serif(16.5))
                            .lineSpacing(3)
                            .foregroundStyle(Color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let h = choice.hunks.first {
                        InkButton(title: "See it in the code") { session.go(toHunk: h) }
                    }
                }
                .frame(maxWidth: 340, alignment: .leading)
                .padding(.top, 6)
            }
        }
    }
}

/// The options as columns, what separates them as rows, each score a Harvey ball, ruled like a table in a paper:
/// a heavy rule above, a light one under the heads, a heavy one below. The chosen column is shaded.
struct HarveyTable: View {
    let choice: Critique.Choice
    @State private var filled = false

    var body: some View {
        let n = choice.options.count
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { Rectangle().fill(Color.text1.opacity(0.55)).frame(height: 1).gridCellColumns(n + 1) }
            GridRow(alignment: .bottom) {
                Color.clear.frame(height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(Array(choice.options.enumerated()), id: \.offset) { i, option in
                    VStack(spacing: 4) {
                        if i == 0 {
                            Text("chosen")
                                .font(.smallCaps(11))
                                .tracking(1)
                                .foregroundStyle(Color.text3)
                        }
                        Text(option)
                            .font(.serif(15.5))
                            .foregroundStyle(i == 0 ? Color.text1 : Color.text2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .background(i == 0 ? Color.wash(0.045) : Color.clear)
                }
            }
            GridRow { Rule(opacity: 0.2).gridCellColumns(n + 1) }
            ForEach(Array(choice.criteria.enumerated()), id: \.offset) { r, criterion in
                GridRow {
                    Text(criterion.name)
                        .font(.serifItalic(15.5))
                        .foregroundStyle(Color.text2)
                        .lineLimit(1)
                        .frame(minWidth: 130, maxWidth: 200, alignment: .leading)
                        .padding(.vertical, 11)
                    ForEach(0..<n, id: \.self) { i in
                        let score = i < criterion.scores.count ? criterion.scores[i] : 0
                        HarveyBall(score: score, filled: filled, delay: Double(r * n + i) * 0.04)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(i == 0 ? Color.wash(0.045) : Color.clear)
                            .help("\(choice.options[i]): \(score) of 4 on \(criterion.name.lowercased())")
                    }
                }
            }
            GridRow { Rectangle().fill(Color.text1.opacity(0.55)).frame(height: 1).gridCellColumns(n + 1) }
        }
        .onAppear { filled = true }
    }
}

/// A score out of four as a circle filled by quarters, the way a consumer report scores.
struct HarveyBall: View {
    let score: Int
    var filled = true
    var delay = 0.0

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.text1.opacity(0.7), lineWidth: 0.9)
            Pie(fraction: filled ? Double(score) / 4 : 0)
                .fill(Color.text1.opacity(0.82))
                .padding(1.6)
        }
        .frame(width: 17, height: 17)
        .animation(.smooth(duration: 0.6).delay(0.15 + delay), value: filled)
    }
}

/// A slice from twelve o'clock, clockwise.
struct Pie: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard fraction > 0.001 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        if fraction >= 0.999 { return Path(ellipseIn: rect) }
        p.move(to: c)
        p.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Risk

struct RiskPage: View {
    @Bindable var session: PRSession
    @State private var focus: Int?

    var body: some View {
        let c = session.critique
        let contracts = session.brief.contracts
        PageFrame(page: .risk, title: c.door.isEmpty ? "" : c.oneWay ? "A one-way door" : "A two-way door",
                  dek: c.doorWhy.isEmpty ? nil : Text(Prose.sentence(c.doorWhy)),
                  waiting: session.critiqueState.isRunning) {
            VStack(alignment: .leading, spacing: 50) {
                if !c.risks.isEmpty {
                    HStack(alignment: .top, spacing: 44) {
                        Figure(number: 3, caption: "Each hazard by how likely it is and how much it would hurt. A filled mark has nothing in this change guarding it.") {
                            RiskMatrix(risks: c.risks, focus: $focus)
                        }
                        .frame(width: 380)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(c.risks) { r in
                                HazardRow(session: session, risk: r, focus: $focus)
                            }
                        }
                        .frame(maxWidth: 620, alignment: .leading)
                    }
                } else if session.critiqueState.isDone {
                    Text("Fathom found no way this fails in production worth naming.")
                        .font(.serifItalic(18))
                        .foregroundStyle(Color.text2)
                } else if session.critiqueState.isRunning {
                    Skeleton(lines: [0.8, 0.6, 0.7], height: 14, spacing: 16).frame(maxWidth: 800)
                }
                if !contracts.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionHead(title: "Contracts that change", note: "Other code relies on their shape; a new shape is a new promise.")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(contracts) { contract in
                                InterfaceCard(session: session, contract: contract, fill: true)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }

    static func tint(_ r: Critique.Risk) -> Color {
        r.score >= 6 ? .removed : r.score >= 3 ? .changed : .text2
    }
}

/// Likelihood across, impact up, three by three, each cell a shade deeper towards the top right. Each hazard is a
/// numbered mark in its cell: filled when nothing in the change guards it.
struct RiskMatrix: View {
    let risks: [Critique.Risk]
    @Binding var focus: Int?
    @State private var shown = false

    private let cell: CGFloat = 92
    private let axisW: CGFloat = 54
    private let axisH: CGFloat = 40

    var body: some View {
        let side = cell * 3
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for l in 1...3 {
                    for i in 1...3 {
                        let r = rect(l, i)
                        let level = Double(l * i)
                        ctx.fill(Path(r), with: .color(Color.removed.opacity(0.012 + level * 0.014)))
                        ctx.stroke(Path(r), with: .color(.wash(0.1)), lineWidth: 0.5)
                    }
                }
                var frame = Path()
                frame.move(to: CGPoint(x: axisW, y: 0))
                frame.addLine(to: CGPoint(x: axisW, y: side))
                frame.addLine(to: CGPoint(x: axisW + side, y: side))
                ctx.stroke(frame, with: .color(.wash(0.45)), lineWidth: 0.9)
            }
            .frame(width: axisW + side, height: side + axisH)

            ForEach(1...3, id: \.self) { l in
                Text(["Rare", "Possible", "Likely"][l - 1])
                    .font(.serifItalic(13.5))
                    .foregroundStyle(Color.text3)
                    .position(x: axisW + (CGFloat(l) - 0.5) * cell, y: side + 14)
            }
            ForEach(1...3, id: \.self) { i in
                Text(["Minor", "Serious", "Severe"][i - 1])
                    .font(.serifItalic(13.5))
                    .foregroundStyle(Color.text3)
                    .position(x: axisW / 2 - 2, y: side - (CGFloat(i) - 0.5) * cell)
            }
            Text("Likelihood")
                .font(.smallCaps(11.5))
                .tracking(1.2)
                .foregroundStyle(Color.text3)
                .position(x: axisW + side / 2, y: side + 34)
            Text("Impact")
                .font(.smallCaps(11.5))
                .tracking(1.2)
                .foregroundStyle(Color.text3)
                .position(x: axisW / 2 - 2, y: -12)

            ForEach(risks) { r in
                let spot = spot(r)
                RiskMarker(risk: r, size: 26, focused: focus == r.id)
                    .onHover { h in withAnimation(.easeOut(duration: 0.18)) { focus = QA.hover(h) ? r.id : (focus == r.id ? nil : focus) } }
                    .scaleEffect(shown ? (focus == r.id ? 1.15 : 1) : 0.4)
                    .opacity(shown ? (focus == nil || focus == r.id ? 1 : 0.35) : 0)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(Double(r.id) * 0.08), value: shown)
                    .position(spot)
            }
        }
        .frame(width: axisW + side, height: side + axisH + 8, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .onAppear { shown = true }
    }

    private func rect(_ likelihood: Int, _ impact: Int) -> CGRect {
        CGRect(x: axisW + CGFloat(likelihood - 1) * cell, y: CGFloat(3 - impact) * cell, width: cell, height: cell)
    }

    /// Hazards sharing a cell sit side by side.
    private func spot(_ r: Critique.Risk) -> CGPoint {
        let mates = risks.filter { $0.likelihood == r.likelihood && $0.impact == r.impact }
        let k = mates.firstIndex(of: r) ?? 0
        let c = rect(r.likelihood, r.impact)
        let spread: CGFloat = 32
        let x = c.midX + (CGFloat(k) - CGFloat(mates.count - 1) / 2) * spread
        return CGPoint(x: x, y: c.midY)
    }
}

/// A hazard's number in a circle, coloured by how bad it would be; filled when nothing guards it.
struct RiskMarker: View {
    let risk: Critique.Risk
    var size: CGFloat = 22
    var focused = false

    var body: some View {
        let tint = RiskPage.tint(risk)
        let open = risk.guardedBy.isEmpty
        ZStack {
            Circle().fill(open ? tint : Color.paper)
            Circle().strokeBorder(tint, lineWidth: focused ? 1.4 : 1)
            Text("\(risk.id + 1)")
                .font(.serif(size * 0.56, .medium))
                .foregroundStyle(open ? Color.paper : tint)
        }
        .frame(width: size, height: size)
        .help(risk.title)
    }
}

/// One hazard: what fails, when, who notices, and what in the change guards against it.
struct HazardRow: View {
    @Bindable var session: PRSession
    let risk: Critique.Risk
    @Binding var focus: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            RiskMarker(risk: risk, size: 22, focused: focus == risk.id)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(risk.title)
                        .font(.serif(19.5))
                        .foregroundStyle(Color.text1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(grade)
                        .font(.smallCaps(11.5))
                        .tracking(1)
                        .foregroundStyle(RiskPage.tint(risk))
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 5) {
                    line("When", Prose.sentence(risk.when))
                    line("Then", Prose.sentence(risk.effect))
                    if risk.guardedBy.isEmpty {
                        line("Guard", "Nothing in this change", tint: .removed, italic: true)
                    } else {
                        line("Guard", Prose.sentence(risk.guardedBy))
                    }
                }
                if let h = risk.hunks.first {
                    InkButton(title: "See it in the code") { session.go(toHunk: h) }
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(Color.wash(focus == risk.id ? 0.035 : 0))
        .overlay(alignment: .bottom) { Rule(opacity: 0.08) }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { focus = QA.hover(h) ? risk.id : (focus == risk.id ? nil : focus) } }
    }

    private var grade: String {
        let l = ["rare", "possible", "likely"][risk.likelihood - 1]
        let i = ["minor", "serious", "severe"][risk.impact - 1]
        return "\(l) · \(i)"
    }

    private func line(_ label: String, _ text: String, tint: Color = .text2, italic: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.smallCaps(11.5))
                .tracking(1.1)
                .foregroundStyle(Color.text3)
                .frame(width: 44, alignment: .leading)
            Text(text)
                .font(italic ? .serifItalic(16) : .serif(16))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Questions

struct QuestionsPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let qs = session.critique.questions
        let left = qs.filter { !session.settled.contains($0.id) }.count
        PageFrame(page: .questions, title: title(qs.count, left: left),
                  dek: qs.isEmpty ? nil : Text("Settle each one yourself, ask Fathom to look into it, or put it to the author as a comment."),
                  waiting: session.critiqueState.isRunning) {
            VStack(alignment: .leading, spacing: 0) {
                Rule(opacity: 0.12)
                ForEach(qs) { q in
                    QuestionRow(session: session, question: q)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func title(_ n: Int, left: Int) -> String {
        guard n > 0 else { return "" }
        if left == 0 { return n == 1 ? "The one open question is settled" : "All \(Prose.word(n).lowercased()) questions are settled" }
        return n == 1 ? "One question this change leaves open" : "\(Prose.word(n)) questions this change leaves open"
    }
}

/// A question, why it matters, and what you can do with it.
struct QuestionRow: View {
    @Bindable var session: PRSession
    let question: Critique.Question

    var body: some View {
        let settled = session.settled.contains(question.id)
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("5.\(question.id + 1)")
                .font(.serif(18))
                .foregroundStyle(Color.text3)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                Text(question.q)
                    .font(.serif(22))
                    .lineSpacing(3)
                    .foregroundStyle(settled ? Color.text3 : Color.text1)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !question.why.isEmpty {
                    Text(Prose.sentence(question.why))
                        .font(.serifItalic(16.5))
                        .foregroundStyle(settled ? Color.text3 : Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 22) {
                    InkButton(title: "Ask Fathom", icon: nil, leading: "sparkle", tint: .sonar) {
                        session.ask(question.q)
                    }
                    .disabled(session.askRunning)
                    .help("Fathom looks into it in the repository and answers beside the reading")
                    if !question.hunk.isEmpty {
                        InkButton(title: "Ask the author", icon: nil, leading: "text.bubble") {
                            session.askAuthor(question.q, hunk: question.hunk)
                        }
                        .help("Opens a comment on the code with the question written in, for your review")
                        InkButton(title: "Read the code") { session.go(toHunk: question.hunk) }
                    }
                    Spacer()
                    SettleToggle(on: settled) { session.toggleSettled(question.id) }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 26)
        .overlay(alignment: .bottom) { Rule(opacity: 0.12) }
        .animation(Motion.snappy, value: settled)
    }
}

struct SettleToggle: View {
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    Circle().strokeBorder(on ? Color.added : Color.wash(hover ? 0.5 : 0.3), lineWidth: 1)
                    if on {
                        Circle().fill(Color.added).padding(0.5)
                        Image(systemName: "checkmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Color.paper)
                    }
                }
                .frame(width: 14, height: 14)
                Text(on ? "Settled" : "Settle")
                    .font(.smallCaps(12.5))
                    .tracking(1)
                    .foregroundStyle(on ? Color.added : hover ? Color.text1 : Color.text3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .help(on ? "Mark it open again" : "You've thought it through")
    }
}

// MARK: - Evidence

struct EvidencePage: View {
    @Bindable var session: PRSession

    var body: some View {
        let ev = session.critique.evidence
        let firsts = ev.reduce(into: [Int]()) { out, e in out.append((out.last ?? 1) + (out.isEmpty ? 0 : ev[out.count - 1].marks.count)) }
        PageFrame(page: .evidence,
                  title: ev.isEmpty ? "" : "If you read nothing else, read \(ev.count == 1 ? "this" : "these \(Prose.word(ev.count).lowercased())")",
                  dek: ev.contains { !$0.marks.isEmpty } ? Text("Numbered lines carry a note in the margin.") : nil,
                  waiting: session.critiqueState.isRunning) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ev.enumerated()), id: \.element.id) { i, e in
                    Passage(session: session, evidence: e, first: firsts[i])
                        .padding(.top, i == 0 ? 0 : 44)
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .environment(\.inPanel, true)
        }
    }
}

private struct MarkSpots: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One passage: why it matters, its lines, and notes in the margin beside the lines they're about.
struct Passage: View {
    @Bindable var session: PRSession
    let evidence: Critique.Evidence
    let first: Int

    private let margin: CGFloat = 250

    var body: some View {
        let marks = located
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("6.\(evidence.id + 1)")
                    .font(.serif(16))
                    .foregroundStyle(Color.text3)
                Text(Prose.sentence(evidence.why))
                    .font(.serif(19))
                    .foregroundStyle(Color.text1)
                Spacer()
                InkButton(title: "In Changes") { session.go(toHunk: evidence.hunk) }
                    .help("Read it in place, with what's around it")
            }
            .padding(.bottom, 10)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(session.lookRows(evidence.hunk)) { row in
                        let n = number(row, marks)
                        DocRowView(session: session, row: row)
                            .overlay(alignment: .trailing) {
                                if let n {
                                    Text("\(n)")
                                        .font(.serif(12.5, .semibold))
                                        .foregroundStyle(Color.sonar)
                                        .padding(.horizontal, 5)
                                        .background(Capsule().fill(Color.paper.opacity(0.9)))
                                        .padding(.trailing, 6)
                                }
                            }
                            .anchorPreference(key: MarkSpots.self, value: .bounds) { a in n.map { [$0: a] } ?? [:] }
                    }
                }
                .frame(maxWidth: .infinity)
                Color.clear.frame(width: margin)
            }
            .overlayPreferenceValue(MarkSpots.self) { spots in
                GeometryReader { g in
                    let placed = place(spots, g)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in
                            for p in placed {
                                var leader = Path()
                                let x0 = size.width - margin + 2, x1 = size.width - margin + 16
                                leader.move(to: CGPoint(x: x0, y: p.lineY))
                                leader.addLine(to: CGPoint(x: x1, y: p.noteY + 10))
                                ctx.stroke(leader, with: .color(Color.sonar.opacity(0.5)), lineWidth: 0.75)
                            }
                        }
                        ForEach(placed, id: \.n) { p in
                            (Text("\(p.n)  ").font(.serif(12.5, .semibold)).foregroundStyle(Color.sonar)
                             + Text(Prose.sentence(p.note)).font(.serifItalic(14.5)).foregroundStyle(Color.text2))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: margin - 26, alignment: .leading)
                                .offset(x: g.size.width - margin + 20, y: p.noteY)
                        }
                    }
                }
            }
            let lost = evidence.marks.indices.filter { marks[$0] == nil }
            if !lost.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lost, id: \.self) { k in
                        (Text("\(first + k)  ").font(.serif(12.5, .semibold)).foregroundStyle(Color.sonar)
                         + Text(Prose.sentence(evidence.marks[k].note)).font(.serifItalic(14.5)).foregroundStyle(Color.text2))
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    /// Each mark's line in the hunk, when its words can be found there.
    private var located: [Int: Int] {
        guard let diff = session.diff else { return [:] }
        var out: [Int: Int] = [:]
        for (k, m) in evidence.marks.enumerated() {
            if let i = diff.lineIndex(hunk: evidence.hunk, anchor: m.anchor) { out[k] = i }
        }
        return out
    }

    private func number(_ row: DocRow, _ marks: [Int: Int]) -> Int? {
        guard case .line(_, let h, let i, _, _) = row.kind, h.id == evidence.hunk,
              let k = marks.first(where: { $0.value == i })?.key else { return nil }
        return first + k
    }

    private struct Placed {
        var n: Int
        var note: String
        var lineY: CGFloat
        var noteY: CGFloat
    }

    /// Notes beside their lines, pushed down where they'd overlap.
    private func place(_ spots: [Int: Anchor<CGRect>], _ g: GeometryProxy) -> [Placed] {
        var out: [Placed] = []
        var floor: CGFloat = -1000
        for (n, anchor) in spots.sorted(by: { $0.key < $1.key }) {
            let k = n - first
            guard evidence.marks.indices.contains(k) else { continue }
            let r = g[anchor]
            let y = max(r.midY - 10, floor)
            out.append(Placed(n: n, note: evidence.marks[k].note, lineY: r.midY, noteY: y))
            floor = y + 48
        }
        return out
    }
}
