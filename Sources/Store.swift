// App state: the inbox, and one open pull request being sounded.

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
    var title: String { self == .brief ? "Map" : "Changes" }
}

enum Era: String, CaseIterable, Identifiable {
    case before, after
    var id: String { rawValue }
    var title: String { self == .before ? "Before" : "After" }
}

@MainActor
@Observable
final class AppStore {
    var viewer: Viewer?
    var forYou: [PRSummary] = []
    var yours: [PRSummary] = []
    var reviewed: [PRSummary] = []
    var recents: [PRSummary] = []
    var inboxLoading = false
    var inboxError: String?
    var session: PRSession?
    var sidebarShown = true
    var windowWidth: CGFloat = 1500
    var model: String { didSet { state.model = model; persist() } }
    var ping: Bool { didSet { state.ping = ping; persist() } }
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
        recents = state.recents
        if let inbox = state.inbox {
            // Last session's inbox, shown at once while GitHub is asked again.
            viewer = inbox.viewer
            forYou = inbox.forYou
            yours = inbox.yours
            reviewed = inbox.reviewed
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
                inboxError = nil
            }
            NSApp.dockTile.badgeLabel = inbox.forYou.isEmpty ? nil : String(inbox.forYou.count)
            state.inbox = CachedInbox(viewer: inbox.viewer, forYou: inbox.forYou, yours: inbox.yours, reviewed: inbox.reviewed)
            persist()
            readAhead()
            prefetch()
        } catch {
            inboxError = error.localizedDescription
            // A login that stopped working (signed out, token revoked) belongs on the setup card.
            if error.localizedDescription.contains("isn't signed in") { await setup.check() }
        }
    }

    func open(_ ref: PRRef) {
        if session?.ref == ref { return }
        session?.stop()
        if ahead?.ref == ref, let s = ahead {
            ahead = nil
            readingAhead = nil
            s.background = false
            s.onSounded = nil
            withAnimation(Motion.spring) {
                session = s
                if windowWidth < 1440 { sidebarShown = false }
            }
            if let d = s.detail { remember(d.summary) }
            return
        }
        let s = PRSession(ref: ref, store: self)
        withAnimation(Motion.spring) {
            session = s
            if windowWidth < 1440 { sidebarShown = false }
        }
        s.start()
    }

    func close() {
        session?.stop()
        withAnimation(Motion.spring) { session = nil }
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

/// Lets exactly one of several racers through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
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
    var lines: [String: AttributedString] = [:]     // "f3h2:17" → coloured line

    // Claude
    var brief = Brief() { didSet { briefVersion &+= 1 } }
    var briefState: RunState = .idle
    var map = SystemMap()
    var mapState: RunState = .idle
    @ObservationIgnored var briefVersion = 0
    var checkoutState: RunState = .idle
    var checkout: URL?
    var activity: [Activity] = []
    var soundedAt: Date?
    var soundedModel: String?

    // Looking around
    var tab: PRTab = .brief
    var era: Era = .after
    var hoveredComponent: String?
    var hoveredFile: String?          // from the footprint or an interface card
    var selectedComponent: String?
    var hoveredEdge: String?
    var panel: Panel?                 // what sits beside the map
    var playingFlow: Int?
    var flowStep = 0
    var flowStarted = Date()
    var flowRunning = false
    var scrollTarget: String?
    var fileFilter: Set<String>?   // limit Changes to these files
    var filterLabel = ""
    var expandedSkips: Set<Int> = []
    var reviewed: Set<Int> = []
    var byFile = false

    // Review
    var pending: [PendingComment] = []
    var composing: String?      // line key of an open comment box
    var composingInPanel = false  // opened from the side panel rather than Changes
    var reviewOpen = false
    var submitting = false
    var submitError: String?
    var submittedURL: URL?
    var reviewBody = ""

    // Ask
    var askOpen = false
    var askMessages: [AskMessage] = []
    var askRunning = false
    var askFocusTick = 0
    @ObservationIgnored var askSession: UUID?

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var checkoutTask: Task<URL?, Never>?
    @ObservationIgnored private var soundTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var flowTimer: Task<Void, Never>?
    @ObservationIgnored private var briefJSON: Data?
    @ObservationIgnored private var mapJSON: Data?

    @ObservationIgnored var rowsCache: RowsCache?
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
    }

    var reviewKey: String { "\(ref.id)@\((detail?.headSha ?? "").prefix(12))" }
    var model: String { store?.model ?? "opus" }

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
        flowTimer?.cancel()
        checkoutTask?.cancel()
    }

    /// The PR head on disk, fetched once per session and shared by the map and by questions.
    /// Nil for very large repos, where Claude works from the diff alone.
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
                if self.diffGeneration == generation { self.lines = colored }
            }
        }
        colouringTask = Task { await withTaskCancellationHandler { await colouring.value } onCancel: { colouring.cancel() } }
        if !background && !demoApplied {
            demoApplied = true
            applyDemoState()
        }
        ensureCheckout()
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
        flowTimer?.cancel()
        flowTimer = nil
        flowRunning = false
        checkoutTask?.cancel()
        checkoutTask = nil
        if let dir = checkout { Task { await Checkouts.shared.release(dir) } }
        checkout = nil
        checkoutState = .idle
        briefJSON = nil
        mapJSON = nil
        brief = Brief()
        map = SystemMap()
        briefState = .idle
        mapState = .idle
        panel = nil
        selectedComponent = nil
        playingFlow = nil
        lines = [:]
        askSession = nil
        soundedAt = nil
        // These point at the old diff's hunks and lines.
        composing = nil
        expandedSkips = []
        fileFilter = nil
        filterLabel = ""
        rowsCache = nil
    }

    private func adopt(_ s: Sounding) {
        briefJSON = s.brief
        mapJSON = s.map
        withAnimation(Motion.spring) {
            if let b = s.brief { brief = Brief(J(data: b)) }
            if let m = s.map { map = SystemMap(J(data: m)) }
            briefState = s.brief == nil ? .failed("No brief saved") : .done(s.briefSeconds ?? 0)
            mapState = s.map == nil ? .failed("No map saved") : .done(s.mapSeconds ?? 0)
        }
        soundedAt = s.createdAt
        soundedModel = s.model
    }

    /// Runs both readings: the brief (diff only, fast to first word) and the map (explores the repo).
    func sound() {
        guard let detail, let diff else { return }
        guard Claude.executable != nil else {
            briefState = .failed("Install Claude Code (claude.com/code) so Fathom can read PRs")
            mapState = briefState
            return
        }
        briefJSON = nil
        mapJSON = nil
        brief = Brief()
        map = SystemMap()
        activity = []
        selectedComponent = nil
        panel = nil
        stopFlow()
        soundedAt = nil
        let prompt = Analyst.prompt(detail, diff)
        let model = self.model
        let started = Date()
        briefState = .running(started)
        mapState = .running(started)

        // A second sounding replaces the first.
        soundTasks.forEach { $0.cancel() }
        soundTasks = [
            Task { await runBrief(prompt: prompt, model: model, started: started) },
            Task { await runMap(prompt: prompt, model: model, started: started, detail: detail) },
        ]
    }

    private func runBrief(prompt: String, model: String, started: Date) async {
        let scratch = Library.root.appending(path: "scratch", directoryHint: .isDirectory)
        Library.ensure(scratch)
        let options = Claude.Options(model: model, effort: "medium", system: Analyst.briefSystem, schema: Analyst.briefSchema,
                                     tools: [], cwd: scratch)
        var lastPaint = Date.distantPast
        do {
            for try await event in Claude.run(prompt, options) {
                switch event {
                case .structured(let text):
                    guard Date().timeIntervalSince(lastPaint) > 0.15 else { continue }
                    lastPaint = Date()
                    if let obj = PartialJSON.parse(text) {
                        let next = Brief(J(obj))
                        withAnimation(Motion.soft) { brief = next }
                    }
                case .finished(let f):
                    if f.isError || f.structured == nil {
                        briefState = .failed(f.isError ? f.message : "Claude didn't return a brief")
                    } else if let data = f.structured {
                        briefJSON = data
                        withAnimation(Motion.spring) {
                            brief = Brief(J(data: data))
                            briefState = .done(Date().timeIntervalSince(started))
                        }
                    }
                default: break
                }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { briefState = .failed(error.localizedDescription) }
        }
        if briefState.isRunning && !Task.isCancelled { briefState = .failed("Claude stopped before finishing the brief") }
        settle()
    }

    private func runMap(prompt: String, model: String, started: Date, detail: PRDetail) async {
        // A checkout lets Claude see callers and neighbours; very large repos go without.
        var cwd = Library.root.appending(path: "scratch", directoryHint: .isDirectory)
        Library.ensure(cwd)
        var tools: [String] = []
        // The diff is enough to draw the map; the checkout only adds neighbours. Wait for it briefly, never for a clone.
        if let checkout = ensureCheckout(), let dir = await Self.value(of: checkout, within: 1.5) {
            cwd = dir
            tools = ["Read", "Grep", "Glob"]
        }
        if Task.isCancelled { return }
        let options = Claude.Options(model: model, effort: "medium", system: Analyst.mapSystem, schema: Analyst.mapSchema,
                                     tools: tools, cwd: cwd)
        var lastPaint = Date.distantPast
        do {
            for try await event in Claude.run(prompt, options) {
                switch event {
                case .activity(let a):
                    withAnimation(Motion.soft) { activity.append(a) }
                case .structured(let text):
                    // The map draws itself as Claude writes it: layers first, then parts arriving one by one.
                    guard Date().timeIntervalSince(lastPaint) > 0.25 else { continue }
                    lastPaint = Date()
                    if let obj = PartialJSON.parse(text) {
                        let next = SystemMap(J(obj), partial: true)
                        if !next.isEmpty { withAnimation(Motion.soft) { map = next } }
                    }
                case .finished(let f):
                    if f.isError || f.structured == nil {
                        failMap(f.isError ? f.message : "Claude didn't return a map")
                    } else if let data = f.structured {
                        mapJSON = data
                        let next = SystemMap(J(data: data))
                        withAnimation(.smooth(duration: 0.7)) {
                            map = next
                            mapState = .done(Date().timeIntervalSince(started))
                        }
                    }
                default: break
                }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { failMap(error.localizedDescription) }
        }
        if mapState.isRunning && !Task.isCancelled { failMap("Claude stopped before finishing the map") }
        settle()
    }

    /// A map that streamed in part and then failed is taken down, so the failure (and Read again) shows.
    private func failMap(_ message: String) {
        withAnimation(Motion.soft) {
            if mapJSON == nil { map = SystemMap() }
            mapState = .failed(message)
        }
    }

    /// A task's result if it arrives in time, else nil. The task itself keeps running.
    /// (A task group won't do: it waits for every child, and awaiting another task's value ignores cancellation.)
    nonisolated static func value<T: Sendable>(of task: Task<T?, Never>, within seconds: Double) async -> T? {
        await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            let once = Once()
            Task { let v = await task.value; if once.claim() { done.resume(returning: v) } }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { done.resume(returning: nil) }
            }
        }
    }

    /// When both readings are over, keep what came back; a background reading then hands over to the next one.
    private func settle() {
        guard !briefState.isRunning, !mapState.isRunning, !Task.isCancelled else { return }
        if briefJSON != nil || mapJSON != nil { save() }
        if background { onSounded?() }
    }

    private func save() {
        guard let detail else { return }
        var briefSeconds: Double?, mapSeconds: Double?
        if case .done(let s) = briefState { briefSeconds = s }
        if case .done(let s) = mapState { mapSeconds = s }
        Library.saveSounding(Sounding(ref: ref, headSha: detail.headSha, model: model, brief: briefJSON, map: mapJSON,
                                      briefSeconds: briefSeconds, mapSeconds: mapSeconds, createdAt: Date(),
                                      version: Sounding.current))
        soundedAt = Date()
        soundedModel = model
        store?.markSounded(ref, sha: detail.headSha)
        guard !background else { return }
        if store?.ping == true, store?.env["FATHOM_MUTE"] != "1", let sound = NSSound(named: "Submarine") {
            sound.volume = 0.22
            sound.play()
        }
        if NSApp.isActive == false { NSApp.requestUserAttention(.informationalRequest) }
    }

    nonisolated static func colour(_ diff: ParsedDiff) -> [String: AttributedString] {
        var out: [String: AttributedString] = [:]
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
                        Highlighter.mark(&a, spans: s, color: h.lines[i].kind == .add ? Color.added.opacity(0.28) : Color.removed.opacity(0.3))
                    }
                    out["\(h.id):\(i)"] = a
                }
            }
        }
        return out
    }

    // MARK: Derived

    /// Components whose files appear in these hunks.
    func components(forHunks hunks: [String]) -> Set<String> {
        guard let diff else { return [] }
        let paths = Set(hunks.compactMap { diff.file(ofHunk: $0)?.path })
        return components(forPaths: paths)
    }

    func components(forPaths paths: Set<String>) -> Set<String> {
        Set(map.components.filter { c in c.files.contains { f in paths.contains { $0 == f || $0.hasSuffix("/" + f) || f.hasSuffix("/" + $0) } } }.map(\.id))
    }

    /// What the map should light up right now, if anything.
    var litComponents: Set<String>? {
        if let f = playingFlow, map.flows.indices.contains(f) {
            let steps = map.flows[f].steps.prefix(flowStep + 1)
            return Set(steps.flatMap { [$0.from, $0.to] })
        }
        if let f = hoveredFile { return components(forPaths: [f]) }
        return nil
    }

    var isSounding: Bool { briefState.isRunning || mapState.isRunning }

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

    func filter(toComponent id: String) {
        guard let c = map.component(id), let diff else { return }
        let paths = Set(c.files.compactMap { diff.file(path: $0)?.path })
        guard !paths.isEmpty else { return }
        withAnimation(Motion.spring) {
            fileFilter = paths
            filterLabel = c.name
            tab = .changes
        }
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

    func play(_ flow: Int, after delay: Double = 0) {
        flowTimer?.cancel()
        let resume = playingFlow == flow
        withAnimation(Motion.spring) {
            if !resume { flowStep = 0 }
            playingFlow = flow
            selectedComponent = nil
            if panel != .flow(flow) { panel = .flow(flow) }
        }
        // The first pulse waits for the map to settle after the panel opens.
        flowStarted = Date().addingTimeInterval(delay)
        flowRunning = true
        flowTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                guard !Task.isCancelled, let f = playingFlow, map.flows.indices.contains(f) else { return }
                if flowStep + 1 < map.flows[f].steps.count {
                    advanceFlow(1)
                } else {
                    try? await Task.sleep(for: .seconds(1.4))
                    if !Task.isCancelled { withAnimation(Motion.soft) { flowStep = 0 }; flowStarted = Date() }
                }
            }
        }
    }

    func advanceFlow(_ delta: Int) {
        guard let f = playingFlow, map.flows.indices.contains(f) else { return }
        let n = map.flows[f].steps.count
        withAnimation(Motion.soft) { flowStep = (flowStep + delta + n) % n }
        flowStarted = Date()
    }

    func pauseFlow() {
        flowTimer?.cancel()
        flowTimer = nil
        flowRunning = false
    }

    var flowPaused: Bool { playingFlow != nil && !flowRunning }

    func stopFlow() {
        flowTimer?.cancel()
        flowTimer = nil
        flowRunning = false
        withAnimation(Motion.soft) { playingFlow = nil }
    }

    // MARK: The side panel

    enum Panel: Equatable {
        case component(String), edge(String), flow(Int), interfaces, footprint
    }

    var selectedEdge: String? {
        if case .edge(let id) = panel { return id }
        return nil
    }

    /// Opens one connection beside the map: how it's called, what travels, and where in the code.
    func selectEdge(_ id: String) {
        guard map.edge(id) != nil else { return }
        flowTimer?.cancel()
        flowTimer = nil
        flowRunning = false
        withAnimation(Motion.spring) {
            playingFlow = nil
            selectedComponent = nil
            panel = .edge(id)
            tab = .brief
        }
    }

    /// Opens a part's code beside the map.
    func select(_ id: String) {
        guard map.component(id) != nil else { return }
        flowTimer?.cancel()
        flowTimer = nil
        flowRunning = false
        withAnimation(Motion.spring) {
            playingFlow = nil
            selectedComponent = id
            panel = .component(id)
            tab = .brief
        }
    }

    func closePanel() {
        flowTimer?.cancel()
        flowTimer = nil
        flowRunning = false
        withAnimation(Motion.spring) {
            panel = nil
            selectedComponent = nil
            playingFlow = nil
        }
    }

    func toggle(_ p: Panel) {
        if panel == p { closePanel(); return }
        flowTimer?.cancel()
        flowTimer = nil
        flowRunning = false
        withAnimation(Motion.spring) {
            playingFlow = nil
            selectedComponent = nil
            panel = p
        }
    }

    func toggleFlow(_ i: Int) {
        if panel == .flow(i) { closePanel(); return }
        play(i, after: panel == nil ? 0.5 : 0.2)
    }

    func step(_ delta: Int, in flow: Int) {
        if playingFlow != flow { play(flow) }
        pauseFlow()
        advanceFlow(delta)
    }

    func jump(toStep k: Int, in flow: Int) {
        if playingFlow != flow { play(flow) }
        pauseFlow()
        withAnimation(Motion.soft) { flowStep = k }
        flowStarted = Date()
    }

    // MARK: Review comments

    func addComment(path: String, line: Int, side: String, body: String, hunk: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(Motion.spring) {
            pending.append(PendingComment(path: path, line: line, side: side, body: text, hunk: hunk))
            composing = nil
        }
        store?.setPending(ref, pending)
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
            guard !c.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let f = diff.file(path: c.path) else { return false }
            return f.hunks.contains { h in
                h.lines.contains { l in c.side == "LEFT" ? (l.kind == .del && l.old == c.line) : (l.kind != .del && l.new == c.line) }
            }
        }
    }

    func submit(_ verdict: GitHub.Verdict, body: String) {
        guard let detail else { return }
        submitting = true
        submitError = nil
        let comments = sendableComments
        tasks.append(Task {
            do {
                let url = try await GitHub.submitReview(ref, commit: detail.headSha, verdict: verdict, body: body, comments: comments)
                withAnimation(Motion.spring) {
                    submittedURL = url ?? ref.web
                    pending = []
                    submitting = false
                }
                store?.setPending(ref, [])
            } catch {
                submitting = false
                submitError = error.localizedDescription
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
        let prompt = first ? Analyst.askOpening(detail, diff, brief: brief, question: q) : q
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

    /// FATHOM_TAB, FATHOM_FLOW, FATHOM_SELECT, FATHOM_ASK put the window in a given state for screenshots.
    private func applyDemoState() {
        guard let env = store?.env else { return }
        tasks.append(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if env["FATHOM_TAB"] == "changes" { tab = .changes }
            if let era = env["FATHOM_ERA"], let e = Era(rawValue: era) { self.era = e }
            if env["FATHOM_BY_FILE"] == "1" { byFile = true }
            for _ in 0..<600 where map.isEmpty || brief.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let s = env["FATHOM_SELECT"] { select(s) }
            // FATHOM_EDGE=walkmodel>routeplanner opens that connection.
            if let e = env["FATHOM_EDGE"], let edge = map.edges.first(where: { "\($0.from)>\($0.to)" == e }) { selectEdge(edge.id) }
            if let p = env["FATHOM_PANEL"] { toggle(p == "footprint" ? .footprint : .interfaces) }
            if let f = env["FATHOM_FLOW"], let n = Int(f), map.flows.indices.contains(n) {
                toggleFlow(n)
                if let st = env["FATHOM_FLOW_STEP"], let k = Int(st) {
                    try? await Task.sleep(for: .milliseconds(700))
                    jump(toStep: k, in: n)
                }
            }
            if let q = env["FATHOM_ASK"] {
                if q.isEmpty { withAnimation(Motion.spring) { askOpen = true } } else { ask(q) }
            }
            if env["FATHOM_REVIEW"] == "1" { reviewOpen = true }
            if let h = env["FATHOM_GO"] { go(toHunk: h) }
            if let row = env["FATHOM_SCROLL"] {
                withAnimation(Motion.spring) { tab = .changes }
                try? await Task.sleep(for: .milliseconds(300))
                scrollTarget = row
            }
        })
    }
}
