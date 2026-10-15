// The Story tab: a pull request told the way you'd explain it at a whiteboard. One page at a time, each a sentence
// and a small diagram: the problem, the idea, how it works now, the choices made, the promises that change, and
// the few places in the code worth reading. ← and → turn the pages.

import SwiftUI

enum StoryPage: Int, CaseIterable, Identifiable {
    case overview, problem, idea, now, choices, promises, code
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .problem: "Problem"
        case .idea: "Idea"
        case .now: "Now"
        case .choices: "Choices"
        case .promises: "Promises"
        case .code: "Code"
        }
    }

    var eyebrow: String {
        switch self {
        case .overview: "The story"
        case .problem: "The problem"
        case .idea: "The idea"
        case .now: "How it works now"
        case .choices: "Choices it makes"
        case .promises: "Promises that change"
        case .code: "Where to look"
        }
    }

    var icon: String {
        switch self {
        case .overview: "book.pages"
        case .problem: "exclamationmark.triangle"
        case .idea: "lightbulb"
        case .now: "arrow.triangle.turn.up.right.diamond"
        case .choices: "arrow.triangle.branch"
        case .promises: "curlybraces"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .text2
        case .problem: .removed
        case .idea: .sonar
        case .now: .added
        case .choices: .changed
        case .promises: .calm
        case .code: Color(hex: 0xB49CFF)
        }
    }
}

struct StoryView: View {
    @Bindable var session: PRSession
    @State private var page: StoryPage = .overview
    @State private var forward = true
    @FocusState private var focused: Bool

    private var pages: [StoryPage] {
        StoryPage.allCases.filter { p in
            switch p {
            case .choices: !session.story.choices.isEmpty || session.storyState.isRunning
            case .promises: !session.brief.contracts.isEmpty || session.briefState.isRunning
            case .code: !session.story.look.isEmpty || session.storyState.isRunning
            default: true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StoryNav(pages: pages, page: page) { go($0) }
                .padding(.top, 6)
                .padding(.bottom, 4)
            ZStack {
                if session.story.isEmpty && !session.storyState.isDone {
                    if let failure = session.storyState.failure {
                        StoryFailure(message: failure) { session.sound() }
                    } else {
                        SonarView(session: session)
                    }
                } else {
                    pageView(page)
                        .id(page)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
                                                removal: .opacity.combined(with: .offset(x: forward ? -40 : 40))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StoryFooter(pages: pages, page: page) { go($0) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onAppear { focused = true }
        .onChange(of: session.tab) { _, tab in focused = tab == .brief }
        .onChange(of: session.ref) { _, _ in page = .overview }
        .task {
            // FATHOM_PAGE=idea opens the story on that page, for screenshots.
            if let name = session.store?.env["FATHOM_PAGE"], let p = StoryPage.allCases.first(where: { $0.title.lowercased() == name.lowercased() }) {
                page = p
            }
        }
    }

    private func step(_ delta: Int) {
        guard let i = pages.firstIndex(of: page) else { return }
        let j = min(max(i + delta, 0), pages.count - 1)
        if j != i { go(pages[j]) }
    }

    private func go(_ p: StoryPage) {
        forward = p.rawValue > page.rawValue
        withAnimation(.smooth(duration: 0.38)) { page = p }
    }

    @ViewBuilder
    private func pageView(_ p: StoryPage) -> some View {
        switch p {
        case .overview: OverviewPage(session: session) { go($0) }
        case .problem: ProblemPage(session: session)
        case .idea: IdeaPage(session: session)
        case .now: NowPage(session: session)
        case .choices: ChoicesPage(session: session)
        case .promises: PromisesPage(session: session)
        case .code: CodePage(session: session)
        }
    }
}

// MARK: - Chrome

/// The pages as a row of quiet tabs, the current one lit.
struct StoryNav: View {
    let pages: [StoryPage]
    let page: StoryPage
    let go: (StoryPage) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(pages) { p in
                let on = p == page
                Button { go(p) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: p.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(on ? p.tint : Color.text3)
                        Text(p.title)
                            .font(.system(size: 12, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Color.text1 : Color.text3)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Capsule().fill(on ? p.tint.opacity(0.14) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.035)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        .animation(Motion.snappy, value: page)
    }
}

struct StoryFooter: View {
    let pages: [StoryPage]
    let page: StoryPage
    let go: (StoryPage) -> Void

    var body: some View {
        let i = pages.firstIndex(of: page) ?? 0
        HStack {
            if i > 0 {
                Button { go(pages[i - 1]) } label: {
                    Label(pages[i - 1].title, systemImage: "arrow.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.text3)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("← →")
                .font(.mono(10.5))
                .foregroundStyle(Color.text3.opacity(0.6))
            Spacer()
            if i + 1 < pages.count {
                Button { go(pages[i + 1]) } label: {
                    HStack(spacing: 6) {
                        Text("Next: \(pages[i + 1].eyebrow.lowercased())")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(pages[i + 1].tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 44)
    }
}

/// The frame every page shares: a small eyebrow, the sentence, then the picture.
struct PageFrame<Content: View>: View {
    let page: StoryPage
    let title: String
    var waiting = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", page.rawValue))
                    .font(.mono(11, .semibold))
                    .foregroundStyle(page.tint.opacity(0.7))
                Text(page.eyebrow.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(page.tint)
            }
            .padding(.bottom, 12)
            if title.isEmpty && waiting {
                Skeleton(lines: [0.62], height: 30).frame(maxWidth: 760)
            } else {
                Text(title)
                    .font(.serif(36))
                    .tracking(-0.6)
                    .foregroundStyle(Color.text1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
                    .textSelection(.enabled)
            }
            content
                .padding(.top, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 56)
        .padding(.top, 34)
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }
}

struct StoryFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("No story this time")
                .font(.serif(24))
                .foregroundStyle(Color.text1)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Read again", action: retry)
                .buttonStyle(.glass)
        }
    }
}

// MARK: - Overview

/// The whole story in five sentences. Most of the time this is enough to know what you're looking at.
struct OverviewPage: View {
    @Bindable var session: PRSession
    let go: (StoryPage) -> Void

    var body: some View {
        let s = session.story, b = session.brief
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let d = session.detail {
                    Avatar(url: d.authorAvatar, name: d.author, size: 18)
                    Text(d.author).foregroundStyle(Color.text2)
                    dot
                }
                if !b.kind.isEmpty { Text(Glyph.kindWord(b.kind)); dot }
                if let d = session.diff {
                    Text("\(d.files.count) files")
                    dot
                    DiffStat(additions: d.additions, deletions: d.deletions, bar: false, size: 12)
                }
                if session.isSounding { dot; ReadingClock(session: session) }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color.text3)
            .padding(.bottom, 16)

            if b.headline.isEmpty {
                Skeleton(lines: [0.55], height: 38).frame(maxWidth: 820)
            } else {
                Text(b.headline)
                    .font(.serif(44))
                    .tracking(-0.9)
                    .foregroundStyle(Color.text1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 920, alignment: .leading)
                    .textSelection(.enabled)
            }

            VStack(spacing: 2) {
                row(.problem, s.problemTitle)
                row(.idea, s.ideaTitle)
                row(.now, s.solutionTitle)
                if !s.choices.isEmpty {
                    row(.choices, s.choices.map(\.title).joined(separator: " · "),
                        count: "\(s.choices.count) choice\(s.choices.count == 1 ? "" : "s")")
                }
                if !b.contracts.isEmpty {
                    row(.promises, b.contracts.map(\.name).joined(separator: ", "),
                        count: "\(b.contracts.count) interface\(b.contracts.count == 1 ? "" : "s")")
                }
                if !s.look.isEmpty {
                    row(.code, s.look.first?.why ?? "", count: "\(s.look.count) place\(s.look.count == 1 ? "" : "s") to read")
                }
            }
            .padding(.top, 40)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .padding(.horizontal, 56)
        .padding(.top, 40)
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    private var dot: some View { Text("·").foregroundStyle(Color.text3.opacity(0.6)) }

    private func row(_ p: StoryPage, _ text: String, count: String = "") -> some View {
        OverviewRow(page: p, text: text, count: count, waiting: session.storyState.isRunning) { go(p) }
    }
}

struct OverviewRow: View {
    let page: StoryPage
    let text: String
    let count: String
    let waiting: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                HStack(spacing: 7) {
                    Image(systemName: page.icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(page.title.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(1.3)
                }
                .foregroundStyle(page.tint)
                .frame(width: 116, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    if text.isEmpty && waiting {
                        Skeleton(lines: [0.5], height: 14).frame(maxWidth: 460)
                    } else {
                        Text(text)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.text1.opacity(0.92))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !count.isEmpty {
                        Text(count)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.text3)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(page.tint.opacity(hover ? 1 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.045 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
    }
}

// MARK: - Problem and Now

struct ProblemPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let s = session.story
        PageFrame(page: .problem, title: s.problemTitle, waiting: session.storyState.isRunning) {
            StorySequence(steps: s.problemSteps, actors: actorOrder(s), kinds: kinds(s), painStep: s.painStep, pain: s.pain,
                          tint: .text2)
        }
    }
}

struct NowPage: View {
    @Bindable var session: PRSession
    @State private var before = false

    var body: some View {
        let s = session.story
        PageFrame(page: .now, title: s.solutionTitle, waiting: session.storyState.isRunning) {
            VStack(alignment: .leading, spacing: 18) {
                if !s.problemSteps.isEmpty {
                    HStack(spacing: 2) {
                        ForEach([false, true], id: \.self) { b in
                            Button {
                                withAnimation(.smooth(duration: 0.35)) { before = b }
                            } label: {
                                Text(b ? "Before" : "After")
                                    .font(.system(size: 11.5, weight: before == b ? .semibold : .medium))
                                    .foregroundStyle(before == b ? Color.text1 : Color.text3)
                                    .padding(.horizontal, 12)
                                    .frame(height: 24)
                                    .background(Capsule().fill(before == b ? Color.white.opacity(0.1) : .clear))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Capsule().fill(Color.black.opacity(0.25)))
                }
                if before {
                    StorySequence(steps: s.problemSteps, actors: actorOrder(s), kinds: kinds(s), painStep: s.painStep, pain: s.pain,
                                  tint: .text2)
                        .id("before")
                } else {
                    StorySequence(steps: s.solutionSteps, actors: actorOrder(s), kinds: kinds(s), tint: .text2)
                        .id("after")
                }
            }
        }
    }
}

/// The same actors, in the same columns, on both the Problem and the Now pages, so the two read as one picture.
private func actorOrder(_ s: Story) -> [String] {
    var order: [String] = []
    for step in s.problemSteps + s.solutionSteps {
        for a in [step.from, step.to] where !order.contains(a) { order.append(a) }
    }
    return order
}

/// What kind of thing each actor is, where the idea names it.
private func kinds(_ s: Story) -> [String: String] {
    var out: [String: String] = [:]
    func norm(_ x: String) -> String { x.lowercased().filter { $0.isLetter || $0.isNumber } }
    for a in actorOrder(s) {
        let n = norm(a)
        if let p = s.parts.first(where: { let m = norm($0.name); return !m.isEmpty && (m == n || m.contains(n) || n.contains(m)) }) {
            out[a] = p.kind
        }
    }
    return out
}

/// A sequence diagram that draws itself one step at a time: actors along the top, a row per step, what's said above
/// each arrow and what travels below it. New steps are green; the step where it hurts ends in a cross.
struct StorySequence: View {
    let steps: [Story.Step]
    let actors: [String]
    var kinds: [String: String] = [:]
    var painStep = -2
    var pain = ""
    let tint: Color

    @State private var shown = 0
    private let headerH: CGFloat = 46
    private let rowH: CGFloat = 70

    private var columns: [String] {
        // Only the actors this telling uses, in the shared order.
        let used = Set(steps.flatMap { [$0.from, $0.to] })
        return actors.filter { used.contains($0) }
    }

    private var missing: Bool { painStep == -1 && !pain.isEmpty }
    private var rows: Int { steps.count + (missing ? 1 : 0) }

    var body: some View {
        GeometryReader { geo in
            let cols = columns
            let colW = geo.size.width / CGFloat(max(cols.count, 1))
            let x: (String) -> CGFloat = { a in (CGFloat(cols.firstIndex(of: a) ?? 0) + 0.5) * colW }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for a in cols {
                        var p = Path()
                        p.move(to: CGPoint(x: x(a), y: headerH))
                        p.addLine(to: CGPoint(x: x(a), y: size.height - 6))
                        ctx.stroke(p, with: .color(.white.opacity(0.09)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    }
                    for (k, step) in steps.enumerated() where k < shown {
                        let y = rowY(k)
                        let hurt = k == painStep
                        let color: Color = hurt ? .removed : step.isNew ? .added : tint
                        arrow(&ctx, from: x(step.from), to: x(step.to), y: y, color: color, emphasis: hurt || step.isNew)
                        if hurt { cross(&ctx, at: CGPoint(x: x(step.to) + (step.from == step.to ? 44 : 0), y: y)) }
                    }
                    if missing && shown >= steps.count, let last = steps.last {
                        // The step that never happened.
                        let y = rowY(steps.count)
                        let from = x(last.to), to = from + min(colW * 0.9, 170)
                        var p = Path()
                        p.move(to: CGPoint(x: from, y: y))
                        p.addLine(to: CGPoint(x: to, y: y))
                        ctx.stroke(p, with: .color(Color.removed.opacity(0.75)), style: StrokeStyle(lineWidth: 1.6, dash: [5, 5]))
                        cross(&ctx, at: CGPoint(x: to, y: y))
                    }
                }

                ForEach(Array(cols.enumerated()), id: \.element) { _, a in
                    ActorChip(name: a, kind: kinds[a])
                        .frame(maxWidth: colW - 8)
                        .position(x: x(a), y: 16)
                }

                ForEach(Array(steps.enumerated()), id: \.offset) { k, step in
                    let x0 = x(step.from), x1 = x(step.to)
                    let selfCall = step.from == step.to
                    let span = selfCall ? min(colW * 1.3, 260) : max(abs(x1 - x0) - 16, 150)
                    let mid = selfCall ? x0 + 64 + span / 2 : (x0 + x1) / 2
                    let hurt = k == painStep
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            Text("\(k + 1)")
                                .font(.mono(9.5, .bold))
                                .foregroundStyle(Color.ink)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(hurt ? Color.removed : step.isNew ? Color.added : Color.text3))
                            Text(step.does)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(hurt ? Color.removed : Color.text1)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if step.isNew {
                                Text("NEW")
                                    .font(.system(size: 8, weight: .heavy))
                                    .tracking(0.5)
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.added))
                            }
                        }
                        Color.clear.frame(height: 6)
                        if !step.data.isEmpty {
                            Text(step.data)
                                .font(.mono(11, .medium))
                                .foregroundStyle(step.isNew ? Color.added : Color.calm)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.ink.opacity(0.85)))
                        }
                    }
                    .frame(width: span)
                    .position(x: min(max(mid, span / 2 + 4), geo.size.width - span / 2 - 4), y: rowY(k) - 3)
                    .opacity(k < shown ? 1 : 0)
                    .offset(y: k < shown ? 0 : 6)

                    if hurt && !pain.isEmpty {
                        PainNote(text: pain)
                            .position(x: min(max(selfCall ? x1 + 64 + span / 2 : (x0 + x1) / 2, 150), geo.size.width - 150), y: rowY(k) + 44)
                            .opacity(k < shown ? 1 : 0)
                    }
                }
                if missing, let last = steps.last {
                    PainNote(text: pain)
                        .position(x: min(x(last.to) + min(colW * 0.9, 170) / 2, geo.size.width - 150), y: rowY(steps.count) - 26)
                        .opacity(shown >= steps.count ? 1 : 0)
                }
            }
        }
        .frame(height: headerH + 30 + CGFloat(rows) * rowH + (painStep >= 0 && !pain.isEmpty ? 46 : 0))
        .frame(maxWidth: 1060)
        .animation(.smooth(duration: 0.35), value: shown)
        .task(id: steps.count) {
            // One step at a time, the way you'd draw it on a whiteboard.
            if shown > steps.count { shown = steps.count }
            while shown < steps.count {
                try? await Task.sleep(for: .milliseconds(shown == 0 ? 250 : 420))
                if Task.isCancelled { return }
                shown += 1
            }
        }
    }

    /// The step that hurts gets room under it for its note.
    private func rowY(_ k: Int) -> CGFloat {
        headerH + 44 + CGFloat(k) * rowH + (painStep >= 0 && k > painStep && !pain.isEmpty ? 46 : 0)
    }

    private func arrow(_ ctx: inout GraphicsContext, from x0: CGFloat, to x1: CGFloat, y: CGFloat, color: Color, emphasis: Bool) {
        var p = Path()
        let tip: CGPoint
        let dir: CGFloat
        if abs(x0 - x1) < 1 {
            p.move(to: CGPoint(x: x0, y: y - 9))
            p.addCurve(to: CGPoint(x: x0 + 2, y: y + 9), control1: CGPoint(x: x0 + 40, y: y - 14), control2: CGPoint(x: x0 + 40, y: y + 14))
            tip = CGPoint(x: x0 + 2, y: y + 9)
            dir = -1
        } else {
            dir = x1 > x0 ? 1 : -1
            p.move(to: CGPoint(x: x0, y: y))
            p.addLine(to: CGPoint(x: x1 - dir * 4, y: y))
            tip = CGPoint(x: x1 - dir * 1, y: y)
        }
        if emphasis {
            ctx.stroke(p, with: .color(color.opacity(0.22)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        ctx.stroke(p, with: .color(color.opacity(emphasis ? 0.95 : 0.55)), style: StrokeStyle(lineWidth: emphasis ? 2 : 1.4, lineCap: .round))
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - dir * 8, y: tip.y - 4.5))
        head.addLine(to: CGPoint(x: tip.x - dir * 8, y: tip.y + 4.5))
        head.closeSubpath()
        ctx.fill(head, with: .color(color.opacity(emphasis ? 0.95 : 0.6)))
        ctx.fill(Path(ellipseIn: CGRect(x: x0 - 3, y: y - 3, width: 6, height: 6)), with: .color(color.opacity(0.8)))
    }

    private func cross(_ ctx: inout GraphicsContext, at c: CGPoint) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)), with: .color(Color.removed))
        var x = Path()
        x.move(to: CGPoint(x: c.x - 4.5, y: c.y - 4.5)); x.addLine(to: CGPoint(x: c.x + 4.5, y: c.y + 4.5))
        x.move(to: CGPoint(x: c.x + 4.5, y: c.y - 4.5)); x.addLine(to: CGPoint(x: c.x - 4.5, y: c.y + 4.5))
        ctx.stroke(x, with: .color(Color.ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }
}

struct ActorChip: View {
    let name: String
    let kind: String?

    var body: some View {
        let person = name.lowercased() == "you" || name.lowercased() == "user"
        HStack(spacing: 6) {
            Image(systemName: person ? "person.fill" : Glyph.component(kind ?? "service"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(person ? Color.sonar : Color.text2)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.text1)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x111720)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75))
    }
}

struct PainNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.removed)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.removed.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.removed.opacity(0.35), lineWidth: 0.75))
            .frame(maxWidth: 280)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Idea

struct IdeaPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let s = session.story
        PageFrame(page: .idea, title: s.ideaTitle, waiting: session.storyState.isRunning) {
            IdeaGraph(parts: s.parts, links: s.links)
        }
    }
}

/// The few parts that carry the idea, left to right in the order things happen, new ones glowing.
struct IdeaGraph: View {
    let parts: [Story.Part]
    let links: [Story.Link]
    @State private var drawn = false

    private let nodeW: CGFloat = 214
    private let nodeH: CGFloat = 66

    var body: some View {
        GeometryReader { geo in
            let place = layout(geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for l in links {
                        guard let a = place[l.from], let b = place[l.to] else { continue }
                        let d = shift(l)
                        let (path, tip, dir) = curve(CGPoint(x: a.x, y: a.y + d), CGPoint(x: b.x, y: b.y + d))
                        let color: Color = l.isNew ? .added : .white
                        if l.isNew { ctx.stroke(path, with: .color(color.opacity(0.18)), style: StrokeStyle(lineWidth: 7, lineCap: .round)) }
                        ctx.stroke(path, with: .color(color.opacity(l.isNew ? 0.85 : 0.32)), style: StrokeStyle(lineWidth: l.isNew ? 1.8 : 1.3, lineCap: .round))
                        var head = Path()
                        head.move(to: tip)
                        head.addLine(to: CGPoint(x: tip.x - dir.dx * 8 - dir.dy * 4.5, y: tip.y - dir.dy * 8 + dir.dx * 4.5))
                        head.addLine(to: CGPoint(x: tip.x - dir.dx * 8 + dir.dy * 4.5, y: tip.y - dir.dy * 8 - dir.dx * 4.5))
                        head.closeSubpath()
                        ctx.fill(head, with: .color(color.opacity(l.isNew ? 0.9 : 0.4)))
                    }
                }
                .opacity(drawn ? 1 : 0)

                let spots = labelSpots(place)
                ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                    if let spot = spots[i] {
                        Text(l.label)
                            .font(.mono(10.5, .medium))
                            .foregroundStyle(l.isNew ? Color.added : Color.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: 0x0B0F15)))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                            .fixedSize()
                            .position(spot)
                            .opacity(drawn ? 1 : 0)
                    }
                }

                ForEach(parts) { p in
                    if let c = place[p.id] {
                        PartCard(part: p)
                            .frame(width: nodeW, height: nodeH)
                            .position(c)
                            .scaleEffect(drawn ? 1 : 0.92)
                            .opacity(drawn ? 1 : 0)
                    }
                }
            }
        }
        .frame(maxWidth: 1080)
        .frame(height: min(max(CGFloat(tallest) * (nodeH + 30) + 40, 260), 560))
        .onAppear { withAnimation(.smooth(duration: 0.6).delay(0.1)) { drawn = true } }
    }

    /// Columns by how many links a part is from where things start (loops don't push parts further right);
    /// a part's row by the order it was named. The drawing is centred, columns no wider than they need to be.
    private var ranks: [String: Int] {
        var incoming = Set(links.map(\.to))
        if incoming.count == parts.count { incoming.remove(parts.first?.id ?? "") }
        var rank: [String: Int] = [:]
        var queue = parts.map(\.id).filter { !incoming.contains($0) }
        for id in queue { rank[id] = 0 }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for l in links where l.from == id && rank[l.to] == nil {
                rank[l.to] = (rank[id] ?? 0) + 1
                queue.append(l.to)
            }
        }
        for p in parts where rank[p.id] == nil { rank[p.id] = 0 }
        return rank
    }

    private var tallest: Int {
        Dictionary(grouping: parts, by: { ranks[$0.id] ?? 0 }).values.map(\.count).max() ?? 1
    }

    private func layout(_ size: CGSize) -> [String: CGPoint] {
        let rank = ranks
        let columns = (rank.values.max() ?? 0) + 1
        var byColumn: [[String]] = Array(repeating: [], count: columns)
        for p in parts { byColumn[rank[p.id] ?? 0].append(p.id) }
        let colW = min(size.width / CGFloat(columns), nodeW + 190)
        let left = (size.width - colW * CGFloat(columns)) / 2
        var out: [String: CGPoint] = [:]
        for (c, ids) in byColumn.enumerated() {
            let gap = min((size.height - 20) / CGFloat(max(ids.count, 1)), nodeH + 56)
            let top = size.height / 2 - gap * CGFloat(ids.count - 1) / 2
            for (i, id) in ids.enumerated() {
                out[id] = CGPoint(x: left + (CGFloat(c) + 0.5) * colW, y: top + CGFloat(i) * gap)
            }
        }
        return out
    }

    /// Links that go both ways between two parts sit a little apart, so both read.
    private func shift(_ l: Story.Link) -> CGFloat {
        guard links.contains(where: { $0.from == l.to && $0.to == l.from }) else { return 0 }
        return l.from < l.to ? -9 : 9
    }

    private func curve(_ a: CGPoint, _ b: CGPoint) -> (Path, CGPoint, CGVector) {
        var p = Path()
        if abs(a.x - b.x) < 4 {
            let down = b.y > a.y
            let s = CGPoint(x: a.x, y: a.y + (down ? nodeH / 2 : -nodeH / 2))
            let e = CGPoint(x: b.x, y: b.y + (down ? -nodeH / 2 - 2 : nodeH / 2 + 2))
            p.move(to: s)
            p.addLine(to: CGPoint(x: e.x, y: e.y - (down ? 4 : -4)))
            return (p, e, CGVector(dx: 0, dy: down ? 1 : -1))
        }
        let right = b.x > a.x
        let s = CGPoint(x: a.x + (right ? nodeW / 2 : -nodeW / 2), y: a.y)
        let e = CGPoint(x: b.x + (right ? -nodeW / 2 - 2 : nodeW / 2 + 2), y: b.y)
        let dx = (e.x - s.x) * 0.5
        p.move(to: s)
        p.addCurve(to: CGPoint(x: e.x - (right ? 4 : -4), y: e.y), control1: CGPoint(x: s.x + dx, y: s.y), control2: CGPoint(x: e.x - dx, y: e.y))
        return (p, e, CGVector(dx: right ? 1 : -1, dy: 0))
    }

    /// Where each link's label sits: on its curve, at the first spot clear of the parts and of other labels,
    /// trying near where it lands first (a fan of links spreads out there). A label with no room is left off.
    private func labelSpots(_ place: [String: CGPoint]) -> [Int: CGPoint] {
        var taken = place.values.map { CGRect(x: $0.x - nodeW / 2 - 4, y: $0.y - nodeH / 2 - 4, width: nodeW + 8, height: nodeH + 8) }
        var out: [Int: CGPoint] = [:]
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        for (i, l) in links.enumerated() {
            guard let a0 = place[l.from], let b0 = place[l.to], !l.label.isEmpty else { continue }
            let d = shift(l) * 2.6
            let a = CGPoint(x: a0.x, y: a0.y + d), b = CGPoint(x: b0.x, y: b0.y + d)
            let w = (l.label as NSString).size(withAttributes: [.font: font]).width + 16, h: CGFloat = 20
            for t in [0.64, 0.5, 0.78, 0.36, 0.86] as [CGFloat] {
                let p = labelPoint(a, b, t: t)
                let r = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
                if !taken.contains(where: { $0.intersects(r) }) {
                    taken.append(r.insetBy(dx: -3, dy: -2))
                    out[i] = p
                    break
                }
            }
        }
        return out
    }

    private func labelPoint(_ a: CGPoint, _ b: CGPoint, t: CGFloat) -> CGPoint {
        if abs(a.x - b.x) < 4 { return CGPoint(x: a.x + 70, y: a.y + (b.y - a.y) * t) }
        let right = b.x > a.x
        let s = CGPoint(x: a.x + (right ? nodeW / 2 : -nodeW / 2), y: a.y)
        let e = CGPoint(x: b.x + (right ? -nodeW / 2 : nodeW / 2), y: b.y)
        let u = 1 - t
        let dx = (e.x - s.x) * 0.5
        let c1 = CGPoint(x: s.x + dx, y: s.y), c2 = CGPoint(x: e.x - dx, y: e.y)
        let x = u * u * u * s.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * e.x
        let y = u * u * u * s.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * e.y
        return CGPoint(x: x, y: y - 13)
    }
}

struct PartCard: View {
    let part: Story.Part

    var body: some View {
        let tint: Color = part.isNew ? .added : .text2
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: Glyph.component(part.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(part.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(part.role)
                .font(.system(size: 12))
                .foregroundStyle(Color.text3)
                .lineLimit(2)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if part.isNew {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.added.opacity(0.25)).blur(radius: 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x10161F)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(part.isNew ? Color.added.opacity(0.75) : Color.white.opacity(0.12), lineWidth: part.isNew ? 1.2 : 0.8))
        .overlay(alignment: .topTrailing) {
            if part.isNew {
                Text("NEW")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.added))
                    .offset(x: 6, y: -7)
            }
        }
    }
}

// MARK: - Choices

struct ChoicesPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let choices = session.story.choices
        PageFrame(page: .choices, title: choices.isEmpty ? "" : "\(choices.count == 1 ? "One choice" : "\(Self.word(choices.count)) choices") shape this change",
                  waiting: session.storyState.isRunning) {
            ScrollView {
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    ForEach(Array(stride(from: 0, to: choices.count, by: 2)), id: \.self) { i in
                        GridRow(alignment: .top) {
                            ChoiceCard(session: session, choice: choices[i])
                            if i + 1 < choices.count {
                                ChoiceCard(session: session, choice: choices[i + 1])
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
                .frame(maxWidth: 1080)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }

    static func word(_ n: Int) -> String {
        ["Zero", "One", "Two", "Three", "Four", "Five", "Six"][min(n, 6)]
    }
}

struct ChoiceCard: View {
    @Bindable var session: PRSession
    let choice: Story.Choice
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%02d", choice.id + 1))
                    .font(.mono(11, .semibold))
                    .foregroundStyle(Color.changed.opacity(0.8))
                Text(choice.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.text1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(choice.stated ? "SAID IN THE PR" : "INFERRED")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(choice.stated ? Color.calm : Color.text3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().strokeBorder((choice.stated ? Color.calm : Color.text3).opacity(0.45), lineWidth: 0.75))
                    .help(choice.stated ? "The PR description or a code comment says why" : "Fathom's reading of why; the PR doesn't say")
            }
            VStack(alignment: .leading, spacing: 9) {
                line("checkmark", .added, choice.chose, Color.text1)
                if !choice.over.isEmpty {
                    line("arrow.uturn.left", .text3, Self.lower(choice.over), Color.text3, prefix: "not ")
                }
                if !choice.why.isEmpty {
                    line("quote.opening", .changed, choice.why, Color.text2)
                }
            }
            if !choice.hunks.isEmpty {
                Button {
                    if let h = choice.hunks.first { session.go(toHunk: h) }
                } label: {
                    Label("See it in the code", systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.changed.opacity(hover ? 1 : 0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(hover ? 0.05 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.75))
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
    }

    /// "Resetting state" → "resetting state", but names like "ARView" or "SceneKit" stay as written.
    static func lower(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 1, chars[0].isUppercase, chars[1].isLowercase,
              !s.split(separator: " ").first!.dropFirst().contains(where: \.isUppercase) else { return s }
        return chars[0].lowercased() + String(chars.dropFirst())
    }

    private func line(_ icon: String, _ tint: Color, _ text: String, _ color: Color, prefix: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            (Text(prefix).foregroundStyle(Color.text3) + Text(text).foregroundStyle(color))
                .font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Promises

struct PromisesPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let contracts = session.brief.contracts
        let n = contracts.count
        PageFrame(page: .promises, title: n == 0 ? "" : n == 1 ? "One promise to the rest of the system changes"
                                                         : "\(ChoicesPage.word(n)) promises to the rest of the system change",
                  waiting: session.briefState.isRunning) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(contracts) { c in
                        InterfaceCard(session: session, contract: c, fill: true)
                    }
                }
                .frame(maxWidth: 1080)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Code

struct CodePage: View {
    @Bindable var session: PRSession

    var body: some View {
        let look = session.story.look
        PageFrame(page: .code, title: look.isEmpty ? "" : "If you read nothing else, read \(look.count == 1 ? "this" : "these \(ChoicesPage.word(look.count).lowercased())")",
                  waiting: session.storyState.isRunning) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(look.enumerated()), id: \.offset) { i, l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)")
                                .font(.mono(10, .bold))
                                .foregroundStyle(Color.ink)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(StoryPage.code.tint))
                            Text(l.why)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.text1)
                        }
                        .padding(.top, i == 0 ? 0 : 26)
                        .padding(.bottom, 10)
                        ForEach(session.lookRows(l.hunk)) { row in
                            DocRowView(session: session, row: row)
                        }
                    }
                }
                .frame(maxWidth: 1080, alignment: .leading)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.automatic)
            .environment(\.inPanel, true)
        }
    }
}
