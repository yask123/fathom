// The Story tab: a pull request read as a short paper you referee. An abstract with the change's vital signs; its
// behaviour before and after as one figure, a diff of what happens rather than of text; the design, with the idea it
// rests on; what it trades; what could go wrong and whether it can be undone; the questions it leaves open; and the
// passages that carry it, annotated in the margin. ← and → turn the pages.

import SwiftUI

enum StoryPage: Int, CaseIterable, Identifiable {
    case overview, behaviour, design, tradeoffs, risk, questions, evidence

    var id: Int { rawValue }

    /// The word in the row of pages.
    var title: String {
        switch self {
        case .overview: "Abstract"
        case .behaviour: "Behaviour"
        case .design: "Design"
        case .tradeoffs: "Trade-offs"
        case .risk: "Risk"
        case .questions: "Questions"
        case .evidence: "Evidence"
        }
    }

    /// The page's name in its running head and in the contents.
    var eyebrow: String {
        switch self {
        case .overview: "Abstract"
        case .behaviour: "Before and after"
        case .design: "The design"
        case .tradeoffs: "What it trades"
        case .risk: "What could go wrong"
        case .questions: "Questions it leaves open"
        case .evidence: "Where to read"
        }
    }

    /// FATHOM_PAGE=design opens the story on that page; the old page names still work.
    static func named(_ name: String) -> StoryPage? {
        let n = name.lowercased()
        let old: [String: StoryPage] = ["overview": .overview, "problem": .behaviour, "now": .behaviour, "idea": .design,
                                        "choices": .tradeoffs, "tradeoffs": .tradeoffs, "promises": .risk, "code": .evidence]
        return allCases.first { $0.title.lowercased() == n } ?? old[n]
    }
}

struct StoryView: View {
    @Bindable var session: PRSession
    @State private var page: StoryPage = .overview
    @State private var forward = true
    @FocusState private var focused: Bool

    private var pages: [StoryPage] {
        let s = session.story, c = session.critique
        let drawing = session.storyState.isRunning, judging = session.critiqueState.isRunning
        return StoryPage.allCases.filter { p in
            switch p {
            case .design: !s.parts.isEmpty || s.concept != nil || drawing
            case .tradeoffs: !c.choices.isEmpty || judging
            case .risk: !c.door.isEmpty || !c.risks.isEmpty || !session.brief.contracts.isEmpty || judging
            case .questions: !c.questions.isEmpty || judging
            case .evidence: !c.evidence.isEmpty || judging
            default: true
            }
        }
    }

    /// Nothing to show yet: Claude is still reading, or both readings failed.
    private var nothingYet: Bool {
        session.story.isEmpty && session.critique.isEmpty && !session.storyState.isDone && !session.critiqueState.isDone
    }

    var body: some View {
        VStack(spacing: 0) {
            StoryNav(pages: pages, page: page, waiting: waiting) { go($0) }
                .padding(.top, 4)
            ZStack {
                if nothingYet {
                    if let failure = session.storyState.failure, !session.critiqueState.isRunning {
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
        // After a comment on the Evidence page, ← → turn pages again.
        .onChange(of: session.compose == nil) { _, closed in if closed && session.tab == .brief { focused = true } }
        .onChange(of: session.ref) { _, _ in page = .overview }
        .task {
            // FATHOM_PAGE=design opens the story on that page, for screenshots.
            if let name = session.store?.env["FATHOM_PAGE"], let p = StoryPage.named(name) { page = p }
        }
    }

    /// Pages Claude is still writing.
    private var waiting: Set<StoryPage> {
        let s = session.story, c = session.critique
        var out: Set<StoryPage> = []
        if session.storyState.isRunning {
            if s.flow.isEmpty { out.insert(.behaviour) }
            if s.parts.isEmpty { out.insert(.design) }
        }
        if session.critiqueState.isRunning {
            if c.choices.isEmpty { out.insert(.tradeoffs) }
            if c.door.isEmpty { out.insert(.risk) }
            if c.questions.isEmpty { out.insert(.questions) }
            if c.evidence.isEmpty { out.insert(.evidence) }
        }
        if session.brief.headline.isEmpty && session.briefState.isRunning { out.insert(.overview) }
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
        case .behaviour: BehaviourPage(session: session)
        case .design: DesignPage(session: session)
        case .tradeoffs: TradeoffsPage(session: session)
        case .risk: RiskPage(session: session)
        case .questions: QuestionsPage(session: session)
        case .evidence: EvidencePage(session: session)
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

/// The frame every page shares, set like a page of a journal: a running head, the section's number hanging in the
/// margin beside its one sentence, a dek under it in italics, then the figure. The page scrolls when it's taller
/// than the window.
struct PageFrame<Content: View>: View {
    let page: StoryPage
    let title: String
    var dek: Text? = nil
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
                if let dek {
                    dek
                        .font(.serifItalic(20))
                        .lineSpacing(3)
                        .foregroundStyle(Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 820, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 12)
                }
                content
                    .padding(.top, 34)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 64)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .frame(maxWidth: 1180, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        // FATHOM_STORY_END=1 opens pages scrolled to the end, for screenshots.
        .defaultScrollAnchor(QA.storyEnd ? .bottom : .top)
    }
}

/// A section inside a page: its name in small capitals over a hairline, an optional line of italics after it.
struct SectionHead: View {
    let title: String
    var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(title)
                    .font(.smallCaps(13.5))
                    .tracking(1.4)
                    .foregroundStyle(Color.text2)
                if !note.isEmpty {
                    Text(note)
                        .font(.serifItalic(15))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                }
            }
            Rule(opacity: 0.12)
        }
    }
}

/// A quiet action in small capitals: "See it in the code →".
struct InkButton: View {
    let title: String
    var icon: String? = "arrow.right"
    var leading: String? = nil
    var tint: Color = .text3
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let leading { Image(systemName: leading).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.smallCaps(12.5)).tracking(1)
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            }
            .foregroundStyle(hover ? Color.text1 : tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
    }
}

struct StoryFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("No reading this time")
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

/// A reading that didn't come back, said quietly, with a way to try again.
struct Missing: View {
    let what: String
    var detail = ""
    @Bindable var session: PRSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("The \(what) didn't come back this time.")
                .font(.serifItalic(16.5))
                .foregroundStyle(Color.text2)
            InkButton(title: "Read again", icon: "arrow.clockwise") { session.sound() }
                .disabled(session.isSounding)
        }
        .help(detail)
    }
}

/// Small helpers for the story's prose.
enum Prose {
    /// "only new routes stop navigation" → "Only new routes stop navigation."
    static func sentence(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces)
        // A name from the code keeps its case: "conversation-v4 header…", "placeDetail is…".
        let word = out.prefix { !$0.isWhitespace }
        let code = word.contains { $0.isNumber || "-_.()/:".contains($0) } || word.dropFirst().contains(where: \.isUppercase)
        if let first = out.first, first.isLowercase, !code { out = first.uppercased() + out.dropFirst() }
        if let last = out.last, !".!?".contains(last) { out += "." }
        return out
    }

    /// "Resetting state" → "resetting state", but names like "ARView" or "SceneKit" stay as written.
    static func lower(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 1, chars[0].isUppercase, chars[1].isLowercase,
              !s.split(separator: " ").first!.dropFirst().contains(where: \.isUppercase) else { return s }
        return chars[0].lowercased() + String(chars.dropFirst())
    }

    static func word(_ n: Int) -> String {
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
        return n < words.count ? words[n] : "\(n)"
    }
}

// MARK: - Abstract

/// The reading's title page, as a paper's: the title and a byline; the change's vital signs in a strip (what kind
/// of change, whether a revert undoes it, how risky, how far it reaches, what's still open); a structured abstract
/// (Problem. Move. Price.); and the contents, each line a way in.
struct OverviewPage: View {
    @Bindable var session: PRSession
    let go: (StoryPage) -> Void
    @Environment(\.runningHead) private var head

    var body: some View {
        let s = session.story, c = session.critique, b = session.brief
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RunningHead(left: head, right: "Abstract")
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

                SpecStrip(session: session, go: go)
                    .frame(maxWidth: 980, alignment: .leading)
                    .padding(.top, 34)

                Text("Abstract")
                    .font(.smallCaps(13.5))
                    .tracking(1.4)
                    .foregroundStyle(Color.text2)
                    .padding(.top, 40)
                    .padding(.bottom, 10)
                if s.problem.isEmpty && c.price.isEmpty && session.isSounding {
                    Skeleton(lines: [0.95, 0.9, 0.6], height: 14, spacing: 12).frame(maxWidth: 740)
                } else {
                    abstract(s, c)
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
                    .padding(.top, 44)
                    .padding(.bottom, 12)
                contents(s, c)
                    .frame(maxWidth: 740, alignment: .leading)
                if c.isEmpty, let failure = session.critiqueState.failure {
                    Missing(what: "referee's reading", detail: failure, session: session)
                        .padding(.top, 24)
                }
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

    /// Problem. … Move. … Price. …, the heads run in as small capitals.
    private func abstract(_ s: Story, _ c: Critique) -> Text {
        var t = Text("")
        for (head, sentence) in [("Problem.", s.problem), ("Move.", s.move), ("Price.", c.price)] where !sentence.isEmpty {
            t = t + Text(head + " ").font(.runIn(18.5)) + Text(Prose.sentence(sentence) + "  ")
        }
        return t
    }

    @ViewBuilder
    private func contents(_ s: Story, _ c: Critique) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TocRow(page: .behaviour, note: behaviourNote(s)) { go(.behaviour) }
            if !s.parts.isEmpty || s.concept != nil {
                TocRow(page: .design, note: s.concept.map { "on \(Prose.lower($0.name))" } ?? "") { go(.design) }
            }
            if !c.choices.isEmpty {
                TocRow(page: .tradeoffs, note: "", sub: c.choices.map { ("3.\($0.id + 1)", $0.title) }) { go(.tradeoffs) }
            }
            if !c.door.isEmpty || !c.risks.isEmpty {
                TocRow(page: .risk, note: riskNote(c)) { go(.risk) }
            }
            if !c.questions.isEmpty {
                TocRow(page: .questions, note: questionsNote(c)) { go(.questions) }
            }
            if !c.evidence.isEmpty {
                TocRow(page: .evidence, note: "", sub: c.evidence.map { ("6.\($0.id + 1)", $0.why) }) { go(.evidence) }
            }
        }
    }

    private func behaviourNote(_ s: Story) -> String {
        guard !s.flow.isEmpty else { return "" }
        let added = s.flow.filter { $0.status == .added }.count
        let changed = s.flow.filter { $0.status == .changed }.count
        let removed = s.flow.filter { $0.status == .removed }.count
        var parts: [String] = []
        if added > 0 { parts.append("\(Prose.word(added).lowercased()) new") }
        if changed > 0 { parts.append("\(Prose.word(changed).lowercased()) changed") }
        if removed > 0 { parts.append("\(Prose.word(removed).lowercased()) gone") }
        let steps = "\(Prose.word(s.flow.count).lowercased()) steps"
        return parts.isEmpty ? steps : steps + "; " + parts.joined(separator: ", ")
    }

    private func riskNote(_ c: Critique) -> String {
        var parts: [String] = []
        if !c.door.isEmpty { parts.append(c.oneWay ? "a one-way door" : "a two-way door") }
        let n = c.risks.count
        parts.append(n == 0 ? "no hazards found" : n == 1 ? "one hazard" : "\(Prose.word(n).lowercased()) hazards")
        return parts.joined(separator: "; ")
    }

    private func questionsNote(_ c: Critique) -> String {
        let n = c.questions.count
        let done = c.questions.filter { session.settled.contains($0.id) }.count
        let count = Prose.word(n).lowercased()
        if done == 0 { return "\(count), none settled" }
        return done == n ? "\(count), all settled" : "\(count), \(Prose.word(done).lowercased()) settled"
    }
}

/// The change's vital signs, in a strip ruled above and below like a table in a paper. Each cell opens its page.
struct SpecStrip: View {
    @Bindable var session: PRSession
    let go: (StoryPage) -> Void

    var body: some View {
        let c = session.critique, s = session.story
        let judging = session.critiqueState.isRunning
        HStack(alignment: .top, spacing: 0) {
            SpecCell(label: "Kind", value: session.brief.kind.isEmpty ? nil : Glyph.kindWord(session.brief.kind),
                     note: size, first: true) { go(.behaviour) }
            SpecCell(label: "Door", value: c.door.isEmpty ? (judging ? nil : "—") : c.oneWay ? "One-way" : "Two-way",
                     note: c.door.isEmpty ? "" : c.oneWay ? "Outlives a revert" : "A revert undoes it",
                     tint: c.oneWay ? .changed : .text1, door: c.door.isEmpty ? nil : c.oneWay) { go(.risk) }
            SpecCell(label: "Risk", value: judging && c.questions.isEmpty ? nil : c.door.isEmpty && c.risks.isEmpty ? "—" : Critique.levelWord(c.level),
                     note: hazards(c), tint: levelTint(c.level), dots: c.level) { go(.risk) }
            SpecCell(label: "Reach", value: s.parts.isEmpty ? (session.storyState.isRunning ? nil : "—") : "\(Prose.word(s.parts.count)) parts",
                     note: places(s)) { go(.design) }
            SpecCell(label: "Questions", value: c.questions.isEmpty ? (judging ? nil : "None") : open(c),
                     note: c.questions.isEmpty ? "" : "\(c.questions.filter { session.settled.contains($0.id) }.count) of \(c.questions.count) settled") { go(.questions) }
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.text1.opacity(0.5)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rule(opacity: 0.14) }
    }

    private var size: String {
        guard let d = session.diff else { return "" }
        return "+\(d.additions) −\(d.deletions) in \(d.files.count) files"
    }

    private func hazards(_ c: Critique) -> String {
        guard !c.risks.isEmpty else { return c.door.isEmpty ? "" : "No hazards named" }
        let open = c.risks.filter { $0.guardedBy.isEmpty }.count
        let n = c.risks.count
        return "\(n) hazard\(n == 1 ? "" : "s"), \(open == 0 ? "all" : "\(n - open) of \(n)") guarded"
    }

    private func places(_ s: Story) -> String {
        var seen: [String] = []
        for p in s.parts where !p.place.isEmpty && !seen.contains(p.place) { seen.append(p.place) }
        return seen.isEmpty ? "" : "in " + seen.joined(separator: ", ")
    }

    private func open(_ c: Critique) -> String {
        let left = c.questions.filter { !session.settled.contains($0.id) }.count
        return left == 0 ? "All settled" : "\(Prose.word(left)) open"
    }

    private func levelTint(_ level: Int) -> Color {
        level >= 3 ? .removed : level == 2 ? .changed : .text1
    }
}

struct SpecCell: View {
    let label: String
    let value: String?
    var note = ""
    var tint: Color = .text1
    var dots = 0
    var door: Bool? = nil
    var first = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Text(label)
                    .font(.smallCaps(11.5))
                    .tracking(1.2)
                    .foregroundStyle(Color.text3)
                if let value {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(value)
                            .font(.serif(21))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if dots > 0 { LevelDots(level: dots, tint: tint).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 } }
                        if let door { DoorGlyph(oneWay: door, tint: tint).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 } }
                    }
                } else {
                    Skeleton(lines: [0.7], height: 16).frame(width: 110).padding(.vertical, 4)
                }
                Text(note.isEmpty ? " " : note)
                    .font(.serifItalic(13.5))
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wash(hover ? 0.03 : 0))
            .overlay(alignment: .leading) {
                if !first { Rectangle().fill(Color.wash(0.1)).frame(width: 0.5).padding(.vertical, 12) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
    }
}

/// How risky, as three marks filled in.
struct LevelDots: View {
    let level: Int
    var tint: Color = .text1

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Rectangle()
                    .fill(i < level ? tint : Color.wash(0.14))
                    .frame(width: 3.5, height: 9)
            }
        }
    }
}

/// A doorway with the way through it: both ways for a change a revert undoes, one way for one it doesn't.
struct DoorGlyph: View {
    let oneWay: Bool
    var tint: Color = .text2

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            var jamb = Path()
            jamb.move(to: CGPoint(x: size.width / 2, y: 1))
            jamb.addLine(to: CGPoint(x: size.width / 2, y: size.height - 1))
            ctx.stroke(jamb, with: .color(tint.opacity(0.6)), lineWidth: 1)
            func head(_ x: CGFloat, _ dir: CGFloat, _ y: CGFloat) {
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x - dir * 5, y: y - 2.6))
                p.addLine(to: CGPoint(x: x - dir * 5, y: y + 2.6))
                p.closeSubpath()
                ctx.fill(p, with: .color(tint))
            }
            if oneWay {
                var a = Path()
                a.move(to: CGPoint(x: 1, y: mid)); a.addLine(to: CGPoint(x: size.width - 3, y: mid))
                ctx.stroke(a, with: .color(tint), lineWidth: 1)
                head(size.width - 1, 1, mid)
            } else {
                for (y, dir) in [(mid - 3, 1.0), (mid + 3, -1.0)] as [(CGFloat, CGFloat)] {
                    var a = Path()
                    a.move(to: CGPoint(x: 2, y: y)); a.addLine(to: CGPoint(x: size.width - 2, y: y))
                    ctx.stroke(a, with: .color(tint), lineWidth: 1)
                    head(dir > 0 ? size.width - 1 : 1, dir, y)
                }
            }
        }
        .frame(width: 20, height: 14)
    }
}

/// A line of the contents: number, title, a dotted leader, and the section mark; sub-entries under it.
struct TocRow: View {
    let page: StoryPage
    let note: String
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
                            .font(.serifItalic(15))
                            .foregroundStyle(Color.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    DotLeader()
                        .frame(minWidth: 24)
                        .layoutPriority(-1)
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

// MARK: - Behaviour

/// Which telling of the journey the figure shows.
enum FlowMode: String, CaseIterable, Identifiable {
    case before, diff, after
    var id: String { rawValue }
    var word: String {
        switch self {
        case .before: "Before"
        case .diff: "Diff"
        case .after: "After"
        }
    }
}

/// How the system behaved before and how it behaves now, as one figure. In the diff, a gutter marks each step the
/// way a code diff marks lines: + added, − gone, ~ changed, with what it used to be struck through.
struct BehaviourPage: View {
    @Bindable var session: PRSession
    @State private var mode: FlowMode = FlowMode(rawValue: QA.flow) ?? .diff

    var body: some View {
        let s = session.story
        PageFrame(page: .behaviour, title: s.problem,
                  dek: s.after.isEmpty ? nil : Text("Now  ").font(.runIn(20)) + Text(Prose.sentence(s.after)),
                  waiting: session.storyState.isRunning) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    ModeSwitch(mode: $mode)
                    Spacer()
                    if mode == .diff && !s.flow.isEmpty { DiffLegend() }
                }
                if s.flow.isEmpty && session.storyState.isRunning {
                    Skeleton(lines: [0.9, 0.7, 0.8], height: 14, spacing: 16).frame(maxWidth: 900).padding(.top, 20)
                } else if s.flow.isEmpty {
                    Missing(what: "drawing", session: session)
                } else {
                    Figure(number: 1, caption: caption(s)) {
                        BehaviourFigure(flow: s.flow, breaks: s.breaks, pain: s.pain, mode: mode, kinds: kinds(s))
                    }
                }
            }
            .frame(maxWidth: 1060, alignment: .leading)
        }
    }

    private func caption(_ s: Story) -> String {
        let hurt = s.pain.isEmpty ? "" : " Red marks where it went wrong."
        switch mode {
        case .diff: return "One journey through the system, before and after, as a diff: + a step this change adds, − one it removes, ~ one it changes, with what it was struck through." + hurt + " Point at an actor to follow it alone."
        case .before: return "How it went before, one step at a time." + hurt + " Under each arrow, what travels."
        case .after: return "How it goes now. Green marks steps this change adds; amber, steps it changes. Under each arrow, what travels."
        }
    }

    /// What kind of thing each actor is, where the design names it.
    private func kinds(_ s: Story) -> [String: String] {
        var out: [String: String] = [:]
        func norm(_ x: String) -> String { x.lowercased().filter { $0.isLetter || $0.isNumber } }
        for step in s.flow {
            for a in [step.from, step.to] where out[a] == nil {
                let n = norm(a)
                if let p = s.parts.first(where: { let m = norm($0.name); return !m.isEmpty && (m == n || m.contains(n) || n.contains(m)) }) {
                    out[a] = p.kind
                }
            }
        }
        return out
    }
}

/// Before · Diff · After, as words in small capitals, the current one underlined.
struct ModeSwitch: View {
    @Binding var mode: FlowMode
    @Namespace private var space

    var body: some View {
        HStack(spacing: 18) {
            ForEach(FlowMode.allCases) { m in
                let on = m == mode
                Button {
                    withAnimation(.smooth(duration: 0.45)) { mode = m }
                } label: {
                    VStack(spacing: 5) {
                        Text(m.word)
                            .font(.smallCaps(13.5))
                            .tracking(1.2)
                            .foregroundStyle(on ? Color.text1 : Color.text3)
                        ZStack {
                            Rectangle().fill(Color.clear).frame(height: 1)
                            if on {
                                Rectangle().fill(Color.text1.opacity(0.75)).frame(height: 1)
                                    .matchedGeometryEffect(id: "mode", in: space)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct DiffLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            item("+", "added", .added)
            item("−", "gone", .removed)
            item("~", "changed", .changed)
        }
    }

    private func item(_ sign: String, _ word: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(sign).font(.mono(13, .semibold)).foregroundStyle(tint)
            Text(word).font(.serifItalic(14.5)).foregroundStyle(Color.text3)
        }
    }
}

/// The journey drawn the way a textbook draws a sequence: each actor named over a dotted lifeline with what kind of
/// thing it is in italics, time running down the left, what each step does in italics over its hairline arrow and
/// what travels under it in angle brackets. Switching between before, diff and after moves the steps rather than
/// redrawing them, so you can watch the journey change. Point at an actor to follow only its part.
struct BehaviourFigure: View {
    let flow: [Story.Beat]
    let breaks: Int
    let pain: String
    let mode: FlowMode
    var kinds: [String: String] = [:]

    @State private var shown = 0
    @State private var focus: String?

    private let headerH: CGFloat = 60
    private let gutter: CGFloat = 54
    private let stubH: CGFloat = 96

    private var actors: [String] {
        var out: [String] = []
        for b in flow { for a in [b.from, b.to] where !out.contains(a) { out.append(a) } }
        return out
    }

    private var visible: [Story.Beat] {
        flow.filter { mode == .before ? $0.inBefore : mode == .after ? $0.inAfter : true }
    }

    /// The step where it went wrong before; it's marked before and in the diff.
    private var hurt: Int? { mode == .after || breaks < 0 ? nil : flow.first { $0.id == breaks }?.id }
    private var missing: Bool { breaks < 0 && !pain.isEmpty && mode != .after }
    /// The step the note about what went wrong hangs under.
    private var noteRow: Int? {
        guard !pain.isEmpty else { return nil }
        if let hurt { return hurt }
        if missing && mode == .diff { return flow.first { $0.status == .added }?.id }
        return nil
    }
    /// Before, when the problem was a step that never happened, it's drawn after the last as a dashed stub.
    private var stub: Bool { missing && mode == .before }

    private func height(_ b: Story.Beat) -> CGFloat {
        var h: CGFloat = 78
        if BeatRow.oldDoes(b, mode) != nil { h += 20 }
        if b.id == noteRow { h += 48 }
        return h
    }

    private var layout: (ys: [Int: CGFloat], total: CGFloat) {
        var y = headerH + 6
        var ys: [Int: CGFloat] = [:]
        for b in visible {
            ys[b.id] = y
            y += height(b)
        }
        if stub { y += stubH }
        return (ys, y + 24)
    }

    private func lit(_ b: Story.Beat) -> Bool { focus == nil || b.from == focus || b.to == focus }
    private func used(_ a: String) -> Bool { visible.contains { $0.from == a || $0.to == a } }

    var body: some View {
        let (ys, total) = layout
        let vis = visible
        GeometryReader { geo in
            let cols = actors
            let colW = (geo.size.width - gutter) / CGFloat(max(cols.count, 1))
            let xs = Dictionary(uniqueKeysWithValues: cols.enumerated().map { ($0.element, gutter + (CGFloat($0.offset) + 0.5) * colW) })
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Time runs down the left.
                    let axisX: CGFloat = 12, top = headerH + 8, bottom = size.height - 8
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
                    // Lifelines, dotted; the followed one drawn in.
                    for a in cols {
                        var p = Path()
                        p.move(to: CGPoint(x: xs[a] ?? 0, y: headerH))
                        p.addLine(to: CGPoint(x: xs[a] ?? 0, y: size.height - 6))
                        let on = focus == a
                        var c = ctx
                        c.opacity = used(a) ? 1 : 0.35
                        c.stroke(p, with: .color(.wash(on ? 0.4 : 0.16)),
                                 style: StrokeStyle(lineWidth: on ? 0.9 : 0.75, lineCap: .round, dash: on ? [] : [0.5, 4.5]))
                    }
                }

                ForEach(cols, id: \.self) { a in
                    // Hover goes on the head itself: after .position it would cover the whole diagram.
                    ActorHead(name: a, kind: kinds[a], focused: focus == a, dimmed: (focus != nil && focus != a) || !used(a))
                        .frame(maxWidth: colW - 8)
                        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { focus = QA.hover(h) ? a : (focus == a ? nil : focus) } }
                        .position(x: xs[a] ?? 0, y: 24)
                }

                ForEach(Array(vis.enumerated()), id: \.element.id) { i, b in
                    BeatRow(beat: b, mode: mode, x0: xs[b.from] ?? 0, x1: xs[b.to] ?? 0, width: geo.size.width, colW: colW,
                            gutter: gutter, mark: mark(b, i), hurt: b.id == hurt, note: b.id == noteRow ? pain : "",
                            missingBefore: missing && hurt == nil, lit: lit(b))
                        .frame(width: geo.size.width, height: height(b), alignment: .topLeading)
                        .offset(y: ys[b.id] ?? 0)
                        .opacity(i < shown ? 1 : 0)
                        .transition(.opacity)
                }

                if stub, let last = vis.last {
                    MissingStep(x: xs[last.to] ?? 0, colW: colW, width: geo.size.width, pain: pain)
                        .frame(width: geo.size.width, height: stubH, alignment: .topLeading)
                        .offset(y: total - 24 - stubH)
                        .opacity(shown >= vis.count ? 1 : 0)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: total)
        .frame(maxWidth: 1060)
        .animation(.smooth(duration: 0.45), value: mode)
        .animation(.smooth(duration: 0.35), value: shown)
        .task(id: flow.count) {
            // One step at a time, the way you'd draw it on a whiteboard.
            if shown > flow.count { shown = flow.count }
            while shown < flow.count {
                try? await Task.sleep(for: .milliseconds(shown == 0 ? 220 : 300))
                if Task.isCancelled { return }
                shown += 1
            }
        }
    }

    /// The gutter: t₁, t₂ … for one telling; in the diff, the step's sign.
    private func mark(_ b: Story.Beat, _ i: Int) -> (String, Color) {
        if mode == .diff {
            switch b.status {
            case .added: return ("+", .added)
            case .removed: return ("−", .removed)
            case .changed: return ("~", .changed)
            case .same: return ("", .text3)
            }
        }
        let tint: Color = b.id == hurt ? .removed : mode == .after && b.status == .added ? .added : .text3
        return ("t" + Self.subscriptDigits(i + 1), tint)
    }

    static func subscriptDigits(_ n: Int) -> String {
        String(String(n).map { c in c.wholeNumberValue.map { Character(UnicodeScalar(0x2080 + $0)!) } ?? c })
    }
}

/// One step of the journey: its arrow, what it does above and what travels below, its mark in the time gutter.
struct BeatRow: View {
    let beat: Story.Beat
    let mode: FlowMode
    let x0: CGFloat
    let x1: CGFloat
    let width: CGFloat
    let colW: CGFloat
    let gutter: CGFloat
    let mark: (String, Color)
    let hurt: Bool
    let note: String
    var missingBefore = false
    let lit: Bool

    /// What a changed step used to do, struck through above what it does now (diff only).
    static func oldDoes(_ b: Story.Beat, _ mode: FlowMode) -> String? {
        mode == .diff && b.status == .changed && !b.wasDoes.isEmpty && b.wasDoes != b.does ? b.wasDoes : nil
    }

    private var oldData: String? {
        mode == .diff && beat.status == .changed && !beat.wasData.isEmpty && beat.wasData != beat.data ? beat.wasData : nil
    }
    private var does: String { mode == .before ? beat.beforeDoes : beat.does }
    private var data: String { mode == .before ? beat.beforeData : beat.data }
    private var struck: Bool { mode == .diff && beat.status == .removed }
    private var arrowY: CGFloat { 44 + (Self.oldDoes(beat, mode) != nil ? 20 : 0) }

    /// Colour, weight, dash and how far it recedes.
    private var style: (color: Color, strong: Bool, dashed: Bool, fade: Double) {
        if hurt && (mode == .before || beat.status == .removed) { return (.removed, true, struck, 1) }
        switch mode {
        case .before: return (.stroke, false, false, 1)
        case .after:
            switch beat.status {
            case .added: return (.added, true, false, 1)
            case .changed: return (.changed, true, false, 1)
            default: return (.stroke, false, false, 1)
            }
        case .diff:
            switch beat.status {
            case .same: return (.stroke, false, false, 0.5)
            case .added: return (.added, true, false, 1)
            case .removed: return (.removed, false, true, 0.75)
            case .changed: return (.changed, true, false, 1)
            }
        }
    }

    private var dataTint: Color {
        if struck { return .text3 }
        switch (mode, beat.status) {
        case (.before, _): return .calm
        case (_, .added): return .added
        case (_, .changed): return .changed
        default: return .calm
        }
    }

    var body: some View {
        let st = style
        let selfCall = beat.from == beat.to
        let span = selfCall ? min(max(colW * 1.3, 220), 300) : min(max(abs(x1 - x0) - 12, 320), width - gutter - 8)
        let mid = selfCall ? x0 + 56 + span / 2 : (x0 + x1) / 2
        let cx = min(max(mid, gutter + span / 2), width - span / 2 - 4)
        let y = arrowY
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var tick = Path()
                tick.move(to: CGPoint(x: 9, y: y))
                tick.addLine(to: CGPoint(x: 15, y: y))
                ctx.stroke(tick, with: .color(.wash(0.35)), lineWidth: 0.75)
                var c = ctx
                c.opacity = st.fade
                Self.arrow(&c, from: x0, to: x1, y: y, color: st.color, strong: st.strong, dashed: st.dashed)
                if hurt { Self.cross(&ctx, at: CGPoint(x: x1 + (selfCall ? 44 : 0), y: y)) }
            }

            Text(mark.0)
                .font(mode == .diff ? .mono(14, .semibold) : .serifItalic(14))
                .foregroundStyle(mark.1)
                .position(x: 30, y: y)

            VStack(spacing: 3) {
                if let old = Self.oldDoes(beat, mode) {
                    Text(old)
                        .font(.serifItalic(13.5))
                        .strikethrough(true, color: (hurt ? Color.removed : Color.text3).opacity(0.7))
                        .foregroundStyle(hurt ? Color.removed.opacity(0.85) : Color.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                (Text(does).font(.serifItalic(16)).foregroundStyle(hurt && (mode == .before || struck) ? Color.removed : struck ? Color.text3 : Color.text1)
                 + (beat.status == .added && mode != .before ? Text("  new").font(.smallCaps(12.5)).foregroundStyle(Color.added) : Text("")))
                    .strikethrough(struck, color: Color.removed.opacity(0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: span, height: y - 9, alignment: .bottom)
            .position(x: cx, y: (y - 9) / 2)
            .opacity(lit ? (struck ? 0.85 : 1) : 0.18)

            let dataSpan = oldData == nil ? span : min(width - gutter - 8, max(span, 600))
            let dataX = min(max(mid, gutter + dataSpan / 2), width - dataSpan / 2 - 4)
            HStack(spacing: 8) {
                if let oldData { DataTag(text: oldData, tint: .text3, struck: true) }
                if !data.isEmpty { DataTag(text: data, tint: dataTint, struck: struck) }
            }
            .frame(width: dataSpan)
            .position(x: dataX, y: y + 16)
            .opacity(lit ? 1 : 0.18)

            if !note.isEmpty {
                PainNote(text: missingBefore ? "Before, missing: " + Prose.lower(note) : mode == .diff ? "Before: " + Prose.lower(note) : note)
                    .position(x: min(max(selfCall ? x1 + 64 + span / 2 : (x0 + x1) / 2, gutter + 150), width - 150), y: y + 54)
                    .opacity(lit ? 1 : 0.18)
            }
        }
        .animation(.smooth(duration: 0.3), value: lit)
    }

    static func arrow(_ ctx: inout GraphicsContext, from x0: CGFloat, to x1: CGFloat, y: CGFloat, color: Color, strong: Bool, dashed: Bool) {
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
        ctx.stroke(p, with: .color(color.opacity(strong ? 0.95 : 0.6)),
                   style: StrokeStyle(lineWidth: strong ? 1.25 : 0.9, lineCap: .round, dash: dashed ? [4, 3.5] : []))
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

    static func cross(_ ctx: inout GraphicsContext, at c: CGPoint) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(Color.paper))
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(Color.removed), lineWidth: 1)
        var x = Path()
        x.move(to: CGPoint(x: c.x - 3.5, y: c.y - 3.5)); x.addLine(to: CGPoint(x: c.x + 3.5, y: c.y + 3.5))
        x.move(to: CGPoint(x: c.x + 3.5, y: c.y - 3.5)); x.addLine(to: CGPoint(x: c.x - 3.5, y: c.y + 3.5))
        ctx.stroke(x, with: .color(Color.removed), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }
}

/// What travels, in angle brackets: ⟨query⟩.
struct DataTag: View {
    let text: String
    var tint: Color = .calm
    var struck = false

    var body: some View {
        (Text("⟨").font(.serif(14)) + Text(text).font(.mono(11)) + Text("⟩").font(.serif(14)))
            .foregroundStyle(tint)
            .strikethrough(struck, color: tint.opacity(0.8))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 4)
            .background(Rectangle().fill(Color.paper))
    }
}

/// The step that never happened, before: a dashed stub ending in a cross, with what was missing.
struct MissingStep: View {
    let x: CGFloat
    let colW: CGFloat
    let width: CGFloat
    let pain: String

    var body: some View {
        let to = x + min(colW * 0.9, 170)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var p = Path()
                p.move(to: CGPoint(x: x, y: 40))
                p.addLine(to: CGPoint(x: to, y: 40))
                ctx.stroke(p, with: .color(Color.removed.opacity(0.75)), style: StrokeStyle(lineWidth: 0.9, dash: [4, 4]))
                BeatRow.cross(&ctx, at: CGPoint(x: to, y: 40))
            }
            PainNote(text: pain)
                .position(x: min((x + to) / 2, width - 150), y: 70)
        }
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
                .minimumScaleFactor(0.78)
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
