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
        case .code: .merged
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
            .environment(\.runningHead, "A Reading of \(session.ref.repo) #\(session.ref.number)")
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

private struct RunningHeadKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    /// "A Reading of walkai #46": the left half of every page's running head.
    var runningHead: String {
        get { self[RunningHeadKey.self] }
        set { self[RunningHeadKey.self] = newValue }
    }
}

/// The pages as a row of words, the current one underlined. A page still being written shows a dot.
struct StoryNav: View {
    let pages: [StoryPage]
    let page: StoryPage
    var waiting: Set<StoryPage> = []
    let go: (StoryPage) -> Void
    @Namespace private var space

    var body: some View {
        HStack(spacing: 6) {
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
            VStack(spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if page != .overview {
                        Text("\(page.rawValue)")
                            .font(.serif(13))
                            .foregroundStyle(Color.text3)
                    }
                    Text(page.title)
                        .font(.serif(15))
                        .foregroundStyle(on ? Color.text1 : hover ? Color.text2 : Color.text3)
                    if waiting {
                        Circle().fill(Color.text3).frame(width: 3, height: 3)
                            .help("Still being written")
                    }
                }
                ZStack {
                    Rectangle().fill(Color.clear).frame(height: 1)
                    if on {
                        Rectangle().fill(Color.text1.opacity(0.8)).frame(height: 1)
                            .matchedGeometryEffect(id: "bar", in: space)
                    }
                }
            }
            .padding(.horizontal, 9)
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
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left").font(.system(size: 10, weight: .medium))
                        Text(pages[i - 1].title).font(.serif(14.5))
                    }
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
                        Text("\(pages[i + 1].rawValue)").font(.serif(13)).foregroundStyle(Color.text3)
                        Text(pages[i + 1].eyebrow).font(.serif(14.5))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.text2)
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

/// The frame every page shares, set like a page of a book: a running head, the section's number hanging in the
/// margin beside its one sentence, then the figure. The page scrolls when the figure is taller than the window.
struct PageFrame<Content: View>: View {
    let page: StoryPage
    let title: String
    var waiting = false
    @ViewBuilder var content: Content
    @Environment(\.runningHead) private var head

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RunningHead(left: head, right: "§\(page.rawValue)  \(page.eyebrow)")
                    .padding(.bottom, 34)
                if title.isEmpty && waiting {
                    Skeleton(lines: [0.62], height: 28).frame(maxWidth: 760)
                } else {
                    Text(title)
                        .font(.serif(33))
                        .lineSpacing(4)
                        .foregroundStyle(Color.text1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 860, alignment: .leading)
                        .textSelection(.enabled)
                        .overlay(alignment: .topLeading) {
                            // The section number hangs in the margin, as in a book.
                            Text("\(page.rawValue)")
                                .font(.serif(33))
                                .foregroundStyle(Color.text3.opacity(0.8))
                                .alignmentGuide(.leading) { $0.width + 20 }
                        }
                }
                content
                    .padding(.top, 32)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(.horizontal, 64)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .frame(maxWidth: 1180, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
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

/// The story's title page, as a paper's: the title, a byline, a structured abstract (Problem. Idea. Now.), and the
/// contents with dot leaders, each line a way in. Most of the time the abstract is enough to know what you're
/// looking at.
struct OverviewPage: View {
    @Bindable var session: PRSession
    let go: (StoryPage) -> Void
    @Environment(\.runningHead) private var head

    var body: some View {
        let s = session.story, b = session.brief
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RunningHead(left: head, right: "Overview")
                    .padding(.bottom, 34)

                if b.headline.isEmpty {
                    Skeleton(lines: [0.55], height: 32).frame(maxWidth: 820)
                } else {
                    Text(b.headline)
                        .font(.serif(40))
                        .lineSpacing(5)
                        .foregroundStyle(Color.text1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 880, alignment: .leading)
                        .textSelection(.enabled)
                }
                byline
                    .padding(.top, 16)

                Text("Abstract")
                    .font(.smallCaps(13.5))
                    .tracking(1.4)
                    .foregroundStyle(Color.text2)
                    .padding(.top, 44)
                    .padding(.bottom, 10)
                if s.problemTitle.isEmpty && session.storyState.isRunning {
                    Skeleton(lines: [0.95, 0.9, 0.6], height: 14, spacing: 12).frame(maxWidth: 740)
                } else {
                    abstract(s)
                        .font(.serif(18.5))
                        .lineSpacing(6)
                        .foregroundStyle(Color.text1.opacity(0.93))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 740, alignment: .leading)
                        .textSelection(.enabled)
                }

                Text("Contents")
                    .font(.smallCaps(13.5))
                    .tracking(1.4)
                    .foregroundStyle(Color.text2)
                    .padding(.top, 46)
                    .padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 0) {
                    TocRow(page: .problem, note: "") { go(.problem) }
                    TocRow(page: .idea, note: s.parts.isEmpty ? "" : "\(ChoicesPage.word(s.parts.count).lowercased()) parts") { go(.idea) }
                    TocRow(page: .now, note: s.solutionSteps.isEmpty ? "" : "\(ChoicesPage.word(s.solutionSteps.count).lowercased()) steps") { go(.now) }
                    if !s.choices.isEmpty {
                        TocRow(page: .choices, note: "", sub: s.choices.enumerated().map { ("4.\($0.offset + 1)", $0.element.title) }) { go(.choices) }
                    }
                    if !b.contracts.isEmpty {
                        TocRow(page: .promises, note: b.contracts.map(\.name).joined(separator: ", "), noteIsCode: true) { go(.promises) }
                    }
                    if !s.look.isEmpty {
                        TocRow(page: .code, note: "", sub: s.look.enumerated().map { ("6.\($0.offset + 1)", $0.element.why) }) { go(.code) }
                    }
                }
                .frame(maxWidth: 740, alignment: .leading)
            }
            .padding(.horizontal, 64)
            .padding(.top, 26)
            .padding(.bottom, 36)
            .frame(maxWidth: 1180, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Who, what kind of change, and how big, as a paper's author line.
    private var byline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let d = session.detail {
                Avatar(url: d.authorAvatar, name: d.author, size: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(d.author).font(.smallCaps(15)).tracking(0.6).foregroundStyle(Color.text2)
            }
            let kind = session.brief.kind.isEmpty ? "" : Glyph.kindWord(session.brief.kind).lowercased()
            if let d = session.diff {
                Text("\(kind.isEmpty ? "a change" : "a \(kind)") across \(d.files.count) files")
                    .font(.serifItalic(15.5))
                    .foregroundStyle(Color.text3)
                DiffStat(additions: d.additions, deletions: d.deletions, bar: false, size: 11)
            }
            if session.isSounding {
                ReadingClock(session: session)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.text3)
            }
        }
    }

    /// Problem. … Idea. … Now. …, the heads run in as small capitals.
    private func abstract(_ s: Story) -> Text {
        var t = Text("")
        for (head, sentence) in [("Problem.", s.problemTitle), ("Idea.", s.ideaTitle), ("Now.", s.solutionTitle)] where !sentence.isEmpty {
            t = t + Text(head + " ").font(.runIn(18.5)) + Text(Self.sentence(sentence) + "  ")
        }
        return t
    }

    /// "only new routes stop navigation" → "Only new routes stop navigation."
    static func sentence(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces)
        if let first = out.first, first.isLowercase { out = first.uppercased() + out.dropFirst() }
        if let last = out.last, !".!?".contains(last) { out += "." }
        return out
    }
}

/// A line of the contents: number, title, a dotted leader, and the section mark; sub-entries under it.
struct TocRow: View {
    let page: StoryPage
    let note: String
    var noteIsCode = false
    var sub: [(String, String)] = []
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text("\(page.rawValue)")
                        .font(.serif(17))
                        .foregroundStyle(Color.text3)
                        .frame(width: 22, alignment: .leading)
                    Text(page.eyebrow)
                        .font(.serif(17.5))
                        .foregroundStyle(hover ? Color.text1 : Color.text1.opacity(0.9))
                        .fixedSize()
                    if !note.isEmpty {
                        Text(note)
                            .font(noteIsCode ? .mono(11.5) : .serifItalic(15))
                            .foregroundStyle(Color.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                    DotLeader()
                        .frame(minWidth: 24)
                    Text("§\(page.rawValue)")
                        .font(.serif(15))
                        .foregroundStyle(Color.text3)
                        .fixedSize()
                }
                ForEach(Array(sub.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.0)
                            .font(.serif(14.5))
                            .foregroundStyle(Color.text3)
                            .frame(width: 30, alignment: .leading)
                        Text(item.1)
                            .font(.serif(15.5))
                            .foregroundStyle(Color.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, 32)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
    }
}

/// The dotted line between a contents entry and its section mark.
struct DotLeader: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 2
            while x < size.width - 1 {
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: size.height - 2.2, width: 1.4, height: 1.4)), with: .color(Color.text3.opacity(0.7)))
                x += 6
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Problem and Now

struct ProblemPage: View {
    @Bindable var session: PRSession

    var body: some View {
        let s = session.story
        PageFrame(page: .problem, title: s.problemTitle, waiting: session.storyState.isRunning) {
            Figure(number: 1, caption: s.problemSteps.isEmpty ? "" : "How it went before, one step at a time."
                   + (s.pain.isEmpty ? "" : " Red marks where it went wrong.") + " Under each arrow, what travels.") {
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
            VStack(alignment: .leading, spacing: 18) {
                if !s.problemSteps.isEmpty {
                    BeforeAfter(before: $before)
                }
                Figure(number: before ? 1 : 3, caption: s.solutionSteps.isEmpty ? "" : before
                       ? "How it went before, for comparison." + (s.pain.isEmpty ? "" : " Red marks where it went wrong.")
                       : "How it works now. Green marks steps new in this pull request; under each arrow, what travels.") {
                    if before {
                        StorySequence(steps: s.problemSteps, actors: actorOrder(s), kinds: kinds(s), painStep: s.painStep, pain: s.pain)
                            .id("before")
                    } else {
                        StorySequence(steps: s.solutionSteps, actors: actorOrder(s), kinds: kinds(s))
                            .id("after")
                    }
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
                                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.wash(0.09))
                                    .matchedGeometryEffect(id: "flip", in: space)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.wash(0.1), lineWidth: 0.5))
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

/// A sequence diagram drawn the way a textbook draws one, one step at a time: each actor named over a dotted
/// lifeline with what kind of thing it is in italics beneath, time running down a labelled axis (t₁, t₂, …), what
/// each step does in italics over its hairline arrow and what travels under it in angle brackets. New steps are
/// green; the step where it hurts ends in a cross with a note. Point at an actor to follow only its part.
struct StorySequence: View {
    let steps: [Story.Step]
    let actors: [String]
    var kinds: [String: String] = [:]
    var painStep = -2
    var pain = ""

    @State private var shown = 0
    @State private var focus: String?
    private let headerH: CGFloat = 54
    private let rowH: CGFloat = 76
    private let gutter: CGFloat = 46   // the time axis

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
            let colW = (geo.size.width - gutter) / CGFloat(max(cols.count, 1))
            let x: (String) -> CGFloat = { a in gutter + (CGFloat(cols.firstIndex(of: a) ?? 0) + 0.5) * colW }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Time runs down the left: an axis with a tick and a label for every step.
                    let axisX: CGFloat = 12, top = headerH + 10, bottom = size.height - 8
                    var axis = Path()
                    axis.move(to: CGPoint(x: axisX, y: top))
                    axis.addLine(to: CGPoint(x: axisX, y: bottom - 6))
                    ctx.stroke(axis, with: .color(.wash(0.22)), lineWidth: 0.75)
                    var tip = Path()
                    tip.move(to: CGPoint(x: axisX, y: bottom))
                    tip.addLine(to: CGPoint(x: axisX - 3, y: bottom - 7))
                    tip.addLine(to: CGPoint(x: axisX + 3, y: bottom - 7))
                    tip.closeSubpath()
                    ctx.fill(tip, with: .color(.wash(0.3)))
                    ctx.draw(Text("t").font(.serifItalic(14)).foregroundStyle(Color.text3), at: CGPoint(x: axisX + 9, y: bottom - 4), anchor: .leading)
                    for k in 0..<steps.count where k < shown {
                        let y = rowY(k)
                        var tick = Path()
                        tick.move(to: CGPoint(x: axisX - 3, y: y))
                        tick.addLine(to: CGPoint(x: axisX + 3, y: y))
                        ctx.stroke(tick, with: .color(.wash(0.35)), lineWidth: 0.75)
                        let hurt = k == painStep
                        ctx.draw(Text("t" + Self.subscriptDigits(k + 1)).font(.serifItalic(14))
                                    .foregroundStyle(hurt ? Color.removed : steps[k].isNew ? Color.added : Color.text3),
                                 at: CGPoint(x: axisX + 9, y: y), anchor: .leading)
                    }

                    // Lifelines, dotted, the followed one drawn in.
                    for a in cols {
                        var p = Path()
                        p.move(to: CGPoint(x: x(a), y: headerH))
                        p.addLine(to: CGPoint(x: x(a), y: size.height - 6))
                        let on = focus == a
                        ctx.stroke(p, with: .color(.wash(on ? 0.4 : 0.16)),
                                   style: StrokeStyle(lineWidth: on ? 0.9 : 0.75, lineCap: .round, dash: on ? [] : [0.5, 4.5]))
                    }
                    for (k, step) in steps.enumerated() where k < shown {
                        let y = rowY(k)
                        let hurt = k == painStep
                        let color: Color = hurt ? .removed : step.isNew ? .added : .stroke
                        var c = ctx
                        c.opacity = lit(step) ? 1 : 0.16
                        arrow(&c, from: x(step.from), to: x(step.to), y: y, color: color, strong: hurt || step.isNew)
                        if hurt { cross(&c, at: CGPoint(x: x(step.to) + (step.from == step.to ? 44 : 0), y: y)) }
                    }
                    if missing && shown >= steps.count, let last = steps.last {
                        // The step that never happened.
                        let y = rowY(steps.count)
                        let from = x(last.to), to = from + min(colW * 0.9, 170)
                        var p = Path()
                        p.move(to: CGPoint(x: from, y: y))
                        p.addLine(to: CGPoint(x: to, y: y))
                        ctx.stroke(p, with: .color(Color.removed.opacity(0.75)), style: StrokeStyle(lineWidth: 0.9, dash: [4, 4]))
                        cross(&ctx, at: CGPoint(x: to, y: y))
                    }
                }

                ForEach(Array(cols.enumerated()), id: \.element) { _, a in
                    // Hover goes on the head itself: after .position it would cover the whole diagram.
                    ActorHead(name: a, kind: kinds[a], focused: focus == a, dimmed: focus != nil && focus != a)
                        .frame(maxWidth: colW - 8)
                        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { focus = QA.hover(h) ? a : (focus == a ? nil : focus) } }
                        .position(x: x(a), y: 22)
                }

                ForEach(Array(steps.enumerated()), id: \.offset) { k, step in
                    let x0 = x(step.from), x1 = x(step.to)
                    let selfCall = step.from == step.to
                    // Words may run wider than a short arrow: nothing else shares the row.
                    let span = selfCall ? min(max(colW * 1.3, 220), 300) : min(max(abs(x1 - x0) - 12, 320), geo.size.width - gutter - 8)
                    let mid = selfCall ? x0 + 56 + span / 2 : (x0 + x1) / 2
                    let hurt = k == painStep
                    VStack(spacing: 7) {
                        (Text(step.does).font(.serifItalic(16)).foregroundStyle(hurt ? Color.removed : Color.text1)
                         + (step.isNew ? Text("  new").font(.smallCaps(12.5)).foregroundStyle(Color.added) : Text("")))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Color.clear.frame(height: 3)
                        if !step.data.isEmpty {
                            (Text("⟨").font(.serif(14)) + Text(step.data).font(.mono(11)) + Text("⟩").font(.serif(14)))
                                .foregroundStyle(step.isNew ? Color.added : Color.calm)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 4)
                                .background(Rectangle().fill(Color.paper))
                        }
                    }
                    .frame(width: span)
                    .position(x: min(max(mid, gutter + span / 2), geo.size.width - span / 2 - 4), y: rowY(k) - 5)
                    .opacity(k < shown ? (lit(step) ? 1 : 0.18) : 0)
                    .offset(y: k < shown ? 0 : 6)

                    if hurt && !pain.isEmpty {
                        PainNote(text: pain)
                            .position(x: min(max(selfCall ? x1 + 64 + span / 2 : (x0 + x1) / 2, gutter + 150), geo.size.width - 150),
                                      y: rowY(k) + 46)
                            .opacity(k < shown ? (lit(step) ? 1 : 0.18) : 0)
                    }
                }
                if missing, let last = steps.last {
                    PainNote(text: pain)
                        .position(x: min(x(last.to) + min(colW * 0.9, 170) / 2, geo.size.width - 150), y: rowY(steps.count) - 26)
                        .opacity(shown >= steps.count ? 1 : 0)
                }
            }
        }
        .frame(height: headerH + 34 + CGFloat(rows) * rowH + (painStep >= 0 && !pain.isEmpty ? 46 : 0))
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
        headerH + 50 + CGFloat(k) * rowH + (painStep >= 0 && k > painStep && !pain.isEmpty ? 46 : 0)
    }

    static func subscriptDigits(_ n: Int) -> String {
        String(String(n).map { c in c.wholeNumberValue.map { Character(UnicodeScalar(0x2080 + $0)!) } ?? c })
    }

    private func arrow(_ ctx: inout GraphicsContext, from x0: CGFloat, to x1: CGFloat, y: CGFloat, color: Color, strong: Bool) {
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
            p.addLine(to: CGPoint(x: x1 - dir * 7, y: y))
            tip = CGPoint(x: x1 - dir * 1, y: y)
        }
        ctx.stroke(p, with: .color(color.opacity(strong ? 0.95 : 0.6)), style: StrokeStyle(lineWidth: strong ? 1.25 : 0.9, lineCap: .round))
        // A narrow, sharp head, as in an engineering drawing.
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - dir * 9, y: tip.y - 3.2))
        head.addLine(to: CGPoint(x: tip.x - dir * 7, y: tip.y))
        head.addLine(to: CGPoint(x: tip.x - dir * 9, y: tip.y + 3.2))
        head.closeSubpath()
        ctx.fill(head, with: .color(color.opacity(strong ? 0.95 : 0.7)))
        ctx.fill(Path(ellipseIn: CGRect(x: x0 - 2, y: y - 2, width: 4, height: 4)), with: .color(color.opacity(0.85)))
    }

    private func cross(_ ctx: inout GraphicsContext, at c: CGPoint) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(Color.paper))
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(Color.removed), lineWidth: 1)
        var x = Path()
        x.move(to: CGPoint(x: c.x - 3.5, y: c.y - 3.5)); x.addLine(to: CGPoint(x: c.x + 3.5, y: c.y + 3.5))
        x.move(to: CGPoint(x: c.x + 3.5, y: c.y - 3.5)); x.addLine(to: CGPoint(x: c.x - 3.5, y: c.y + 3.5))
        ctx.stroke(x, with: .color(Color.removed), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }
}

/// An actor at the head of its lifeline: its name as written in the code, what kind of thing it is in italics,
/// and a short rule the lifeline hangs from.
struct ActorHead: View {
    let name: String
    let kind: String?
    var focused = false
    var dimmed = false

    var body: some View {
        let person = name.lowercased() == "you" || name.lowercased() == "user"
        VStack(spacing: 3) {
            Text(name)
                .font(person ? .serif(16) : .mono(12, .medium))
                .foregroundStyle(Color.text1)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(person ? "the user" : Self.word(kind))
                .font(.serifItalic(13))
                .foregroundStyle(Color.text3)
                .lineLimit(1)
            Rectangle().fill(Color.wash(focused ? 0.6 : 0.3)).frame(width: 28, height: 0.75).padding(.top, 3)
        }
        .padding(.horizontal, 8)
        .background(Rectangle().fill(Color.paper))
        .opacity(dimmed ? 0.4 : 1)
        .contentShape(Rectangle())
        .help("Point here to follow \(name) alone")
    }

    static func word(_ kind: String?) -> String {
        switch kind {
        case "ui": "view"
        case "service": "service"
        case "api": "endpoint"
        case "state": "state"
        case "store": "store"
        case "external": "external service"
        case "job": "job"
        case "config": "configuration"
        case "library": "library"
        case "test": "test"
        default: "component"
        }
    }
}

/// What went wrong, as a note in the figure: italic, red, hung from a short rule.
struct PainNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(Color.removed.opacity(0.7)).frame(width: 1)
            Text(text)
                .font(.serifItalic(15))
                .foregroundStyle(Color.removed)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 6)
        .background(Rectangle().fill(Color.paper))
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
            Figure(number: 2, caption: s.parts.isEmpty ? "" : "The parts that carry the idea, in the order things happen."
                   + (s.parts.contains(where: \.isNew) || s.links.contains(where: \.isNew) ? " Green marks what's new in this pull request." : "")
                   + " Point at a part to see only what it touches.") {
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

    private let nodeW: CGFloat = 232
    private let nodeH: CGFloat = 70

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
                        let color: Color = l.isNew ? .added : .stroke
                        var c = ctx
                        c.opacity = lit(l) ? 1 : 0.12
                        c.stroke(path, with: .color(color.opacity(l.isNew ? 0.9 : 0.5)),
                                 style: StrokeStyle(lineWidth: l.isNew ? 1.2 : 0.9, lineCap: .round))
                        // A narrow, sharp head, as in an engineering drawing.
                        var head = Path()
                        head.move(to: tip)
                        head.addLine(to: CGPoint(x: tip.x - dir.dx * 9 - dir.dy * 3.2, y: tip.y - dir.dy * 9 + dir.dx * 3.2))
                        head.addLine(to: CGPoint(x: tip.x - dir.dx * 7, y: tip.y - dir.dy * 7))
                        head.addLine(to: CGPoint(x: tip.x - dir.dx * 9 + dir.dy * 3.2, y: tip.y - dir.dy * 9 - dir.dx * 3.2))
                        head.closeSubpath()
                        c.fill(head, with: .color(color.opacity(l.isNew ? 0.95 : 0.7)))
                    }
                }
                .opacity(drawn ? 1 : 0)

                let spots = labelSpots(place, port)
                ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                    if let spot = spots[i] {
                        Text(l.label)
                            .font(.serifItalic(14))
                            .foregroundStyle(l.isNew ? Color.added : Color.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Rectangle().fill(Color.paper))
                            .fixedSize()
                            .position(spot)
                            .opacity(drawn ? (lit(l) ? 1 : 0.12) : 0)
                    }
                }

                ForEach(parts) { p in
                    if let c = place[p.id] {
                        // Hover goes on the card itself: after .position it would cover the whole graph.
                        PartCard(part: p, focused: focus == p.id)
                            .frame(width: nodeW, height: nodeH)
                            .contentShape(Rectangle())
                            .onHover { h in
                                withAnimation(.easeOut(duration: 0.18)) { focus = QA.hover(h) ? p.id : (focus == p.id ? nil : focus) }
                            }
                            .scaleEffect(drawn ? 1 : 0.94)
                            .opacity(drawn ? (lit(p) ? 1 : 0.3) : 0)
                            .position(c)
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
        let font = NSFont(name: "STIXTwoText-Italic", size: 14) ?? NSFont.systemFont(ofSize: 14)
        for (i, l) in links.enumerated() {
            guard let a = place[l.from], let b = place[l.to], !l.label.isEmpty else { continue }
            let w = (l.label as NSString).size(withAttributes: [.font: font]).width + 12, h: CGFloat = 20
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

/// A part of the system as a box in a figure: its name as written in the code, what it does in italics, and what
/// kind of thing it is in small capitals. New parts are drawn in green.
struct PartCard: View {
    let part: Story.Part
    var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(part.name)
                    .font(.mono(12.5, .medium))
                    .foregroundStyle(Color.text1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(part.isNew ? "new" : ActorHead.word(part.kind))
                    .font(.smallCaps(11.5))
                    .tracking(0.8)
                    .foregroundStyle(part.isNew ? Color.added : Color.text3)
                    .fixedSize()
            }
            Text(part.role)
                .font(.serifItalic(14))
                .foregroundStyle(Color.text2)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Rectangle().fill(Color.paper))
        .overlay(Rectangle()
            .strokeBorder(part.isNew ? Color.added.opacity(focused ? 0.95 : 0.65) : Color.wash(focused ? 0.5 : 0.24),
                          lineWidth: focused ? 1.1 : 0.75))
        .help(part.isNew ? "\(part.name) — new in this pull request" : part.name)
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
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
        return n < words.count ? words[n] : "\(n)"
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
                Text("4.\(choice.id + 1)")
                    .font(.serif(16))
                    .foregroundStyle(Color.text3)
                Text(choice.title)
                    .font(.serif(19))
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

            VStack(alignment: .leading, spacing: 11) {
                Text(choice.chose)
                    .font(.serif(16.5))
                    .foregroundStyle(Color.text1)
                    .fixedSize(horizontal: false, vertical: true)
                    .anchorPreference(key: ForkRows.self, value: .bounds) { [0: $0] }
                if !choice.over.isEmpty {
                    (Text("not ").foregroundStyle(Color.text3.opacity(0.8)) + Text(Self.lower(choice.over)).foregroundStyle(Color.text3))
                        .font(.serif(15.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .anchorPreference(key: ForkRows.self, value: .bounds) { [1: $0] }
                }
            }
            .padding(.leading, 34)
            .overlayPreferenceValue(ForkRows.self) { rows in
                GeometryReader { g in
                    if let a = rows[0] {
                        Fork(chosen: g[a].minY + 11, over: rows[1].map { g[$0].minY + 10.5 })
                    }
                }
            }

            if !choice.why.isEmpty {
                Text(choice.why)
                    .font(.serifItalic(15.5))
                    .foregroundStyle(Color.text2)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
            }
            if !choice.hunks.isEmpty {
                Spacer(minLength: 0)
                Button {
                    if let h = choice.hunks.first { session.go(toHunk: h) }
                } label: {
                    HStack(spacing: 6) {
                        Text("See it in the code").font(.smallCaps(12.5)).tracking(1)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(hover ? Color.text1 : Color.text3)
                    .padding(.leading, 34)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.wash(hover ? 0.03 : 0.018)))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.wash(hover ? 0.14 : 0.09), lineWidth: 0.5))
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
            ctx.fill(Path(ellipseIn: CGRect(x: root.x - 3.5, y: root.y - 3.5, width: 7, height: 7)), with: .color(Color.text2))
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
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
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
                        Text("6.\(i + 1)")
                            .font(.serif(16))
                            .foregroundStyle(Color.text3)
                        Text(l.why)
                            .font(.serif(19))
                            .foregroundStyle(Color.text1)
                        Spacer()
                        Button {
                            session.go(toHunk: l.hunk)
                        } label: {
                            HStack(spacing: 5) {
                                Text("In Changes").font(.smallCaps(12.5)).tracking(1)
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                            }
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
