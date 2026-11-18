// App state: the inbox, and one open pull request being traced.

import AppKit
import Foundation
import Observation
import SwiftUI

enum RunState: Equatable {
    case idle
    case running(Date)
    case done(Double)
    case failed(String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isDone: Bool { if case .done = self { return true }; return false }
    var failure: String? { if case .failed(let m) = self { return m }; return nil }
}

enum PRTab: String, CaseIterable, Identifiable {
    case brief, changes
    var id: String { rawValue }
    var title: String { self == .brief ? "Trace" : "Code" }
}

@MainActor
@Observable
final class AppStore {
    var viewer: Viewer?
    var forYou: [PRSummary] = []
    var yours: [PRSummary] = []
    var reviewed: [PRSummary] = []
    var recents: [PRSummary] = []
    var viewerRepos: [RepoInfo] = []
    /// The repository open in the sidebar, and its open pull requests.
    var repo: String? { didSet { state.repo = repo; persist() } }
    var repoPulls: [PRSummary] = []
    var repoLoading = false
    var repoError: String?
    var pullFilter: PullFilter = .all
    var inboxLoading = false
    var inboxError: String?
    var session: PRSession?
    var sidebarShown = true
    /// Nothing on screen but the pull request: no sidebar, no bar, no rail.
    var focus = false
    var windowWidth: CGFloat = 1500
    var model: String { didSet { state.model = model; persist() } }
    var ping: Bool { didSet { state.ping = ping; persist() } }
    /// Neon on black, ink on paper, or whatever the Mac is set to.
    var appearance: Appearance { didSet { state.appearance = appearance.rawValue; persist(); appearance.apply() } }
    var sounded: Set<String> = []
    var autoRead: Bool { didSet { state.autoRead = autoRead; persist(); if autoRead { readAhead() } } }
    var readingAhead: PRRef?
    @ObservationIgnored private var ahead: PRSession?
    @ObservationIgnored private var attempted = Set<String>()
    @ObservationIgnored private var prefetching: Task<Void, Never>?
    var linkFocusTick = 0
    let setup = Setup()
    var hasGH: Bool { setup.ghReady }
    var hasClaude: Bool { setup.claudeReady }

    @ObservationIgnored private var state: SavedState
    @ObservationIgnored let env = ProcessInfo.processInfo.environment

    init() {
        state = Library.loadState()
        model = state.model
        ping = state.ping
        autoRead = state.autoRead
        // The neon look is drawn for the dark: the first launch with it starts there, whatever was saved before.
        if state.look < SavedState.currentLook {
            state.look = SavedState.currentLook
            state.appearance = Appearance.dark.rawValue
            Library.saveState(state)
        }
        // FATHOM_APPEARANCE=light|dark shows one for screenshots without changing the saved choice.
        appearance = Appearance(rawValue: env["FATHOM_APPEARANCE"] ?? state.appearance) ?? .dark
        recents = state.recents
        repo = state.repo
        if let r = state.repo { repoPulls = state.repoPulls[r] ?? [] }
        if let inbox = state.inbox {
            // Last session's inbox, shown at once while GitHub is asked again.
            viewer = inbox.viewer
            forYou = inbox.forYou
            yours = inbox.yours
            reviewed = inbox.reviewed
            viewerRepos = inbox.repos ?? []
        }
        sounded = Library.soundedKeys()
        if env["FATHOM_SIDEBAR"] == "0" { sidebarShown = false }
        setup.onGitHubReady = { [weak self] in
            Task { await self?.refreshInbox() }
        }
        Task {
            // The user's shell environment first, so gh and claude are found where Terminal finds them.
            await Shell.loadLoginEnvironment()
            await setup.check()
            await refreshInbox()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await refreshInbox()
            }
        }
        if let open = env["FATHOM_OPEN"], let ref = PRRef.parse(open) {
            self.open(ref)
        }
    }

    func refreshInbox() async {
        // Until gh is installed and signed in, the setup card says what to do; an error here would only repeat it.
        guard hasGH else { return }
        inboxLoading = true
        defer { inboxLoading = false }
        do {
            let inbox = try await GitHub.inbox()
            withAnimation(Motion.soft) {
                viewer = inbox.viewer
                forYou = inbox.forYou
                yours = inbox.yours
                reviewed = inbox.reviewed
                viewerRepos = inbox.repos
                inboxError = nil
            }
            NSApp.dockTile.badgeLabel = inbox.forYou.isEmpty ? nil : String(inbox.forYou.count)
            state.inbox = CachedInbox(viewer: inbox.viewer, forYou: inbox.forYou, yours: inbox.yours, reviewed: inbox.reviewed,
                                      repos: inbox.repos)
            persist()
            // The first time, open the repository with the most waiting for you.
            if repo == nil, let first = repos.first { repo = first.slug }
            await refreshRepo()
            readAhead()
            prefetch()
        } catch {
            inboxError = error.localizedDescription
            // A login that stopped working (signed out, token revoked) belongs on the setup card.
            if error.localizedDescription.contains("isn't signed in") { await setup.check() }
        }
    }

    enum PullFilter: String, CaseIterable, Identifiable {
        case forYou, all, mine
        var id: String { rawValue }
        var title: String {
            switch self {
            case .forYou: "For you"
            case .all: "Open"
            case .mine: "Yours"
            }
        }
    }

    /// Every repository worth switching to: ones with PRs waiting for you first, then yours by recent pushes,
    /// then any you've opened a PR in.
    var repos: [RepoInfo] {
        var bySlug: [String: RepoInfo] = [:]
        var order: [String] = []
        func add(_ slug: String, open: Int? = nil, pushed: Date? = nil) {
            if bySlug[slug] == nil {
                bySlug[slug] = RepoInfo(slug: slug, open: open ?? 0, pushedAt: pushed)
                order.append(slug)
            } else if let open { bySlug[slug]!.open = max(bySlug[slug]!.open, open) }
        }
        for r in viewerRepos where r.open > 0 { add(r.slug, open: r.open, pushed: r.pushedAt) }
        for pr in forYou + yours + reviewed + recents { add(pr.ref.slug) }
        if let repo { add(repo) }
        let waiting = Dictionary(grouping: forYou, by: \.ref.slug).mapValues(\.count)
        return order.compactMap { bySlug[$0] }.sorted { (waiting[$0.slug] ?? 0, $0.open) > (waiting[$1.slug] ?? 0, $1.open) }
    }

    func waiting(in slug: String) -> Int { forYou.filter { $0.ref.slug == slug }.count }

    /// The sidebar's list: the repository's open PRs, narrowed by the filter.
    var shownPulls: [PRSummary] {
        let mine = viewer?.login ?? ""
        let requested = Set(forYou.map(\.id))
        switch pullFilter {
        case .all: return repoPulls
        case .forYou: return repoPulls.filter { requested.contains($0.id) }
        case .mine: return repoPulls.filter { $0.author == mine }
        }
    }

    func isRequested(_ pr: PRSummary) -> Bool { forYou.contains { $0.id == pr.id } }

    func selectRepo(_ slug: String) {
        guard slug != repo else { return }
        repo = slug
        repoPulls = state.repoPulls[slug] ?? []
        repoError = nil
        Task { await refreshRepo() }
    }

    func refreshRepo() async {
        guard let slug = repo, hasGH else { return }
        repoLoading = true
        defer { repoLoading = false }
        do {
            let pulls = try await GitHub.pulls(slug)
            guard slug == repo else { return }
            withAnimation(Motion.soft) {
                repoPulls = pulls
                repoError = nil
            }
            state.repoPulls[slug] = pulls
            persist()
        } catch {
            if slug == repo { repoError = error.localizedDescription }
        }
    }

    func open(_ ref: PRRef) {
        if repo != ref.slug { selectRepo(ref.slug) }
        if session?.ref == ref { return }
        session?.stop()
        if ahead?.ref == ref, let s = ahead {
            ahead = nil
            readingAhead = nil
            s.background = false
            s.onSounded = nil
            withAnimation(Motion.spring) {
                session = s
                sidebarShown = false
            }
            if let d = s.detail { remember(d.summary) }
            return
        }
        let s = PRSession(ref: ref, store: self)
        withAnimation(Motion.spring) {
            session = s
            sidebarShown = false
        }
        s.start()
    }

    func close() {
        session?.stop()
        withAnimation(Motion.spring) {
            session = nil
            focus = false
            sidebarShown = true
        }
    }

    func toggleFocus() {
        guard session != nil else { return }
        withAnimation(Motion.spring) {
            focus.toggle()
            if focus { sidebarShown = false }
        }
    }

    func isSounded(_ pr: PRSummary) -> Bool {
        sounded.contains("\(pr.ref.id)@\(pr.headSha.prefix(12))")
    }

    /// Fetches the top of the inbox ahead of time — details and diffs, no AI — so opening one is instant.
    func prefetch() {
        guard prefetching == nil, env["FATHOM_NO_PREFETCH"] != "1", hasGH else { return }
        let items = Array((forYou + yours).prefix(8))
        prefetching = Task(priority: .utility) {
            for pr in items {
                if Task.isCancelled { break }
                if session?.ref == pr.ref || Library.cachedHead(pr.ref) == pr.headSha { continue }
                do {
                    let (detail, raw) = try await GitHub.detailWithData(pr.ref)
                    let text = try await GitHub.diff(pr.ref)
                    Library.savePR(pr.ref, detail: raw, diff: text, head: detail.headSha)
                } catch {}
            }
            Library.prunePRs(keep: 60)
            prefetching = nil
        }
    }

    /// With auto-read on, sounds review requests nobody has read yet, one at a time, in the background.
    func readAhead() {
        guard autoRead, ahead == nil, env["FATHOM_NO_AI"] != "1", Claude.executable != nil else { return }
        let key: (PRSummary) -> String = { "\($0.ref.id)@\($0.headSha)" }
        guard let next = forYou.first(where: {
            !isSounded($0) && session?.ref != $0.ref && !$0.isDraft && !attempted.contains(key($0))
        }) else { return }
        attempted.insert(key(next))
        let s = PRSession(ref: next.ref, store: self, background: true)
        ahead = s
        readingAhead = next.ref
        s.onSounded = { [weak self, weak s] in
            s?.stop()
            self?.ahead = nil
            self?.readingAhead = nil
            self?.readAhead()
        }
        s.start()
    }

    func remember(_ summary: PRSummary) {
        recents.removeAll { $0.id == summary.id }
        recents.insert(summary, at: 0)
        if recents.count > 24 { recents = Array(recents.prefix(24)) }
        state.recents = recents
        persist()
    }

    func forget(_ ref: PRRef) {
        recents.removeAll { $0.ref == ref }
        state.recents = recents
        persist()
    }

    // MARK: Per-PR saved bits

    func reviewed(_ key: String) -> Set<Int> { Set(state.reviewed[key] ?? []) }
    func setReviewed(_ key: String, _ ids: Set<Int>) {
        state.reviewed[key] = ids.sorted()
        persist()
    }

    func pending(_ ref: PRRef) -> [PendingComment] { state.pending[ref.id] ?? [] }
    func setPending(_ ref: PRRef, _ comments: [PendingComment]) {
        state.pending[ref.id] = comments.isEmpty ? nil : comments
        persist()
    }

    func markSounded(_ ref: PRRef, sha: String) {
        sounded.insert("\(ref.id)@\(sha.prefix(12))")
    }

    private func persist() { Library.saveState(state) }
}

// MARK: - One pull request

struct AskMessage: Identifiable {
    let id = UUID()
    var fromUser: Bool
    var text: String
    var activity: [Activity] = []
    var done = false
    var failed = false
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Match the Mac"
        case .light: "Paper"
        case .dark: "Neon"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
@Observable
final class PRSession {
    let ref: PRRef
    @ObservationIgnored weak var store: AppStore?

    // GitHub
    var detail: PRDetail?
    var diff: ParsedDiff?
    var loadError: String?
    /// Every line of the diff, coloured, for the Code tab's canvases; nil until the colouring is done.
    var code: CodeLines? { didSet { codeStamp &+= 1 } }
    @ObservationIgnored var codeStamp = 0

    // Claude: the trace (what it does, drawn, with its forks) and the outline (the diff in reading order, for the
    // Code tab).
    var trace = Trace()
    var traceState: RunState = .idle
    var brief = Brief() { didSet { briefVersion &+= 1 } }
    var briefState: RunState = .idle
    @ObservationIgnored var briefVersion = 0
    /// When the first words of the trace landed, for the reading clock.
    var firstPaint: Double?
    var checkoutState: RunState = .idle
    var checkout: URL?
    var soundedAt: Date?
    var soundedModel: String?

    // Looking around
    var tab: PRTab = .brief
    /// A row of the Code tab to jump to. A line ("line:f3h2:17") becomes the start of its own run of lines, so
    /// the jump lands on it rather than on the top of whatever run it was drawn in.
    var scrollTarget: String? {
        didSet {
            if let t = scrollTarget, t.hasPrefix("line:") { lineSplits.insert(String(t.dropFirst(5))) }
        }
    }
    var lineSplits: Set<String> = []
    var fileFilter: Set<String>?   // limit Changes to these files
    var filterLabel = ""
    var expandedSkips: Set<Int> = []
    var reviewed: Set<Int> = []
    var byFile = false

    // Review
    var pending: [PendingComment] = []
    var compose: Compose?         // the open comment box, if any
    var drafts: [String: String] = [:]   // words typed into comment boxes, kept while they scroll away
    var openThreads: Set<String> = []    // resolved threads unfolded
    var reviewOpen = false
    var submitting = false
    var submitError: String?
    var submittedURL: URL?
    var reviewBody = ""
    /// Set once the review itself is on GitHub but replies are still to go, so trying again sends only those.
    var reviewPosted: URL?

    // Ask
    var askOpen = false
    var askMessages: [AskMessage] = []
    var askRunning = false
    var askFocusTick = 0
    @ObservationIgnored var askSession: UUID?

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var checkoutTask: Task<URL?, Never>?
    @ObservationIgnored private var soundTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var briefJSON: Data?
    @ObservationIgnored private var traceJSON: Data?

    @ObservationIgnored var rowsCache: RowsCache?
    /// What's selected in the Code tab.
    @ObservationIgnored let selection = CodeSelection()
    @ObservationIgnored private var colouringTask: Task<Void, Never>?
    @ObservationIgnored private var diffGeneration = 0
    @ObservationIgnored private var demoApplied = false
    @ObservationIgnored var background = false
    @ObservationIgnored var onSounded: (() -> Void)?

    init(ref: PRRef, store: AppStore, background: Bool = false) {
        self.ref = ref
        self.store = store
        self.background = background
        pending = store.pending(ref)
        selection.session = self
    }

    var reviewKey: String { "\(ref.id)@\((detail?.headSha ?? "").prefix(12))" }
    var model: String { store?.model ?? "sonnet" }

    // MARK: Lifecycle

    func start() {
        loadError = nil
        tasks.append(Task { await load() })
    }

    func stop() {
        if let dir = checkout { Task { await Checkouts.shared.release(dir) } }
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        soundTasks.forEach { $0.cancel() }
        soundTasks.removeAll()
        checkoutTask?.cancel()
    }

    /// The PR head on disk, fetched the first time you ask a question, so Claude can look around the code.
    /// Opening a pull request never waits for it: the trace is read from the diff alone.
    /// Nil for very large repos, where questions are answered from the diff too.
    @discardableResult
    func ensureCheckout() -> Task<URL?, Never>? {
        if let t = checkoutTask { return t }
        guard let detail, detail.diskUsageKB < 1_500_000, store?.env["FATHOM_NO_CHECKOUT"] != "1" else { return nil }
        checkoutState = .running(Date())
        let ref = self.ref, sha = detail.headSha
        let t = Task { () -> URL? in
            do {
                let dir = try await Checkouts.shared.prepare(ref, sha: sha)
                await Checkouts.shared.hold(dir)
                checkout = dir
                checkoutState = .done(0)
                return dir
            } catch {
                checkoutState = .failed(error.localizedDescription)
                return nil
            }
        }
        checkoutTask = t
        return t
    }

    private func load() async {
        do {
            // A PR seen before opens at once from disk; GitHub is asked quietly whether it has moved on, and only
            // then does a new reading start. Background readings skip the copy: they're for the newest commit.
            if !background, let cached = Library.loadPR(ref), let d = try? GitHub.parseDetail(ref, data: cached.detail) {
                let adopted = show(detail: d, diffText: cached.diff, read: false)
                guard let refreshed = try? await GitHub.detailWithData(ref) else {
                    // Offline or a GitHub hiccup: keep the copy, and read it if it was never read.
                    if !adopted && !Task.isCancelled { startReading() }
                    return
                }
                let (fresh, raw) = refreshed
                if fresh.headSha == d.headSha {
                    detail = fresh
                    Library.savePR(ref, detail: raw, diff: cached.diff, head: fresh.headSha)
                    if !adopted { startReading() }
                } else {
                    let text = try await GitHub.diff(ref)
                    Library.savePR(ref, detail: raw, diff: text, head: fresh.headSha)
                    reset()
                    show(detail: fresh, diffText: text, read: true)
                }
                return
            }
            async let d = GitHub.detailWithData(ref)
            async let t = GitHub.diff(ref)
            let (detail, raw) = try await d
            let text = try await t
            Library.savePR(ref, detail: raw, diff: text, head: detail.headSha)
            show(detail: detail, diffText: text, read: true)
        } catch is CancellationError {
        } catch {
            if diff == nil { loadError = error.localizedDescription }
            if background { onSounded?() }
        }
    }

    /// The pull request as it was last saved, with its reading if there is one, and nothing asked of GitHub: for a
    /// picture drawn off screen. False when there's no copy on disk.
    func showCached() -> Bool {
        guard let cached = Library.loadPR(ref), let d = try? GitHub.parseDetail(ref, data: cached.detail) else { return false }
        let parsed = DiffParser.parse(cached.diff)
        if let path = store?.env["FATHOM_DUMP_PROMPT"] {
            try? Analyst.prompt(d, parsed).write(toFile: path, atomically: true, encoding: .utf8)
        }
        detail = d
        diff = parsed
        if let saved = Library.loadSounding(ref, sha: d.headSha), (saved.version ?? 1) >= Sounding.current { adopt(saved) }
        return true
    }

    /// Puts a PR on screen and adopts its saved reading; with `read`, starts one when there's none.
    /// Returns whether a saved reading was adopted.
    @discardableResult
    private func show(detail: PRDetail, diffText: String, read: Bool) -> Bool {
        let parsed = DiffParser.parse(diffText)
        if let path = store?.env["FATHOM_DUMP_PROMPT"] {
            try? Analyst.prompt(detail, parsed).write(toFile: path, atomically: true, encoding: .utf8)
        }
        withAnimation(Motion.spring) {
            self.detail = detail
            self.diff = parsed
        }
        if !background { store?.remember(detail.summary) }
        reviewed = store?.reviewed(reviewKey) ?? []
        // Line colours are keyed by position, so a slow colouring of an older diff must not land on this one.
        diffGeneration &+= 1
        let generation = diffGeneration
        colouringTask?.cancel()
        let colouring = Task.detached(priority: .userInitiated) { [parsed] in
            let colored = Self.colour(parsed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self.diffGeneration == generation { self.code = colored }
            }
        }
        colouringTask = Task { await withTaskCancellationHandler { await colouring.value } onCancel: { colouring.cancel() } }
        if !background && !demoApplied {
            demoApplied = true
            applyDemoState()
        }
        let saved = Library.loadSounding(ref, sha: detail.headSha)
        if let s = saved, (s.version ?? 1) >= Sounding.current || store?.env["FATHOM_NO_AI"] == "1" {
            adopt(s)
            if background { onSounded?() }
            return true
        }
        if read { startReading() }
        return false
    }

    private func startReading() {
        if store?.env["FATHOM_NO_AI"] != "1" {
            sound()
        } else if background {
            onSounded?()
        }
    }

    /// Forgets everything about the old head when new commits arrive.
    private func reset() {
        soundTasks.forEach { $0.cancel() }
        soundTasks.removeAll()
        colouringTask?.cancel()
        colouringTask = nil
        checkoutTask?.cancel()
        checkoutTask = nil
        if let dir = checkout { Task { await Checkouts.shared.release(dir) } }
        checkout = nil
        checkoutState = .idle
        briefJSON = nil
        traceJSON = nil
        brief = Brief()
        trace = Trace()
        briefState = .idle
        traceState = .idle
        firstPaint = nil
        code = nil
        lineSplits = []
        askSession = nil
        soundedAt = nil
        // These point at the old diff's hunks and lines.
        compose = nil
        selection.clear()
        expandedSkips = []
        fileFilter = nil
        filterLabel = ""
        rowsCache = nil
    }

    private func adopt(_ s: Sounding) {
        briefJSON = s.brief
        traceJSON = s.story
        withAnimation(Motion.spring) {
            if let b = s.brief { brief = Brief(J(data: b)) }
            if let t = s.story { trace = Trace(J(data: t)) }
            briefState = s.brief == nil ? .failed("No outline saved") : .done(s.briefSeconds ?? 0)
            traceState = s.story == nil ? .failed("No trace saved") : .done(s.storySeconds ?? 0)
        }
        soundedAt = s.createdAt
        soundedModel = s.model
    }

    /// The two readings, side by side, each from the diff alone so nothing waits on a checkout or a lookup: the
    /// trace (drawn as it's written) and the outline that puts the Code tab in reading order.
    func sound() {
        guard let detail, let diff else { return }
        guard Claude.executable != nil else {
            traceState = .failed("Install Claude Code so \(Brand.name) can read pull requests. Open Settings (⌘,) to set it up.")
            briefState = traceState
            return
        }
        briefJSON = nil
        traceJSON = nil
        brief = Brief()
        trace = Trace()
        soundedAt = nil
        firstPaint = nil
        let prompt = Analyst.prompt(detail, diff)
        let model = self.model
        let started = Date()
        traceState = .running(started)
        briefState = .running(started)

        // A second reading replaces the first.
        soundTasks.forEach { $0.cancel() }
        soundTasks = Reading.allCases.map { which in
            Task { await run(which, prompt: prompt, model: model, started: started) }
        }
    }

    enum Reading: CaseIterable {
        case trace, outline

        var name: String { self == .trace ? "trace" : "outline" }
    }

    private func state(_ which: Reading) -> RunState { which == .trace ? traceState : briefState }

    /// One reading. What Claude has written so far goes on screen a few times a second.
    private func run(_ which: Reading, prompt: String, model: String, started: Date) async {
        let scratch = Library.root.appending(path: "scratch", directoryHint: .isDirectory)
        Library.ensure(scratch)
        let (system, schema) = which == .trace ? (Analyst.traceSystem, Analyst.traceSchema) : (Analyst.outlineSystem, Analyst.outlineSchema)
        // Low effort: these are short, structured answers, and thinking first only delays the first word.
        let options = Claude.Options(model: model, effort: "low", system: system, schema: schema, tools: [], cwd: scratch)
        var lastPaint = Date.distantPast
        do {
            for try await event in Claude.run(prompt, options) {
                switch event {
                case .structured(let text):
                    guard Date().timeIntervalSince(lastPaint) > 0.12 else { continue }
                    lastPaint = Date()
                    guard let obj = PartialJSON.parse(text) else { continue }
                    switch which {
                    // Words are set as they come, with no animation (a sentence cross-fading into its own next
                    // word smears); only a new part, step or fork eases in.
                    case .trace:
                        let next = Trace(J(obj), partial: true)
                        guard !next.isEmpty else { continue }
                        if firstPaint == nil { firstPaint = Date().timeIntervalSince(started) }
                        if next.cast.count != trace.cast.count || next.flow.count != trace.flow.count || next.forks.count != trace.forks.count {
                            withAnimation(Motion.soft) { trace = next }
                        } else {
                            trace = next
                        }
                    case .outline:
                        brief = Brief(J(obj))
                    }
                case .finished(let f):
                    guard !f.isError, let data = f.structured else {
                        fail(which, f.isError ? f.message : "Claude didn't return the \(which.name)")
                        continue
                    }
                    let seconds = Date().timeIntervalSince(started)
                    withAnimation(.smooth(duration: 0.5)) {
                        switch which {
                        case .trace:
                            traceJSON = data
                            trace = Trace(J(data: data))
                            traceState = .done(seconds)
                        case .outline:
                            briefJSON = data
                            brief = Brief(J(data: data))
                            briefState = .done(seconds)
                        }
                    }
                default: break
                }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { fail(which, error.localizedDescription) }
        }
        if state(which).isRunning && !Task.isCancelled { fail(which, "Claude stopped before finishing the \(which.name)") }
        settle()
    }

    private func fail(_ which: Reading, _ message: String) {
        withAnimation(Motion.soft) {
            switch which {
            case .trace:
                if traceJSON == nil { trace = Trace() }
                traceState = .failed(message)
            case .outline:
                if briefJSON == nil { brief = Brief() }
                briefState = .failed(message)
            }
        }
    }

    /// When both readings are over, keep what came back; a background reading then hands over to the next one.
    private func settle() {
        guard !isSounding, !Task.isCancelled else { return }
        if briefJSON != nil || traceJSON != nil { save() }
        if background { onSounded?() }
    }

    private func save() {
        guard let detail else { return }
        var briefSeconds: Double?, traceSeconds: Double?
        if case .done(let s) = briefState { briefSeconds = s }
        if case .done(let s) = traceState { traceSeconds = s }
        Library.saveSounding(Sounding(ref: ref, headSha: detail.headSha, model: model, brief: briefJSON, map: nil, story: traceJSON,
                                      critique: nil, briefSeconds: briefSeconds, mapSeconds: nil, storySeconds: traceSeconds,
                                      critiqueSeconds: nil, createdAt: Date(), version: Sounding.current))
        soundedAt = Date()
        soundedModel = model
        store?.markSounded(ref, sha: detail.headSha)
        guard !background else { return }
        if store?.ping == true, store?.env["FATHOM_MUTE"] != "1", let sound = NSSound(named: "Tink") {
            sound.volume = 0.18
            sound.play()
        }
        if NSApp.isActive == false { NSApp.requestUserAttention(.informationalRequest) }
    }

    nonisolated static func colour(_ diff: ParsedDiff) -> CodeLines {
        var out: [String: NSAttributedString] = [:]
        for f in diff.files where !f.isBinary && f.noise == nil {
            if Task.isCancelled { break }
            for h in f.hunks {
                // Old and new sides are coloured as separate sequences so block comments carry over correctly.
                let newSide = h.lines.enumerated().filter { $0.element.kind != .del }
                let oldSide = h.lines.enumerated().filter { $0.element.kind == .del }
                var coloured: [Int: AttributedString] = [:]
                for (side) in [newSide, oldSide] {
                    // Minified or generated one-liners stay plain; matching them costs seconds.
                    let painted = side.contains { $0.element.text.utf16.count > 2000 }
                        ? side.map { Highlighter.plain($0.element.text) }
                        : Highlighter.highlight(side.map(\.element.text), f.language)
                    for (k, item) in side.enumerated() { coloured[item.offset] = painted[k] }
                }
                let spans = Intraline.spans(for: h.lines)
                for (i, var a) in coloured {
                    if let s = spans[i] {
                        Highlighter.mark(&a, spans: s, color: h.lines[i].kind == .add ? CodeInk.addMark : CodeInk.delMark)
                    }
                    out["\(h.id):\(i)"] = Highlighter.ns(a)
                }
            }
        }
        return CodeLines(out)
    }

    // MARK: Derived

    var isSounding: Bool { briefState.isRunning || traceState.isRunning }

    /// Lines worth reading vs. lines you can skip, from the chapters (or file noise before they arrive).
    var reading: (focus: Int, skim: Int, skip: Int) {
        guard let diff else { return (0, 0, 0) }
        func size(_ id: String) -> Int { diff.hunk(id).map { $0.additions + $0.deletions } ?? 0 }
        if !brief.chapters.isEmpty {
            var focus = 0, skim = 0, skip = 0
            for c in brief.chapters {
                let n = c.hunks.reduce(0) { $0 + size($1) }
                switch c.attention {
                case .focus: focus += n
                case .skim: skim += n
                case .skip: skip += n
                }
            }
            skip += diff.noiseFiles.reduce(0) { $0 + $1.additions + $1.deletions }
            return (focus, skim, skip)
        }
        let noise = diff.noiseFiles.reduce(0) { $0 + $1.additions + $1.deletions }
        return (diff.additions + diff.deletions - noise, 0, noise)
    }

    var reviewMinutes: Int {
        let r = reading
        return max(1, Int((Double(r.focus) / 45 + Double(r.skim) / 160).rounded(.up)))
    }

    // MARK: Actions

    func go(toHunk id: String, anchor: String = "") {
        guard let diff else { return }
        var target = "hunk:\(id)"
        if !anchor.isEmpty, let i = diff.lineIndex(hunk: id, anchor: anchor) { target = "line:\(id):\(i)" }
        withAnimation(Motion.spring) {
            if let c = brief.chapters.first(where: { $0.hunks.contains(id) }), c.attention == .skip { expandedSkips.insert(c.id) }
            fileFilter = nil
            tab = .changes
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            scrollTarget = target
        }
    }

    /// Opens Changes at a file, at the line that mentions `text` when there is one.
    func go(toFile path: String, containing text: String) {
        guard let diff, let f = diff.file(path: path), let first = f.hunks.first else { return }
        if !text.isEmpty, let h = f.hunks.first(where: { diff.lineIndex(hunk: $0.id, anchor: text) != nil }) {
            go(toHunk: h.id, anchor: text)
            return
        }
        go(toHunk: first.id)
    }

    func go(toChapter id: Int) {
        withAnimation(Motion.spring) { tab = .changes }
        scrollTarget = "chapter:\(id)"
    }

    func clearFilter() {
        withAnimation(Motion.soft) {
            fileFilter = nil
            filterLabel = ""
        }
    }

    func toggleReviewed(_ chapter: Int) {
        withAnimation(Motion.snappy) {
            if reviewed.contains(chapter) { reviewed.remove(chapter) } else { reviewed.insert(chapter) }
        }
        store?.setReviewed(reviewKey, reviewed)
    }

    // MARK: Review comments

    /// Opens a comment box on a line: a new comment, a reply in a thread, or an edit of one of yours.
    func startComposing(_ c: Compose) {
        withAnimation(Motion.snappy) { compose = c }
    }

    /// Closes the box. Esc keeps what was typed for next time; Cancel throws it away.
    func cancelCompose(discard: Bool = true) {
        guard let c = compose else { return }
        if discard { drafts[c.draftKey] = nil }
        withAnimation(Motion.snappy) { compose = nil }
    }

    /// Adds what's in the open box to the review (or saves the edit).
    func commitCompose() {
        guard let c = compose else { return }
        var original = ""
        if case .edit(let id) = c.kind { original = pending.first { $0.id == id }?.body ?? "" }
        let text = (drafts[c.draftKey] ?? original).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        drafts[c.draftKey] = nil
        withAnimation(Motion.spring) {
            switch c.kind {
            case .edit(let id):
                if let i = pending.firstIndex(where: { $0.id == id }) { pending[i].body = text }
            case .reply(let to):
                pending.append(PendingComment(path: c.path, line: c.line, side: c.side, body: text, hunk: c.hunk, replyTo: to))
            case .new:
                pending.append(PendingComment(path: c.path, line: c.line, side: c.side, body: text, hunk: c.hunk))
            }
            compose = nil
        }
        store?.setPending(ref, pending)
    }

    /// ⌘↩: adds the comment being written; with an empty box (or none), opens the review.
    func commandReturn() {
        guard let c = compose, !reviewOpen else {
            reviewOpen = true
            return
        }
        var original = ""
        if case .edit(let id) = c.kind { original = pending.first { $0.id == id }?.body ?? "" }
        if (drafts[c.draftKey] ?? original).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancelCompose()
            reviewOpen = true
        } else {
            commitCompose()
        }
    }

    /// The text of a box, for the editor to bind to.
    func draft(_ key: String, initial: String = "") -> Binding<String> {
        Binding(get: { self.drafts[key] ?? initial }, set: { self.drafts[key] = $0 })
    }

    var threadsByLine: [String: [ReviewThread]] {
        var out: [String: [ReviewThread]] = [:]
        for t in detail?.threads ?? [] { if let k = t.key { out[k, default: []].append(t) } }
        return out
    }


    func removeComment(_ id: UUID) {
        withAnimation(Motion.spring) { pending.removeAll { $0.id == id } }
        store?.setPending(ref, pending)
    }

    func updateComment(_ id: UUID, body: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].body = body
        store?.setPending(ref, pending)
    }

    /// Comments whose line is still in this commit's diff, with words in them. GitHub rejects a whole
    /// review if a single comment points at a line that isn't in the diff.
    var sendableComments: [PendingComment] {
        guard let diff else { return [] }
        return pending.filter { c in
            guard !c.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            // A reply goes to its thread by id; it only needs the thread to still be there.
            if let to = c.replyTo { return detail?.threads.contains { $0.replyTo == to } ?? false }
            guard let f = diff.file(path: c.path) else { return false }
            return f.hunks.contains { h in
                h.lines.contains { l in c.side == "LEFT" ? (l.kind == .del && l.old == c.line) : (l.kind != .del && l.new == c.line) }
            }
        }
    }

    /// Whether Send has anything to send: a verdict, a summary, or comments and replies GitHub will take.
    func canSend(_ verdict: GitHub.Verdict, body: String) -> Bool {
        let sendable = sendableComments
        if reviewPosted != nil { return sendable.contains { $0.replyTo != nil } }
        return verdict != .comment || !sendable.isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit(_ verdict: GitHub.Verdict, body: String) {
        guard let detail, !submitting else { return }
        let sendable = sendableComments
        let comments = sendable.filter { $0.replyTo == nil }
        let replies = sendable.filter { $0.replyTo != nil }
        let posted = reviewPosted
        let review = posted == nil && (verdict != .comment || !comments.isEmpty
                                       || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard review || !replies.isEmpty else {
            submitError = "Nothing here can be sent: write a summary, pick a verdict, or comment on a line that's in this commit."
            return
        }
        submitting = true
        submitError = nil
        tasks.append(Task {
            do {
                var url = posted
                if review {
                    url = try await GitHub.submitReview(ref, commit: detail.headSha, verdict: verdict, body: body, comments: comments)
                    // The review is in. If a reply fails now, trying again must not post the review a second time.
                    reviewPosted = url ?? ref.web
                    reviewBody = ""
                    pending.removeAll { c in comments.contains { $0.id == c.id } }
                    store?.setPending(ref, pending)
                }
                for r in replies {
                    let u = try await GitHub.reply(ref, to: r.replyTo ?? 0, body: r.body)
                    url = url ?? u
                    pending.removeAll { $0.id == r.id }
                    store?.setPending(ref, pending)
                }
                // Anything left out (its line is gone) stays, so nothing you wrote disappears unsent.
                withAnimation(Motion.spring) {
                    submittedURL = url ?? ref.web
                    reviewPosted = nil
                    drafts = [:]
                    submitting = false
                }
            } catch {
                submitting = false
                submitError = error.localizedDescription
                    + (reviewPosted != nil ? "\n\nYour review is on GitHub. Send again to post the replies that are left." : "")
            }
        })
    }

    // MARK: Ask

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !askRunning, let detail, let diff else { return }
        withAnimation(Motion.spring) {
            askOpen = true
            askMessages.append(AskMessage(fromUser: true, text: q, done: true))
            askMessages.append(AskMessage(fromUser: false, text: ""))
        }
        askRunning = true
        let first = askSession == nil
        let session = askSession ?? UUID()
        askSession = session
        let prompt = first ? Analyst.askOpening(detail, diff, headline: trace.headline, question: q) : q
        let model = self.model
        let checkoutTask = ensureCheckout()
        tasks.append(Task {
            let dir = await checkoutTask?.value
            let cwd = dir ?? Library.root.appending(path: "scratch", directoryHint: .isDirectory)
            Library.ensure(cwd)
            let options = Claude.Options(model: model, effort: "low", system: Analyst.askSystem, schema: nil,
                                         tools: dir == nil ? [] : ["Read", "Grep", "Glob"], cwd: cwd,
                                         session: session, resume: !first)
            do {
                for try await event in Claude.run(prompt, options) {
                    guard let i = askMessages.indices.last else { break }
                    switch event {
                    case .text(let t):
                        askMessages[i].text += t
                    case .activity(let a):
                        withAnimation(Motion.soft) { askMessages[i].activity.append(a) }
                    case .finished(let f):
                        if f.isError {
                            askMessages[i].text = f.message
                            askMessages[i].failed = true
                        } else if askMessages[i].text.isEmpty {
                            askMessages[i].text = f.text
                        }
                        withAnimation(Motion.soft) { askMessages[i].done = true }
                    default: break
                    }
                }
            } catch {
                if let i = askMessages.indices.last {
                    askMessages[i].text = error.localizedDescription
                    askMessages[i].failed = true
                    askMessages[i].done = true
                }
                if first { askSession = nil }
            }
            askRunning = false
        })
    }

    func clearAsk() {
        withAnimation(Motion.spring) { askMessages = [] }
        askSession = nil
    }

    // MARK: QA

    /// FATHOM_TAB, FATHOM_FLOW, FATHOM_FOCUS, FATHOM_ASK put the window in a given state for screenshots.
    private func applyDemoState() {
        guard let env = store?.env else { return }
        tasks.append(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if env["FATHOM_TAB"] == "changes" { tab = .changes }
            if env["FATHOM_BY_FILE"] == "1" { byFile = true }
            for _ in 0..<600 where (trace.isEmpty || brief.isEmpty) && env["FATHOM_NO_AI"] != "1" {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let q = env["FATHOM_ASK"] {
                if q.isEmpty { withAnimation(Motion.spring) { askOpen = true } } else { ask(q) }
            }
            if env["FATHOM_REVIEW"] == "1" { reviewOpen = true }
            if env["FATHOM_FOCUS"] == "1" {
                // On its own turn: a change made in the same turn as the tab switch above can be missed.
                try? await Task.sleep(for: .milliseconds(700))
                store?.toggleFocus()
            }
            if let h = env["FATHOM_GO"] { go(toHunk: h) }
            // FATHOM_COMMENT=path:line opens a comment box there (FATHOM_DRAFT fills it, FATHOM_ADD=1 adds it);
            // FATHOM_REPLY=<thread id> opens a reply in that conversation.
            if let spec = env["FATHOM_COMMENT"], let colon = spec.lastIndex(of: ":"), let n = Int(spec[spec.index(after: colon)...]),
               let f = diff?.file(path: String(spec[..<colon])),
               let h = f.hunks.first(where: { $0.lines.contains { $0.kind != .del && $0.new == n } }),
               let i = h.lines.firstIndex(where: { $0.kind != .del && $0.new == n }) {
                withAnimation(Motion.spring) { tab = .changes }
                try? await Task.sleep(for: .milliseconds(300))
                scrollTarget = "line:\(h.id):\(max(i - 3, 0))"
                try? await Task.sleep(for: .milliseconds(300))
                let c = Compose(kind: .new, path: f.path, line: n, side: "RIGHT", hunk: h.id)
                if let d = env["FATHOM_DRAFT"] { drafts[c.draftKey] = d.replacingOccurrences(of: "\\n", with: "\n") }
                startComposing(c)
                if env["FATHOM_ADD"] == "1" { commitCompose() }
            }
            if let id = env["FATHOM_REPLY"], let t = detail?.threads.first(where: { $0.id == id }), let n = t.line, let to = t.replyTo,
               let h = diff?.file(path: t.path)?.hunks.first(where: { $0.lines.contains { $0.kind != .del && $0.new == n } }) {
                withAnimation(Motion.spring) { tab = .changes }
                try? await Task.sleep(for: .milliseconds(300))
                scrollTarget = "thread:\(id)"
                try? await Task.sleep(for: .milliseconds(300))
                let c = Compose(kind: .reply(to), path: t.path, line: n, side: t.side, hunk: h.id, thread: id)
                if let d = env["FATHOM_DRAFT"] { drafts[c.draftKey] = d.replacingOccurrences(of: "\\n", with: "\n") }
                startComposing(c)
            }
            // FATHOM_STAGETEST=3 clicks the trace's third column the way a pointer would, to check that a click pins a
            // step; FATHOM_STAGETEST=play clicks the play button. FATHOM_BENCH_OUT gets a line when it's done.
            if let what = env["FATHOM_STAGETEST"] {
                try? await Task.sleep(for: .seconds(2.6))
                var line = "no stage"
                if let w = NSApp.windows.first(where: { $0.contentView != nil }), let content = w.contentView {
                    var spot: CGPoint?
                    if what == "play", !StageProbe.play.isEmpty {
                        spot = CGPoint(x: StageProbe.play.midX, y: StageProbe.play.midY)
                    } else if let n = Int(what), StageProbe.columns.indices.contains(n - 1) {
                        spot = CGPoint(x: StageProbe.frame.minX + StageProbe.columns[n - 1].x, y: StageProbe.frame.minY + StageProbe.columns[n - 1].y)
                    }
                    if let spot {
                        let at = NSPoint(x: spot.x, y: content.bounds.height - spot.y)
                        // A click on a window that isn't in front only brings it forward, and this window must not
                        // come forward (the Mac may be in use). So, for this test only, the views under the point are
                        // told to take that first click, and the press and release go through the app as real ones do.
                        let hit = content.superview?.hitTest(at)
                        let sel = #selector(NSView.acceptsFirstMouse(for:))
                        let yes: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
                        if let m = class_getInstanceMethod(NSView.self, sel) {
                            var view: NSView? = hit
                            while let v = view {
                                if type(of: v) != NSView.self { class_replaceMethod(type(of: v), sel, imp_implementationWithBlock(yes), method_getTypeEncoding(m)) }
                                view = v.superview
                            }
                        }
                        let ignoring = w.ignoresMouseEvents
                        w.ignoresMouseEvents = false
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                NSApp.sendEvent(e)
                            }
                            try? await Task.sleep(for: .milliseconds(60))
                        }
                        w.ignoresMouseEvents = ignoring
                        try? await Task.sleep(for: .milliseconds(300))
                        line = "clicked \(what) at \(Int(at.x)),\(Int(at.y)); pinned step \(StageProbe.picked.map(String.init) ?? "none"); stage \(StageProbe.frame.integral); columns \(StageProbe.columns.count)"
                    }
                }
                if let path = env["FATHOM_BENCH_OUT"] { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            }
            if env["FATHOM_SELECTTEST"] == "1" {
                withAnimation(Motion.spring) { tab = .changes }
                for _ in 0..<100 where code == nil { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(1.5))
                await SelectTest.run(self)
            }
            // FATHOM_SCROLLBENCH=2400,7000 scrolls the Code tab by itself at those speeds and reports late frames.
            if let spec = env["FATHOM_SCROLLBENCH"] {
                withAnimation(Motion.spring) { tab = .changes }
                for _ in 0..<100 where code == nil { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(2))
                ScrollBench.shared.run(spec)
            }
            if let row = env["FATHOM_SCROLL"] {
                withAnimation(Motion.spring) { tab = .changes }
                try? await Task.sleep(for: .milliseconds(300))
                scrollTarget = row
            }
        })
    }
}
