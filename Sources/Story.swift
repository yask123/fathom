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
            StoryNav(pages: pages, page: page, waiting: waiting) { go($0) }
                .padding(.top, 4)
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
        .onKeyPress(.rightArrow) {
            guard !Typing.active else { return .ignored }
            step(1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard !Typing.active else { return .ignored }
            step(-1)
            return .handled
        }
        .onAppear { focused = true }
        .onChange(of: session.tab) { _, tab in focused = tab == .brief }
        // After a comment on the Code page, ← → turn pages again.
        .onChange(of: session.compose == nil) { _, closed in if closed && session.tab == .brief { focused = true } }
        .onChange(of: session.ref) { _, _ in page = .overview }
        .task {
            // FATHOM_PAGE=idea opens the story on that page, for screenshots.
            if let name = session.store?.env["FATHOM_PAGE"], let p = StoryPage.allCases.first(where: { $0.title.lowercased() == name.lowercased() }) {
                page = p
            }
        }
    }

    /// Pages Claude is still writing.
    private var waiting: Set<StoryPage> {
        guard session.storyState.isRunning || session.briefState.isRunning else { return [] }
        let s = session.story
        var out: Set<StoryPage> = []
        if s.problemSteps.isEmpty { out.insert(.problem) }
        if s.parts.isEmpty { out.insert(.idea) }
        if s.solutionSteps.isEmpty { out.insert(.now) }
        if s.choices.isEmpty { out.insert(.choices) }
        if session.brief.contracts.isEmpty && session.briefState.isRunning { out.insert(.promises) }
        if s.look.isEmpty { out.insert(.code) }
        if session.brief.headline.isEmpty { out.insert(.overview) }
        return out
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

/// The pages as a row of words, the current one underlined in its colour. A page still being written breathes.
struct StoryNav: View {
    let pages: [StoryPage]
    let page: StoryPage
    var waiting: Set<StoryPage> = []
    let go: (StoryPage) -> Void
    @Namespace private var space

    var body: some View {
        HStack(spacing: 4) {
            ForEach(pages) { p in
                NavWord(page: p, on: p == page, waiting: waiting.contains(p), space: space) { go(p) }
            }
        }
        .animation(.smooth(duration: 0.32), value: page)
    }
}

private struct NavWord: View {
    let page: StoryPage
    let on: Bool
    let waiting: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(page.title)
                        .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.text1 : hover ? Color.text2 : Color.text3)
                    if waiting {
                        Circle().fill(page.tint.opacity(0.7)).frame(width: 4, height: 4)
                            .help("Still being written")
                    }
                }
                ZStack {
                    Capsule().fill(Color.clear).frame(height: 2)
                    if on {
                        Capsule().fill(page.tint).frame(height: 2)
                            .matchedGeometryEffect(id: "bar", in: space)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Previous page (←)")
            }
            Spacer()
            if i + 1 < pages.count {
                Button { go(pages[i + 1]) } label: {
                    HStack(spacing: 6) {
                        Text("\(pages[i + 1].eyebrow)")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(pages[i + 1].tint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Next page (→)")
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 46)
    }
}

/// The frame every page shares: a small eyebrow, the sentence, then the picture. The page scrolls when the picture
/// is taller than the window.
struct PageFrame<Content: View>: View {
    let page: StoryPage
    let title: String
    var waiting = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", page.rawValue))
                        .font(.mono(11, .semibold))
                        .foregroundStyle(page.tint.opacity(0.65))
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
                        .font(.serif(34))
                        .tracking(-0.6)
                        .lineSpacing(2)
                        .foregroundStyle(Color.text1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 880, alignment: .leading)
                        .textSelection(.enabled)
                }
                content
                    .padding(.top, 30)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(.horizontal, 56)
            .padding(.top, 30)
            .padding(.bottom, 28)
            .frame(maxWidth: 1180, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
    }
}

/// What the colours on a diagram mean, said once, quietly.
struct DiagramKey: View {
    var new = true
    var hurt = false
    var data = false

    var body: some View {
        HStack(spacing: 16) {
            if new { item(Capsule().fill(Color.added).frame(width: 14, height: 2.5), "New in this pull request") }
            if hurt { item(Circle().fill(Color.removed).frame(width: 8, height: 8), "Where it went wrong") }
            if data {
                item(Text("data").font(.mono(9.5, .medium)).foregroundStyle(Color.calm)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06))),
                     "What travels")
            }
        }
    }

    private func item(_ mark: some View, _ word: String) -> some View {
        HStack(spacing: 6) {
            mark
            Text(word).font(.system(size: 11)).foregroundStyle(Color.text3)
        }
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
            .background(alignment: .leading) {
                // The thread the story runs along.
                Rectangle()
                    .fill(LinearGradient(colors: [Color.removed.opacity(0.5), Color.sonar.opacity(0.4), Color.added.opacity(0.4),
                                                  Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1)
                    .padding(.vertical, 26)
                    .padding(.leading, 19.5)
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
                HStack(spacing: 12) {
                    Circle()
                        .fill(page.tint)
                        .frame(width: 8, height: 8)
                        .background(Circle().fill(Color(hex: 0x0A0D12)).frame(width: 16, height: 16))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                    Text(page.title.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(1.3)
                }
                .foregroundStyle(page.tint)
                .frame(width: 120, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 22) {
                if !s.problemSteps.isEmpty {
                    DiagramKey(new: false, hurt: !s.pain.isEmpty, data: s.problemSteps.contains { !$0.data.isEmpty })
                }
                StorySequence(steps: s.problemSteps, actors: actorOrder(s), kinds: kinds(s), painStep: s.painStep, pain: s.pain)
            }
            .frame(maxWidth: 1060, alignment: .leading)
        }
    }
}

struct NowPage: View {
    @Bindable var session: PRSession
    @State private var before = false

    var body: some View {
        let s = session.story
        PageFrame(page: .now, title: s.solutionTitle, waiting: session.storyState.isRunning) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    if !s.problemSteps.isEmpty {
                        BeforeAfter(before: $before)
                    }
                    if !s.solutionSteps.isEmpty {
                        DiagramKey(new: !before, hurt: before && !s.pain.isEmpty, data: true)
                    }
                }
                if before {
                    StorySequence(steps: s.problemSteps, actors: actorOrder(s), kinds: kinds(s), painStep: s.painStep, pain: s.pain)
                        .id("before")
                } else {
                    StorySequence(steps: s.solutionSteps, actors: actorOrder(s), kinds: kinds(s))
                        .id("after")
                }
            }
            .frame(maxWidth: 1060, alignment: .leading)
        }
    }
}

/// After | Before, to flip the picture back to how it was.
struct BeforeAfter: View {
    @Binding var before: Bool
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { b in
                let on = before == b
                Button {
                    withAnimation(.smooth(duration: 0.3)) { before = b }
                } label: {
                    Text(b ? "Before" : "After")
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.text1 : Color.text3)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if on {
                                Capsule().fill(Color.white.opacity(0.1))
                                    .matchedGeometryEffect(id: "flip", in: space)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
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
/// each arrow and what travels below it. New steps are green; the step where it hurts ends in a cross. Point at an
/// actor to follow only its part.
struct StorySequence: View {
    let steps: [Story.Step]
    let actors: [String]
    var kinds: [String: String] = [:]
    var painStep = -2
    var pain = ""

    @State private var shown = 0
    @State private var focus: String?
    private let headerH: CGFloat = 46
    private let rowH: CGFloat = 72

    private var columns: [String] {
        // Only the actors this telling uses, in the shared order.
        let used = Set(steps.flatMap { [$0.from, $0.to] })
        return actors.filter { used.contains($0) }
    }

    private var missing: Bool { painStep == -1 && !pain.isEmpty }
    private var rows: Int { steps.count + (missing ? 1 : 0) }

    private func lit(_ step: Story.Step) -> Bool { focus == nil || step.from == focus || step.to == focus }

    var body: some View {
        GeometryReader { geo in
            let cols = columns
            let colW = geo.size.width / CGFloat(max(cols.count, 1))
            let x: (String) -> CGFloat = { a in (CGFloat(cols.firstIndex(of: a) ?? 0) + 0.5) * colW }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for a in cols {
                        var p = Path()
                        p.move(to: CGPoint(x: x(a), y: headerH - 8))
                        p.addLine(to: CGPoint(x: x(a), y: size.height - 6))
                        let on = focus == a
                        ctx.stroke(p, with: .color(.white.opacity(on ? 0.28 : 0.08)),
                                   style: StrokeStyle(lineWidth: on ? 1.2 : 1, dash: on ? [] : [2, 5]))
                    }
                    for (k, step) in steps.enumerated() where k < shown {
                        let y = rowY(k)
                        let hurt = k == painStep
                        let color: Color = hurt ? .removed : step.isNew ? .added : Color(hex: 0xC4CCD8)
                        var c = ctx
                        c.opacity = lit(step) ? 1 : 0.18
                        arrow(&c, from: x(step.from), to: x(step.to), y: y, color: color, emphasis: hurt || step.isNew)
                        if hurt { cross(&c, at: CGPoint(x: x(step.to) + (step.from == step.to ? 44 : 0), y: y)) }
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
                    ActorChip(name: a, kind: kinds[a], focused: focus == a, dimmed: focus != nil && focus != a)
                        .frame(maxWidth: colW - 8)
                        .position(x: x(a), y: 16)
                        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { focus = QA.hover(h) ? a : (focus == a ? nil : focus) } }
                }

                ForEach(Array(steps.enumerated()), id: \.offset) { k, step in
                    let x0 = x(step.from), x1 = x(step.to)
                    let selfCall = step.from == step.to
                    // Words may run wider than a short arrow: nothing else shares the row.
                    let span = selfCall ? min(max(colW * 1.3, 220), 300) : min(max(abs(x1 - x0) - 12, 300), geo.size.width - 8)
                    let mid = selfCall ? x0 + 56 + span / 2 : (x0 + x1) / 2
                    let hurt = k == painStep
                    VStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("\(k + 1)")
                                .font(.mono(9.5, .bold))
                                .foregroundStyle(Color.ink)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(hurt ? Color.removed : step.isNew ? Color.added : Color.text3))
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                            Text(step.does)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(hurt ? Color.removed : Color.text1)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Color.clear.frame(height: 5)
                        if !step.data.isEmpty {
                            Text(step.data)
                                .font(.mono(11, .medium))
                                .foregroundStyle(step.isNew ? Color.added : Color.calm)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: 0x0D1218)))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder((step.isNew ? Color.added : Color.calm).opacity(0.18), lineWidth: 0.5))
                        }
                    }
                    .frame(width: span)
                    .position(x: min(max(mid, span / 2 + 4), geo.size.width - span / 2 - 4), y: rowY(k) - 4)
                    .opacity(k < shown ? (lit(step) ? 1 : 0.2) : 0)
                    .offset(y: k < shown ? 0 : 6)

                    if hurt && !pain.isEmpty {
                        PainNote(text: pain)
                            .position(x: min(max(selfCall ? x1 + 64 + span / 2 : (x0 + x1) / 2, 150), geo.size.width - 150), y: rowY(k) + 46)
                            .opacity(k < shown ? (lit(step) ? 1 : 0.2) : 0)
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
                try? await Task.sleep(for: .milliseconds(shown == 0 ? 220 : 340))
                if Task.isCancelled { return }
                shown += 1
            }
        }
    }

    /// The step that hurts gets room under it for its note.
    private func rowY(_ k: Int) -> CGFloat {
        headerH + 46 + CGFloat(k) * rowH + (painStep >= 0 && k > painStep && !pain.isEmpty ? 46 : 0)
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
            p.addLine(to: CGPoint(x: x1 - dir * 6, y: y))
            tip = CGPoint(x: x1 - dir * 1, y: y)
        }
        if emphasis {
            ctx.stroke(p, with: .color(color.opacity(0.16)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        }
        ctx.stroke(p, with: .color(color.opacity(emphasis ? 0.95 : 0.5)), style: StrokeStyle(lineWidth: emphasis ? 1.8 : 1.2, lineCap: .round))
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - dir * 8, y: tip.y - 4))
        head.addQuadCurve(to: CGPoint(x: tip.x - dir * 8, y: tip.y + 4), control: CGPoint(x: tip.x - dir * 5.5, y: tip.y))
        head.closeSubpath()
        ctx.fill(head, with: .color(color.opacity(emphasis ? 0.95 : 0.6)))
        ctx.fill(Path(ellipseIn: CGRect(x: x0 - 2.5, y: y - 2.5, width: 5, height: 5)), with: .color(color.opacity(0.8)))
    }

    private func cross(_ ctx: inout GraphicsContext, at c: CGPoint) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26)), with: .color(Color.removed.opacity(0.18)))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9.5, y: c.y - 9.5, width: 19, height: 19)), with: .color(Color.removed))
        var x = Path()
        x.move(to: CGPoint(x: c.x - 3.8, y: c.y - 3.8)); x.addLine(to: CGPoint(x: c.x + 3.8, y: c.y + 3.8))
        x.move(to: CGPoint(x: c.x + 3.8, y: c.y - 3.8)); x.addLine(to: CGPoint(x: c.x - 3.8, y: c.y + 3.8))
        ctx.stroke(x, with: .color(Color.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}

struct ActorChip: View {
    let name: String
    let kind: String?
    var focused = false
    var dimmed = false

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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: focused ? 0x182230 : 0x111720)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(focused ? 0.3 : 0.1), lineWidth: focused ? 1 : 0.75))
        .opacity(dimmed ? 0.45 : 1)
        .help("Point here to follow \(name) alone")
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
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: 0x1C1014)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.removed.opacity(0.35), lineWidth: 0.75))
            .frame(maxWidth: 300)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Idea

struct IdeaPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let s = session.story
        PageFrame(page: .idea, title: s.ideaTitle, waiting: session.storyState.isRunning) {
            VStack(alignment: .leading, spacing: 22) {
                if !s.parts.isEmpty {
                    DiagramKey(new: s.parts.contains(where: \.isNew) || s.links.contains(where: \.isNew))
                }
                IdeaGraph(parts: s.parts, links: s.links)
            }
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }
}

/// The few parts that carry the idea, left to right in the order things happen, new ones in green. Each link
/// leaves and lands at its own spot on a card's edge, so a busy part fans out instead of knotting. Point at a part
/// to see only what it touches.
struct IdeaGraph: View {
    let parts: [Story.Part]
    let links: [Story.Link]
    @State private var drawn = false
    @State private var focus: String?

    private let nodeW: CGFloat = 228
    private let nodeH: CGFloat = 66

    private func lit(_ l: Story.Link) -> Bool { focus == nil || l.from == focus || l.to == focus }
    private func lit(_ p: Story.Part) -> Bool {
        focus == nil || focus == p.id || links.contains { ($0.from == focus && $0.to == p.id) || ($0.to == focus && $0.from == p.id) }
    }

    var body: some View {
        GeometryReader { geo in
            let place = layout(geo.size)
            let port = ports(place)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for (i, l) in links.enumerated() {
                        guard let a = place[l.from], let b = place[l.to] else { continue }
                        let (path, tip, dir) = curve(a, b, port[i * 2] ?? 0, port[i * 2 + 1] ?? 0)
                        let color: Color = l.isNew ? .added : Color(hex: 0xC4CCD8)
                        var c = ctx
                        c.opacity = lit(l) ? 1 : 0.12
                        if l.isNew { c.stroke(path, with: .color(color.opacity(0.14)), style: StrokeStyle(lineWidth: 6, lineCap: .round)) }
                        c.stroke(path, with: .color(color.opacity(l.isNew ? 0.85 : 0.38)),
                                 style: StrokeStyle(lineWidth: l.isNew ? 1.7 : 1.2, lineCap: .round))
                        var head = Path()
                        head.move(to: tip)
                        head.addLine(to: CGPoint(x: tip.x - dir.dx * 8 - dir.dy * 4, y: tip.y - dir.dy * 8 + dir.dx * 4))
                        head.addQuadCurve(to: CGPoint(x: tip.x - dir.dx * 8 + dir.dy * 4, y: tip.y - dir.dy * 8 - dir.dx * 4),
                                          control: CGPoint(x: tip.x - dir.dx * 5.5, y: tip.y - dir.dy * 5.5))
                        head.closeSubpath()
                        c.fill(head, with: .color(color.opacity(l.isNew ? 0.9 : 0.5)))
                    }
                }
                .opacity(drawn ? 1 : 0)

                let spots = labelSpots(place, port)
                ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                    if let spot = spots[i] {
                        Text(l.label)
                            .font(.mono(10.5, .medium))
                            .foregroundStyle(l.isNew ? Color.added : Color.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: 0x0D1218)))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder((l.isNew ? Color.added : Color.white).opacity(l.isNew ? 0.2 : 0.08), lineWidth: 0.5))
                            .fixedSize()
                            .position(spot)
                            .opacity(drawn ? (lit(l) ? 1 : 0.12) : 0)
                    }
                }

                ForEach(parts) { p in
                    if let c = place[p.id] {
                        PartCard(part: p, focused: focus == p.id)
                            .frame(width: nodeW, height: nodeH)
                            .position(c)
                            .scaleEffect(drawn ? 1 : 0.94)
                            .opacity(drawn ? (lit(p) ? 1 : 0.3) : 0)
                            .onHover { h in
                                withAnimation(.easeOut(duration: 0.18)) { focus = QA.hover(h) ? p.id : (focus == p.id ? nil : focus) }
                            }
                    }
                }
            }
        }
        .frame(maxWidth: 1080)
        .frame(height: min(max(CGFloat(tallest) * (nodeH + 30) + 40, 260), 620))
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
        let colW = min(size.width / CGFloat(columns), nodeW + 200)
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

    /// Where each link leaves and lands on a card's edge, as an offset from the edge's middle: `2i` for where link
    /// `i` leaves, `2i + 1` for where it lands. Links on the same edge spread out in the order of the parts they
    /// reach, so they don't cross on their way.
    private func ports(_ place: [String: CGPoint]) -> [Int: CGFloat] {
        var edges: [String: [(slot: Int, toward: CGFloat)]] = [:]
        for (i, l) in links.enumerated() {
            guard let a = place[l.from], let b = place[l.to], abs(a.x - b.x) >= 4 else { continue }
            let right = b.x > a.x
            edges["\(l.from)>\(right ? "R" : "L")", default: []].append((i * 2, b.y))
            edges["\(l.to)>\(right ? "L" : "R")", default: []].append((i * 2 + 1, a.y))
        }
        var out: [Int: CGFloat] = [:]
        for (_, members) in edges {
            let sorted = members.enumerated().sorted { ($0.element.toward, $0.offset) < ($1.element.toward, $1.offset) }.map(\.element)
            let n = sorted.count
            let spread = min(nodeH - 22, CGFloat(n - 1) * 11)
            for (j, m) in sorted.enumerated() {
                out[m.slot] = n == 1 ? 0 : -spread / 2 + spread * CGFloat(j) / CGFloat(n - 1)
            }
        }
        return out
    }

    private func ends(_ a: CGPoint, _ b: CGPoint, _ da: CGFloat, _ db: CGFloat) -> (CGPoint, CGPoint) {
        let right = b.x > a.x
        return (CGPoint(x: a.x + (right ? nodeW / 2 : -nodeW / 2), y: a.y + da),
                CGPoint(x: b.x + (right ? -nodeW / 2 - 2 : nodeW / 2 + 2), y: b.y + db))
    }

    private func curve(_ a: CGPoint, _ b: CGPoint, _ da: CGFloat, _ db: CGFloat) -> (Path, CGPoint, CGVector) {
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
        let (s, e) = ends(a, b, da, db)
        let dx = (e.x - s.x) * 0.5
        p.move(to: s)
        p.addCurve(to: CGPoint(x: e.x - (right ? 5 : -5), y: e.y), control1: CGPoint(x: s.x + dx, y: s.y), control2: CGPoint(x: e.x - dx, y: e.y))
        return (p, e, CGVector(dx: right ? 1 : -1, dy: 0))
    }

    /// Where each link's label sits: on its curve, at the first spot clear of the parts and of other labels,
    /// trying near where it lands first (a fan of links spreads out there). A label with no room is left off.
    private func labelSpots(_ place: [String: CGPoint], _ port: [Int: CGFloat]) -> [Int: CGPoint] {
        var taken = place.values.map { CGRect(x: $0.x - nodeW / 2 - 4, y: $0.y - nodeH / 2 - 4, width: nodeW + 8, height: nodeH + 8) }
        var out: [Int: CGPoint] = [:]
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        for (i, l) in links.enumerated() {
            guard let a = place[l.from], let b = place[l.to], !l.label.isEmpty else { continue }
            let w = (l.label as NSString).size(withAttributes: [.font: font]).width + 16, h: CGFloat = 20
            for t in [0.62, 0.5, 0.76, 0.38, 0.86, 0.26] as [CGFloat] {
                let p = labelPoint(a, b, port[i * 2] ?? 0, port[i * 2 + 1] ?? 0, t: t)
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

    private func labelPoint(_ a: CGPoint, _ b: CGPoint, _ da: CGFloat, _ db: CGFloat, t: CGFloat) -> CGPoint {
        if abs(a.x - b.x) < 4 { return CGPoint(x: a.x + 70, y: a.y + (b.y - a.y) * t) }
        let (s, e) = ends(a, b, da, db)
        let u = 1 - t
        let dx = (e.x - s.x) * 0.5
        let c1 = CGPoint(x: s.x + dx, y: s.y), c2 = CGPoint(x: e.x - dx, y: e.y)
        let x = u * u * u * s.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * e.x
        let y = u * u * u * s.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * e.y
        return CGPoint(x: x, y: y - 12)
    }
}

struct PartCard: View {
    let part: Story.Part
    var focused = false

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
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
            }
            .help(part.isNew ? "\(part.name) — new in this pull request" : part.name)
            Text(part.role)
                .font(.system(size: 12))
                .foregroundStyle(Color.text3)
                .lineLimit(2)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: part.isNew ? 0x0F1A16 : 0x10161F)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(part.isNew ? Color.added.opacity(focused ? 0.9 : 0.55) : Color.white.opacity(focused ? 0.3 : 0.12),
                          lineWidth: focused ? 1.3 : part.isNew ? 1 : 0.8))
        .shadow(color: part.isNew ? Color.added.opacity(0.12) : .clear, radius: 12)
    }
}

// MARK: - Choices

struct ChoicesPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let choices = session.story.choices
        PageFrame(page: .choices, title: choices.isEmpty ? "" : "\(choices.count == 1 ? "One choice" : "\(Self.word(choices.count)) choices") shape this change",
                  waiting: session.storyState.isRunning) {
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
        }
    }

    static func word(_ n: Int) -> String {
        ["Zero", "One", "Two", "Three", "Four", "Five", "Six"][min(n, 6)]
    }
}

/// One decision, drawn as the fork it was: the road taken in green, the one passed over dashed and dim, and why.
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
                Label(choice.stated ? "Said in the PR" : "Inferred", systemImage: choice.stated ? "quote.bubble" : "sparkle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(choice.stated ? Color.calm : Color.text3)
                    .fixedSize()
                    .help(choice.stated ? "The PR description or a code comment says why" : "Fathom's reading of why; the PR doesn't say")
            }

            VStack(alignment: .leading, spacing: 11) {
                Text(choice.chose)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.text1)
                    .fixedSize(horizontal: false, vertical: true)
                    .anchorPreference(key: ForkRows.self, value: .bounds) { [0: $0] }
                if !choice.over.isEmpty {
                    (Text("not ").foregroundStyle(Color.text3.opacity(0.8)) + Text(Self.lower(choice.over)).foregroundStyle(Color.text3))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .anchorPreference(key: ForkRows.self, value: .bounds) { [1: $0] }
                }
            }
            .padding(.leading, 34)
            .overlayPreferenceValue(ForkRows.self) { rows in
                GeometryReader { g in
                    if let a = rows[0] {
                        Fork(chosen: g[a].minY + 9.5, over: rows[1].map { g[$0].minY + 9 })
                    }
                }
            }

            if !choice.why.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.changed.opacity(0.8))
                        .frame(width: 20)
                    Text(choice.why)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !choice.hunks.isEmpty {
                Spacer(minLength: 0)
                Button {
                    if let h = choice.hunks.first { session.go(toHunk: h) }
                } label: {
                    Label("See it in the code", systemImage: "arrow.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.changed.opacity(hover ? 1 : 0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(hover ? 0.045 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(hover ? 0.1 : 0.065), lineWidth: 0.75))
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
}

private struct ForkRows: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The fork itself, in the 30 points left of the two lines: a point of decision, a solid branch to what was chosen
/// and a dashed one, ending in a cross, to what wasn't.
private struct Fork: View {
    let chosen: CGFloat
    let over: CGFloat?

    var body: some View {
        Canvas { ctx, _ in
            let root = CGPoint(x: 5, y: chosen)
            var taken = Path()
            taken.move(to: root)
            taken.addLine(to: CGPoint(x: 24, y: chosen))
            ctx.stroke(taken, with: .color(Color.added.opacity(0.9)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            var head = Path()
            head.move(to: CGPoint(x: 27, y: chosen))
            head.addLine(to: CGPoint(x: 21, y: chosen - 3.5))
            head.addQuadCurve(to: CGPoint(x: 21, y: chosen + 3.5), control: CGPoint(x: 23, y: chosen))
            head.closeSubpath()
            ctx.fill(head, with: .color(Color.added))
            if let over {
                var not = Path()
                not.move(to: CGPoint(x: root.x, y: root.y + 3))
                not.addCurve(to: CGPoint(x: 19, y: over), control1: CGPoint(x: root.x, y: over - 4), control2: CGPoint(x: root.x + 4, y: over))
                ctx.stroke(not, with: .color(Color.text3.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2.5, 3]))
                var x = Path()
                x.move(to: CGPoint(x: 21.5, y: over - 3)); x.addLine(to: CGPoint(x: 27.5, y: over + 3))
                x.move(to: CGPoint(x: 27.5, y: over - 3)); x.addLine(to: CGPoint(x: 21.5, y: over + 3))
                ctx.stroke(x, with: .color(Color.text3), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: root.x - 4, y: root.y - 4, width: 8, height: 8)), with: .color(Color.changed))
        }
        .allowsHitTesting(false)
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
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(contracts) { c in
                    InterfaceCard(session: session, contract: c, fill: true)
                }
            }
            .frame(maxWidth: 1080)
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
                        Spacer()
                        Button {
                            session.go(toHunk: l.hunk)
                        } label: {
                            Label("In Changes", systemImage: "arrow.right")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.text3)
                        }
                        .buttonStyle(.plain)
                        .help("Read it in place, with what's around it")
                    }
                    .padding(.top, i == 0 ? 0 : 30)
                    .padding(.bottom, 10)
                    ForEach(session.lookRows(l.hunk)) { row in
                        DocRowView(session: session, row: row)
                    }
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .environment(\.inPanel, true)
        }
    }
}
