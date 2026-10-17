// Changes: the diff regrouped by meaning. Chapters in reading order, a short note per change, mechanical changes
// set aside, and comments that go straight into your GitHub review.

import SwiftUI

struct ChapterInfo: Identifiable {
    var id: Int
    var number: Int
    var title: String
    var summary: String
    var attention: Attention
    var hunks: [String]
    var additions: Int
    var deletions: Int
    var files: [String]
    var isFile: Bool
}

struct DocRow: Identifiable {
    enum Kind {
        case chapter(ChapterInfo, collapsed: Bool)
        case fileHeader(DiffFile, Hunk)
        case note(String, hunk: String, top: Bool)
        case line(DiffLine, hunk: Hunk, index: Int, file: DiffFile, last: Bool)
        case comment(PendingComment)
        case thread(ReviewThread, hunk: String)
        case composer(Compose)
        case mechanical([DiffFile])
        case hunkEnd
        case finale(done: Int, total: Int)
    }

    let id: String
    let chapter: Int
    let kind: Kind
}

/// The rows of the Changes tab, kept until something they depend on changes — scrolling never rebuilds them.
struct RowsCache {
    var key: Int
    var chapters: [ChapterInfo]
    var rows: [DocRow]
    var chapterOfRow: [String: Int]
    var indexOfRow: [String: Int]
    /// Conversations on each chapter's lines, for the rail.
    var threadsInChapter: [Int: Int]
}

extension PRSession {
    /// Chapters from Claude, or one per file until they arrive (or when reading by file).
    var chapterInfos: [ChapterInfo] {
        guard let diff else { return [] }
        func info(_ id: Int, _ n: Int, _ title: String, _ summary: String, _ att: Attention, _ hunks: [String], isFile: Bool) -> ChapterInfo {
            let hs = hunks.compactMap { diff.hunk($0) }
            let files = hunks.compactMap { diff.file(ofHunk: $0)?.name }.uniqued()
            return ChapterInfo(id: id, number: n, title: title, summary: summary, attention: att, hunks: hunks,
                               additions: hs.reduce(0) { $0 + $1.additions }, deletions: hs.reduce(0) { $0 + $1.deletions },
                               files: files, isFile: isFile)
        }
        if byFile || brief.chapters.isEmpty {
            return diff.signalFiles.enumerated().map { i, f in
                info(1000 + f.index, i + 1, f.name, f.dir, .focus, f.hunks.map(\.id), isFile: true)
            }
        }
        var claimed = Set<String>()
        let valid = brief.chapters.map { c in
            (c, c.hunks.filter { diff.hunk($0) != nil && claimed.insert($0).inserted })
        }
        .filter { !$0.1.isEmpty }
        var out = valid.enumerated().map { i, pair in info(pair.0.id, i + 1, pair.0.title, "", pair.0.attention, pair.1, isFile: false) }
        let covered = Set(out.flatMap(\.hunks))
        let rest = diff.signalFiles.flatMap(\.hunks).map(\.id).filter { !covered.contains($0) }
        if !rest.isEmpty && !briefState.isRunning {
            out.append(info(999, out.count + 1, "Everything else", "", .skim, rest, isFile: false))
        }
        return out
    }

    func changesRows() -> RowsCache {
        // Touch what the rows are built from so the view still updates when it changes.
        _ = brief.kind
        _ = diff?.files.count
        var h = Hasher()
        h.combine(briefVersion)
        h.combine(diff?.files.count ?? -1)
        h.combine(diff?.additions ?? -1)
        h.combine(byFile)
        h.combine(fileFilter?.sorted() ?? [])
        h.combine(expandedSkips.sorted())
        h.combine(compose?.draftKey)
        h.combine(compose?.inPanel)
        h.combine(detail?.threads ?? [])
        h.combine(pending.map(\.id))
        h.combine(pending.map(\.body))
        h.combine(reviewed.sorted())
        h.combine(briefState.isRunning)
        let key = h.finalize()
        if let c = rowsCache, c.key == key { return c }
        let chapters = chapterInfos
        let rows = docRows(chapters)
        var owner: [String: Int] = [:]
        var index: [String: Int] = [:]
        var threads: [Int: Int] = [:]
        for (i, r) in rows.enumerated() {
            owner[r.id] = r.chapter
            index[r.id] = i
            if case .thread = r.kind { threads[r.chapter, default: 0] += 1 }
        }
        let c = RowsCache(key: key, chapters: chapters, rows: rows, chapterOfRow: owner, indexOfRow: index, threadsInChapter: threads)
        rowsCache = c
        return c
    }

    private var notesByHunk: [String: [HunkNote]] {
        var notes: [String: [HunkNote]] = [:]
        for n in brief.notes { notes[n.hunk, default: []].append(n) }
        return notes
    }

    /// Your new comments by line. Replies show inside the thread they answer.
    private var commentsByLine: [String: [PendingComment]] {
        var comments: [String: [PendingComment]] = [:]
        for c in pending where c.replyTo == nil { comments["\(c.path):\(c.side):\(c.line)", default: []].append(c) }
        return comments
    }

    /// Whether any of these hunks has a conversation on GitHub, so its chapter isn't folded away.
    private func hasThreads(_ hunks: [String], _ threads: [String: [ReviewThread]]) -> Bool {
        guard let diff, let all = detail?.threads, !all.isEmpty else { return false }
        return hunks.contains { id in
            guard let h = diff.hunk(id), let f = diff.file(ofHunk: id) else { return false }
            if h.id == f.hunks.first?.id, all.contains(where: { $0.onFile && $0.path == f.path }) { return true }
            return h.lines.contains { l in
                if l.kind == .context, let old = l.old, threads["\(f.path):LEFT:\(old)"] != nil { return true }
                let side = l.kind == .del ? "LEFT" : "RIGHT"
                return (l.kind == .del ? l.old : l.new).map { threads["\(f.path):\(side):\($0)"] != nil } ?? false
            }
        }
    }

    /// One hunk: its file, its note, its lines, and any comments on them.
    private func hunkRows(_ h: Hunk, _ f: DiffFile, chapter: Int, notes: [String: [HunkNote]],
                          comments: [String: [PendingComment]], threads: [String: [ReviewThread]],
                          inPanel: Bool = false) -> [DocRow] {
        var rows: [DocRow] = []
        rows.append(DocRow(id: "hunk:\(h.id)", chapter: chapter, kind: .fileHeader(f, h)))
        // Conversations about the whole file sit under its first change.
        if h.id == f.hunks.first?.id {
            for t in (detail?.threads ?? []) where t.onFile && t.path == f.path {
                rows.append(DocRow(id: "thread:\(t.id)", chapter: chapter, kind: .thread(t, hunk: h.id)))
            }
        }
        let hn = notes[h.id] ?? []
        if let top = hn.first(where: { $0.anchor.isEmpty }) ?? hn.first {
            rows.append(DocRow(id: "note:\(h.id):top", chapter: chapter, kind: .note(top.note, hunk: h.id, top: true)))
        }
        for (i, l) in h.lines.enumerated() {
            rows.append(DocRow(id: "line:\(h.id):\(i)", chapter: chapter,
                               kind: .line(l, hunk: h, index: i, file: f, last: i == h.lines.count - 1)))
            let side = l.kind == .del ? "LEFT" : "RIGHT"
            if let no = l.kind == .del ? l.old : l.new {
                let key = "\(f.path):\(side):\(no)"
                // An unchanged line can carry a thread on either side.
                var here = threads[key] ?? []
                if l.kind == .context, let old = l.old { here += threads["\(f.path):LEFT:\(old)"] ?? [] }
                for t in here {
                    rows.append(DocRow(id: "thread:\(t.id)", chapter: chapter, kind: .thread(t, hunk: h.id)))
                }
                for c in comments[key] ?? [] {
                    rows.append(DocRow(id: "comment:\(c.id)", chapter: chapter, kind: .comment(c)))
                }
                if let c = compose, c.kind == .new, c.key == key, c.inPanel == inPanel {
                    rows.append(DocRow(id: "composer:\(key)", chapter: chapter, kind: .composer(c)))
                }
            }
        }
        rows.append(DocRow(id: "end:\(h.id)", chapter: chapter, kind: .hunkEnd))
        return rows
    }

    func docRows(_ chapters: [ChapterInfo]) -> [DocRow] {
        guard let diff else { return [] }
        let notes = notesByHunk, comments = commentsByLine, threads = threadsByLine
        var rows: [DocRow] = []
        var shown = Set<String>()
        for ch in chapters {
            let hunks = ch.hunks.filter { id in fileFilter.map { f in diff.file(ofHunk: id).map { f.contains($0.path) } ?? false } ?? true }
            if hunks.isEmpty { continue }
            let collapsed = ch.attention == .skip && !expandedSkips.contains(ch.id) && fileFilter == nil
                && !hasThreads(hunks, threads)
            rows.append(DocRow(id: "chapter:\(ch.id)", chapter: ch.id, kind: .chapter(ch, collapsed: collapsed)))
            if collapsed {
                shown.formUnion(hunks)
                continue
            }
            for hid in hunks {
                guard let h = diff.hunk(hid), let f = diff.file(ofHunk: hid), shown.insert(hid).inserted else { continue }
                rows += hunkRows(h, f, chapter: ch.id, notes: notes, comments: comments, threads: threads)
            }
        }
        if fileFilter == nil {
            let noise = diff.files.filter { f in f.noise != nil && !f.hunks.contains { shown.contains($0.id) } }
            if !noise.isEmpty { rows.append(DocRow(id: "mechanical", chapter: -1, kind: .mechanical(noise))) }
            if !chapters.isEmpty && !brief.chapters.isEmpty && !byFile {
                let done = chapters.filter { reviewed.contains($0.id) }.count
                rows.append(DocRow(id: "finale", chapter: -1, kind: .finale(done: done, total: chapters.count)))
            }
        }
        return rows
    }

    /// One hunk's rows, for the story's "Where to look" page.
    func lookRows(_ hunk: String) -> [DocRow] {
        guard let diff, let h = diff.hunk(hunk), let f = diff.file(ofHunk: hunk) else { return [] }
        return hunkRows(h, f, chapter: -2, notes: notesByHunk, comments: commentsByLine, threads: threadsByLine, inPanel: true)
    }
}

/// A jump through the diff, from a key, the rail, or the story.
struct DiffJump: Equatable {
    var id: String
    var animated = false
    var tick = UUID()
}

struct ChangesView: View {
    @Bindable var session: PRSession
    @State private var topRow: String?
    @State private var jump: DiffJump?
    @State private var flash: String?
    @FocusState private var keys: Bool

    var body: some View {
        let cache = session.changesRows()
        HStack(alignment: .top, spacing: 14) {
            ChapterRail(session: session, chapters: cache.chapters, chapterOfRow: cache.chapterOfRow,
                        threads: cache.threadsInChapter, topRow: $topRow) { id in
                jump = DiffJump(id: "chapter:\(id)")
            }
            .frame(width: 262)
            .padding(.bottom, 16)

            DiffList(session: session, rows: cache.rows, index: cache.indexOfRow, topRow: $topRow, jump: jump)
                .overlay(alignment: .top) {
                    if session.fileFilter != nil {
                        FilterBanner(label: session.filterLabel) { session.clearFilter() }
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
        .padding(.leading, 18)
        .focusable()
        .focusEffectDisabled()
        .focused($keys)
        .onKeyPress(characters: CharacterSet(charactersIn: "jknpx"), phases: .down) { press in
            // Letters typed into a comment box are words, not jumps.
            guard !Typing.active, press.modifiers.isEmpty else { return .ignored }
            let rows = cache.rows
            let here = topRow.flatMap { cache.indexOfRow[$0] } ?? 0
            func move(_ prefix: String, forward: Bool) {
                let target = forward
                    ? rows[min(here + 1, rows.count)...].firstIndex { $0.id.hasPrefix(prefix) }
                    : rows[..<here].lastIndex { $0.id.hasPrefix(prefix) }
                guard let t = target else { return }
                // A short, even glide when the target is near; a long one through rows the list hasn't laid out
                // yet lurches, so far jumps cut straight there.
                jump = DiffJump(id: rows[t].id, animated: abs(t - here) < 60)
            }
            switch press.characters {
            case "j": move("hunk:", forward: true)
            case "k": move("hunk:", forward: false)
            case "n": move("chapter:", forward: true)
            case "p": move("chapter:", forward: false)
            case "x": if let c = cache.chapterOfRow[topRow ?? ""], c >= 0 { session.toggleReviewed(c) }
            default: return .ignored
            }
            return .handled
        }
        .onChange(of: session.tab) { _, tab in keys = tab == .changes }
        // When a comment box closes, the keys come back to the diff.
        .onChange(of: session.compose == nil) { _, closed in if closed && session.tab == .changes { keys = true } }
        .onChange(of: session.scrollTarget) { _, target in
            guard let target else { return }
            jump = DiffJump(id: target)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                session.scrollTarget = nil
                flash = target
                try? await Task.sleep(for: .seconds(1.6))
                if flash == target { withAnimation(Motion.slow) { flash = nil } }
            }
        }
        .environment(\.flashRow, flash)
        .onAppear {
            if let t = session.scrollTarget { jump = DiffJump(id: t) }
            keys = session.tab == .changes
        }
    }
}

/// The diff itself. It only hands its scroll position up, so scrolling doesn't redraw anything else.
struct DiffList: View {
    @Bindable var session: PRSession
    let rows: [DocRow]
    let index: [String: Int]
    @Binding var topRow: String?
    let jump: DiffJump?
    @State private var settling: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DocRowView(session: session, row: row)
                            .id(row.id)
                    }
                    Color.clear.frame(height: 120)
                }
                .scrollTargetLayout()
                .padding(.trailing, 20)
            }
            // Where you are is the first row on screen, whichever way you got there; jumps go through the proxy,
            // which finds rows the lazy list hasn't laid out yet.
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.25) { ids in
                let first = ids.min { (index[$0] ?? .max) < (index[$1] ?? .max) }
                if let first, first != topRow { topRow = first }
            }
            .scrollIndicators(.automatic)
            .onChange(of: jump) { _, j in
                guard let j else { return }
                settling = j.tick
                if j.animated {
                    withAnimation(.smooth(duration: 0.24)) { proxy.scrollTo(j.id, anchor: .top) }
                } else {
                    proxy.scrollTo(j.id, anchor: .top)
                }
                // A far jump lands by estimated row heights; once the rows there are laid out, settle exactly.
                Task { @MainActor in
                    for wait in j.animated ? [300] : [70, 220] {
                        try? await Task.sleep(for: .milliseconds(wait))
                        guard settling == j.tick else { return }
                        proxy.scrollTo(j.id, anchor: .top)
                    }
                }
            }
            .onAppear {
                if let j = jump { proxy.scrollTo(j.id, anchor: .top) }
            }
        }
    }
}

/// The bottom of the diff: how much is understood, and the way to the review.
struct Finale: View {
    @Bindable var session: PRSession
    let done: Int
    let total: Int

    var body: some View {
        let all = done == total
        VStack(spacing: 12) {
            Image(systemName: all ? "checkmark.seal.fill" : "water.waves")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(all ? Color.added : Color.sonar.opacity(0.7))
                .symbolEffect(.bounce, value: all)
            Text(all ? "That's the whole change." : "End of the diff")
                .font(.serif(21))
                .foregroundStyle(Color.text1)
            Text("\(done) of \(total) understood")
                .font(.system(size: 12))
                .foregroundStyle(Color.text3)
                .monospacedDigit()
            Button {
                session.reviewOpen = true
            } label: {
                Text(session.pending.isEmpty ? "Write your review" : "Review \(session.pending.count) comment\(session.pending.count == 1 ? "" : "s")")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(all ? Color(hex: 0x2E7D4F) : Color(hex: 0x1F6F6B))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.top, 20)
        .animation(Motion.spring, value: all)
    }
}

private struct FlashKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var flashRow: String? {
        get { self[FlashKey.self] }
        set { self[FlashKey.self] = newValue }
    }
}

struct FilterBanner: View {
    let label: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Only \(label)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.text1)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.text3)
            }
            .buttonStyle(.plain)
            .help("Show every change (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular.tint(Color.cardTint), in: .capsule)
    }
}

// MARK: - Rail

struct ChapterRail: View {
    @Bindable var session: PRSession
    let chapters: [ChapterInfo]
    let chapterOfRow: [String: Int]
    let threads: [Int: Int]
    @Binding var topRow: String?
    let jump: (Int) -> Void

    var body: some View {
        let current = chapterOfRow[topRow ?? ""]
        let byMeaning = !session.byFile && !session.brief.chapters.isEmpty
        let done = chapters.filter { session.reviewed.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Eyebrow(byMeaning ? "Chapters" : "Files")
                if byMeaning {
                    Text("\(done)/\(chapters.count)")
                        .font(.mono(10, .semibold))
                        .foregroundStyle(done == chapters.count ? Color.added : Color.text3)
                        .contentTransition(.numericText())
                }
                Spacer()
                if !session.brief.chapters.isEmpty {
                    Button {
                        withAnimation(Motion.spring) { session.byFile.toggle() }
                    } label: {
                        Image(systemName: session.byFile ? "list.bullet.indent" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.text3)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(session.byFile ? "Read by meaning, in chapters" : "Read file by file")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if byMeaning {
                ReadingBar(session: session)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else if session.briefState.isRunning {
                HStack(spacing: 7) {
                    SonarPip().frame(width: 12, height: 12)
                    Text("Grouping by meaning…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.text3)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chapters) { ch in
                        RailRow(session: session, chapter: ch, current: current == ch.id, threads: threads[ch.id] ?? 0) { jump(ch.id) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)

            ConversationNote(session: session, threads: threads.values.reduce(0, +))
        }
        .background(Surface(radius: 20))
        .animation(Motion.spring, value: chapters.map(\.id))
    }
}

/// Under the chapters: how many conversations there are on GitHub, and the ones on lines that have since changed.
struct ConversationNote: View {
    @Bindable var session: PRSession
    let threads: Int

    var body: some View {
        let outdated = max((session.detail?.threads.count ?? 0) - threads, 0)
        let yours = session.pending.count
        if threads + outdated + yours > 0 {
            VStack(alignment: .leading, spacing: 6) {
                if threads > 0 {
                    label("bubble.left.and.bubble.right", "\(threads) conversation\(threads == 1 ? "" : "s") on these lines", .calm)
                }
                if outdated > 0 {
                    Button {
                        NSWorkspace.shared.open(session.ref.web.appending(path: "files"))
                    } label: {
                        label("clock.arrow.circlepath", "\(outdated) more on GitHub, not on lines shown here", .text3, link: true, away: true)
                    }
                    .buttonStyle(.plain)
                    .help("Read these on GitHub")
                }
                if yours > 0 {
                    Button { session.reviewOpen = true } label: {
                        label("text.bubble", "\(yours) of yours waiting to be sent", .sonar, link: true)
                    }
                    .buttonStyle(.plain)
                    .help("Open your review (⌘↩)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Color.hair).frame(height: 0.5) }
        }
    }

    private func label(_ icon: String, _ text: String, _ tint: Color, link: Bool = false, away: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).frame(width: 14)
            Text(text).font(.system(size: 11.5)).foregroundStyle(link ? Color.text2 : Color.text3)
            if away { Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.text3) }
        }
        .contentShape(Rectangle())
    }
}

/// Where the lines are: read, skim, or skip.
struct ReadingBar: View {
    let session: PRSession

    var body: some View {
        let r = session.reading
        let total = CGFloat(max(r.focus + r.skim + r.skip, 1))
        GeometryReader { geo in
            HStack(spacing: 2) {
                Capsule().fill(Color.sonar).frame(width: max(2, geo.size.width * CGFloat(r.focus) / total))
                Capsule().fill(Color.sonar.opacity(0.35)).frame(width: max(2, geo.size.width * CGFloat(r.skim) / total))
                Capsule().fill(Color.white.opacity(0.1))
            }
        }
        .frame(height: 4)
        .help("\(r.focus) lines to read · \(r.skim) to skim · \(r.skip) set aside")
    }
}

struct RailRow: View {
    @Bindable var session: PRSession
    let chapter: ChapterInfo
    let current: Bool
    var threads = 0
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let done = session.reviewed.contains(chapter.id)
        HStack(alignment: .center, spacing: 9) {
            Button {
                session.toggleReviewed(chapter.id)
            } label: {
                ZStack {
                    Circle().strokeBorder(done ? Color.added : Color.white.opacity(0.18), lineWidth: 1.2)
                    if done {
                        Circle().fill(Color.added)
                        Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Color.ink)
                    }
                }
                .frame(width: 15, height: 15)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(done ? "Mark as not yet understood" : "Mark as understood (X)")

            Text(chapter.title)
                .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .foregroundStyle(done ? Color.text3 : current ? Color.text1 : Color.text1.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if threads > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.fill").font(.system(size: 8.5))
                    Text("\(threads)").font(.mono(10, .semibold))
                }
                .foregroundStyle(Color.calm)
                .help("\(threads) conversation\(threads == 1 ? "" : "s") on GitHub")
            }
            if !chapter.isFile { AttentionDot(attention: chapter.attention) }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(current ? 0.07 : hover ? 0.035 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = QA.hover($0) }
        .help(chapter.isFile ? chapter.summary : "\(chapter.attention.word) · +\(chapter.additions) −\(chapter.deletions)")
        .animation(Motion.snappy, value: current)
    }
}

/// Read is a full dot, skim a ring, skip a dim dot.
struct AttentionDot: View {
    let attention: Attention

    var body: some View {
        Group {
            switch attention {
            case .focus: Circle().fill(Color.sonar)
            case .skim: Circle().strokeBorder(Color.sonar.opacity(0.8), lineWidth: 1.2)
            case .skip: Circle().fill(Color.text3.opacity(0.5))
            }
        }
        .frame(width: 6, height: 6)
    }
}

struct AttentionTag: View {
    let attention: Attention

    var body: some View {
        HStack(spacing: 5) {
            AttentionDot(attention: attention)
            Text(attention.word)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
        }
        .foregroundStyle(attention == .skip ? Color.text3 : Color.sonar.opacity(attention == .focus ? 1 : 0.7))
    }
}

// MARK: - Rows

struct DocRowView: View {
    @Bindable var session: PRSession
    let row: DocRow
    @Environment(\.flashRow) private var flash
    @Environment(\.inPanel) private var inPanel

    var body: some View {
        switch row.kind {
        case .chapter(let ch, let collapsed):
            ChapterHeader(session: session, chapter: ch, collapsed: collapsed)
        case .fileHeader(let f, let h):
            FileHeader(file: f, hunk: h, ref: session.ref, head: session.detail?.headSha)
            .overlay { flashOverlay("hunk:\(h.id)") }
            .contextMenu {
                Button("Ask Claude about this change") {
                    session.ask("Explain the change in \(f.path) around line \(h.newStart) (hunk \(h.id)): what it does, why, and what it affects.")
                }
                Button("Comment on the first changed line") {
                    if let l = h.lines.first(where: { $0.kind != .context }) {
                        session.startComposing(Compose(kind: .new, path: f.path, line: (l.kind == .del ? l.old : l.new) ?? h.newStart,
                                                       side: l.kind == .del ? "LEFT" : "RIGHT", hunk: h.id, inPanel: inPanel))
                    }
                }
                Divider()
                Button("Open on GitHub") {
                    if let sha = session.detail?.headSha,
                       let url = URL(string: "https://github.com/\(session.ref.slug)/blob/\(sha)/\(f.path)#L\(h.newStart)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(f.path, forType: .string)
                }
            }
        case .note(let text, _, let top):
            NoteRow(text: text, top: top)
        case .line(let l, let h, let i, let f, let last):
            LineRow(session: session, line: l, hunk: h, index: i, file: f, last: last,
                    text: session.lines["\(h.id):\(i)"] ?? Highlighter.plain(l.text))
                .overlay { flashOverlay("line:\(h.id):\(i)") }
        case .comment(let c):
            CommentRow(session: session, comment: c)
        case .thread(let t, let hunk):
            ThreadView(session: session, thread: t, hunk: hunk)
        case .composer(let c):
            InDiff { Composer(session: session, compose: c) }
        case .mechanical(let files):
            MechanicalRow(files: files)
        case .hunkEnd:
            Color.clear.frame(height: 12)
        case .finale(let done, let total):
            Finale(session: session, done: done, total: total)
        }
    }

    @ViewBuilder private func flashOverlay(_ id: String) -> some View {
        if flash == id {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.sonar.opacity(0.14))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

struct ChapterHeader: View {
    @Bindable var session: PRSession
    let chapter: ChapterInfo
    let collapsed: Bool
    @State private var hover = false

    var body: some View {
        let done = session.reviewed.contains(chapter.id)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%02d", chapter.number))
                    .font(.mono(11, .semibold))
                    .foregroundStyle(Color.text3.opacity(0.7))
                Text(chapter.title)
                    .font(chapter.isFile ? .system(size: 17, weight: .semibold, design: .monospaced) : .serif(22))
                    .tracking(chapter.isFile ? 0 : -0.2)
                    .foregroundStyle(collapsed ? Color.text2 : Color.text1)
                Spacer()
                Button {
                    session.toggleReviewed(chapter.id)
                } label: {
                    HStack(spacing: 5) {
                        if hover || done {
                            Text(done ? "Understood" : "Mark understood")
                                .transition(.opacity)
                        }
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(done ? Color.added : Color.text3)
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(Motion.snappy) { hover = QA.hover(h) } }
                .help("Mark this chapter understood (X)")
            }
            HStack(spacing: 9) {
                if !chapter.isFile { AttentionTag(attention: chapter.attention) }
                Text(chapter.isFile ? chapter.summary : "\(chapter.hunks.count) change\(chapter.hunks.count == 1 ? "" : "s")")
                DiffStat(additions: chapter.additions, deletions: chapter.deletions, bar: false, size: 10.5)
                if collapsed {
                    Spacer()
                    Button {
                        withAnimation(Motion.spring) { _ = session.expandedSkips.insert(chapter.id) }
                    } label: {
                        Label("Show anyway", systemImage: "chevron.down")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.text3)
        }
        .padding(.top, chapter.number == 1 ? 14 : 40)
        .padding(.bottom, collapsed ? 4 : 14)
        .opacity(done && !collapsed ? 0.85 : 1)
    }
}

struct FileHeader: View {
    let file: DiffFile
    let hunk: Hunk
    let ref: PRRef
    let head: String?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(Text(file.dir).foregroundStyle(Color.text3))\(Text(file.name).foregroundStyle(Color.text1).bold())")
                .font(.mono(11.5))
                .lineLimit(1)
                .truncationMode(.head)
                .help(hunk.section.isEmpty ? file.path : "\(file.path)\n\(hunk.section)")
            if file.status == .added || file.status == .deleted || file.status == .renamed {
                Text(file.status == .added ? "new" : file.status == .deleted ? "deleted" : "renamed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(file.status == .added ? Color.added : file.status == .deleted ? Color.removed : Color.calm)
            }
            Spacer(minLength: 8)
            Text("L\(hunk.newStart)")
                .font(.mono(10.5))
                .foregroundStyle(Color.text3.opacity(0.7))
            Button {
                var url = ref.web.appending(path: "files")
                if let head { url = URL(string: "https://github.com/\(ref.slug)/blob/\(head)/\(file.path)#L\(hunk.newStart)") ?? url }
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.text3)
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .help("Open this file on GitHub")
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 0.5) }
        .onHover { hover = QA.hover($0) }
    }
}

struct NoteRow: View {
    let text: String
    let top: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.sonar.opacity(0.6))
            Text(md(text, base: Color.sonar.opacity(0.8), code: Color.sonar, size: 11.5))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, top ? 14 : 108)
        .padding(.trailing, 14)
        .padding(.vertical, top ? 8 : 5)
        .background(Color.white.opacity(0.03))
        .background(alignment: .leading) {
            if !top {
                Rectangle().fill(Color.sonar.opacity(0.06))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.sonar.opacity(0.6)).frame(width: 2) }
                    .padding(.leading, 94)
            }
        }
    }
}

struct LineRow: View {
    @Bindable var session: PRSession
    @Environment(\.inPanel) private var inPanel
    let line: DiffLine
    let hunk: Hunk
    let index: Int
    let file: DiffFile
    let last: Bool
    let text: AttributedString
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The gutter. A click on the line numbers starts a comment, as on GitHub.
            HStack(spacing: 0) {
                Text(line.old.map(String.init) ?? "")
                    .frame(width: 42, alignment: .trailing)
                Text(line.new.map(String.init) ?? "")
                    .frame(width: 42, alignment: .trailing)
            }
            .foregroundStyle(Color.text3.opacity(hover ? 0.95 : 0.5))
            .contentShape(Rectangle())
            .onTapGesture(perform: comment)
            ZStack {
                if hover {
                    Button(action: comment) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Color.ink)
                            .frame(width: 16, height: 16)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.sonar))
                    }
                    .buttonStyle(.plain)
                    .help("Comment on this line")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Text(sign).foregroundStyle(signColor)
                }
            }
            .frame(width: 24)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 14)
        }
        .font(.mono(12))
        .lineSpacing(2)
        .padding(.vertical, 1.5)
        .background(rowFill)
        .background(Color.white.opacity(0.03))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: last ? 12 : 0, bottomTrailingRadius: last ? 12 : 0, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = QA.hover(h) } }
    }

    private func comment() {
        let side = line.kind == .del ? "LEFT" : "RIGHT"
        let no = (line.kind == .del ? line.old : line.new) ?? 0
        session.startComposing(Compose(kind: .new, path: file.path, line: no, side: side, hunk: hunk.id, inPanel: inPanel))
    }

    private var sign: String {
        switch line.kind {
        case .add: "+"
        case .del: "−"
        default: ""
        }
    }

    private var signColor: Color {
        line.kind == .add ? Color.added : Color.removed
    }

    private var rowFill: Color {
        switch line.kind {
        case .add: Color.added.opacity(hover ? 0.13 : 0.085)
        case .del: Color.removed.opacity(hover ? 0.13 : 0.085)
        default: Color.white.opacity(hover ? 0.03 : 0)
        }
    }
}

/// Something set into the diff between two lines: lined up with the code, on the hunk's own ground, and no wider
/// than reads comfortably.
struct InDiff<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 108)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.03))
    }
}

/// One of your comments, waiting to go out with the review. Click Edit to change it where it is.
struct CommentRow: View {
    @Bindable var session: PRSession
    let comment: PendingComment
    @Environment(\.inPanel) private var inPanel

    var body: some View {
        InDiff {
            if let c = session.compose, c.kind == .edit(comment.id), c.inPanel == inPanel {
                Composer(session: session, compose: c, initial: comment.body)
            } else {
                PendingCard(session: session, comment: comment)
            }
        }
    }
}

struct PendingCard: View {
    @Bindable var session: PRSession
    let comment: PendingComment
    @Environment(\.inPanel) private var inPanel
    @State private var hover = false

    var body: some View {
        CommentBubble(author: session.store?.viewer?.login ?? "You", avatar: session.store?.viewer?.avatar,
                      date: nil, text: comment.body, tag: "Pending", tagTint: .sonar, plain: true) {
            HStack(spacing: 12) {
                Button("Edit") {
                    session.startComposing(Compose(kind: .edit(comment.id), path: comment.path, line: comment.line,
                                                   side: comment.side, hunk: comment.hunk, inPanel: inPanel))
                }
                Button("Delete") { session.removeComment(comment.id) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.text3)
            .opacity(hover ? 1 : 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.sonar.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.sonar.opacity(0.22), lineWidth: 0.75))
        .onHover { hover = QA.hover($0) }
    }
}

/// A conversation from GitHub on this line: everyone's comments in order, your replies waiting to go, and a way
/// to answer. Resolved ones fold to a single line.
struct ThreadView: View {
    @Bindable var session: PRSession
    let thread: ReviewThread
    let hunk: String
    @Environment(\.inPanel) private var inPanel

    var body: some View {
        InDiff {
            let open = !thread.isResolved || session.openThreads.contains(thread.id)
            VStack(alignment: .leading, spacing: 0) {
                if open {
                    ForEach(Array(thread.comments.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Rectangle().fill(Color.hair).frame(height: 0.5).padding(.leading, 44) }
                        CommentBubble(author: c.displayName, avatar: c.avatar, date: c.createdAt, text: c.body,
                                      tag: c.isBot ? "Bot" : nil, tagTint: .calm, link: c.url)
                            .padding(12)
                    }
                    ForEach(replies) { r in
                        Rectangle().fill(Color.hair).frame(height: 0.5).padding(.leading, 44)
                        if let c = session.compose, c.kind == .edit(r.id), c.inPanel == inPanel {
                            Composer(session: session, compose: c, initial: r.body).padding(8)
                        } else {
                            PendingCard(session: session, comment: r).padding(8)
                        }
                    }
                    footer
                } else {
                    folded
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x0D1218)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var replies: [PendingComment] {
        session.pending.filter { $0.replyTo != nil && $0.replyTo == thread.replyTo }
    }

    @ViewBuilder private var footer: some View {
        if let c = session.compose, case .reply = c.kind, c.thread == thread.id, c.inPanel == inPanel {
            Composer(session: session, compose: c)
                .padding(8)
                .overlay(alignment: .top) { Rectangle().fill(Color.hair).frame(height: 0.5) }
        } else {
            HStack(spacing: 14) {
                if let to = thread.replyTo, let line = thread.line {
                    Button {
                        session.startComposing(Compose(kind: .reply(to), path: thread.path, line: line, side: thread.side,
                                                       hunk: hunk, thread: thread.id, inPanel: inPanel))
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                }
                Spacer()
                if thread.isResolved {
                    Button {
                        withAnimation(Motion.snappy) { _ = session.openThreads.remove(thread.id) }
                    } label: {
                        Label("Resolved", systemImage: "checkmark.circle")
                    }
                    .help("Fold this conversation")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.text3)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.02))
            .overlay(alignment: .top) { Rectangle().fill(Color.hair).frame(height: 0.5) }
        }
    }

    private var folded: some View {
        Button {
            withAnimation(Motion.snappy) { _ = session.openThreads.insert(thread.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.added.opacity(0.8))
                Text("Resolved")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.text2)
                if let first = thread.comments.first {
                    Avatar(url: first.avatar, name: first.author, size: 15)
                    Text(GHText.firstLine(first.body))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(thread.comments.count)")
                    .font(.mono(10.5, .semibold))
                    .foregroundStyle(Color.text3)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.text3)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this resolved conversation")
    }
}

/// A comment as people read them: who, when, and what they said, with long ones folded.
struct CommentBubble<Actions: View>: View {
    let author: String
    let avatar: URL?
    let date: Date?
    let text: String
    var tag: String? = nil
    var tagTint: Color = .text3
    var link: URL? = nil
    /// Your own words go in as written; GitHub's arrive with HTML and folded extras to tidy.
    var plain = false
    let actions: Actions
    @State private var more = false
    @State private var hover = false

    init(author: String, avatar: URL?, date: Date?, text: String, tag: String? = nil, tagTint: Color = .text3,
         link: URL? = nil, plain: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.author = author
        self.avatar = avatar
        self.date = date
        self.text = text
        self.tag = tag
        self.tagTint = tagTint
        self.link = link
        self.plain = plain
        self.actions = actions()
    }

    var body: some View {
        let clean = plain ? text : GHText.clean(text)
        let short = GHText.short(clean)
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: avatar, name: author, size: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(author)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.text1)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tagTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tagTint.opacity(0.12)))
                    }
                    if let date {
                        Text(Fmt.ago(date))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.text3)
                    }
                    Spacer(minLength: 8)
                    actions
                    if let link {
                        Button { NSWorkspace.shared.open(link) } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.text3)
                        }
                        .buttonStyle(.plain)
                        .opacity(hover ? 1 : 0)
                        .help("Open on GitHub")
                    }
                }
                MarkdownText(text: more || short == nil ? clean : short ?? clean)
                    .foregroundStyle(Color.text1.opacity(0.92))
                if short != nil {
                    Button(more ? "Show less" : "Show more") {
                        withAnimation(Motion.snappy) { more.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.calm)
                }
            }
        }
        .onHover { hover = QA.hover($0) }
    }
}

extension CommentBubble where Actions == EmptyView {
    init(author: String, avatar: URL?, date: Date?, text: String, tag: String? = nil, tagTint: Color = .text3, link: URL? = nil) {
        self.init(author: author, avatar: avatar, date: date, text: text, tag: tag, tagTint: tagTint, link: link, actions: { EmptyView() })
    }
}

/// The comment box, for a new comment, a reply, or an edit. What you type is kept if the box scrolls away or you
/// press Esc; Cancel throws it away.
struct Composer: View {
    @Bindable var session: PRSession
    let compose: Compose
    var initial = ""
    @FocusState private var focused: Bool

    var body: some View {
        let text = session.draft(compose.draftKey, initial: initial)
        let empty = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Avatar(url: session.store?.viewer?.avatar, name: session.store?.viewer?.login ?? "you", size: 18)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.text1)
                Text(place)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let original = lineText {
                    Button {
                        let block = "```suggestion\n\(original)\n```"
                        text.wrappedValue += (text.wrappedValue.isEmpty ? "" : "\n\n") + block + "\n"
                        focused = true
                    } label: {
                        Label("Suggest a change", systemImage: "plus.forwardslash.minus")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.text2)
                    }
                    .buttonStyle(.plain)
                    .help("Propose new text for this line; the author can apply it on GitHub")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.text3)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
            }
            .frame(minHeight: 66, maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)

            HStack(spacing: 10) {
                Text("Markdown works · ⌘↩ \(verb) · Esc to close")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.text3.opacity(0.8))
                Spacer()
                Button("Cancel") { session.cancelCompose() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.text2)
                    .padding(.horizontal, 4)
                Button { session.commitCompose() } label: {
                    Text(submit)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(Color(hex: 0x1F6F6B))
                .controlSize(.small)
                .disabled(empty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.025))
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x0E141B)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.sonar.opacity(focused ? 0.5 : 0.22), lineWidth: focused ? 1 : 0.75))
        .animation(Motion.snappy, value: focused)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                focused = true
            }
        }
    }

    private var title: String {
        switch compose.kind {
        case .new: "Comment"
        case .reply: "Reply"
        case .edit: "Edit your comment"
        }
    }

    private var place: String {
        let name = (compose.path as NSString).lastPathComponent
        return "\(compose.side == "LEFT" ? "removed line" : "line") \(compose.line) · \(name)"
    }

    private var placeholder: String {
        switch compose.kind {
        case .reply: "Reply to the thread…"
        default: "What should the author know about this line?"
        }
    }

    private var submit: String {
        switch compose.kind {
        case .new: "Add to review"
        case .reply: "Add reply"
        case .edit: "Save"
        }
    }

    private var verb: String {
        switch compose.kind {
        case .edit: "to save"
        default: "to add"
        }
    }

    /// The line as it is now, for a suggested change. GitHub only takes suggestions on the new side.
    private var lineText: String? {
        if case .edit = compose.kind { return nil }
        guard compose.side == "RIGHT" else { return nil }
        return session.diff?.hunk(compose.hunk)?.lines.first { $0.kind != .del && $0.new == compose.line }?.text
    }
}

struct MechanicalRow: View {
    let files: [DiffFile]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.text3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set aside")
                        .font(.serif(19))
                        .foregroundStyle(Color.text2)
                    Text("\(files.count) mechanical file\(files.count == 1 ? "" : "s") — " + Set(files.compactMap { $0.noise?.word }).sorted().joined(separator: ", "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.text3)
                }
                Spacer()
                Button(open ? "Hide" : "List") { withAnimation(Motion.spring) { open.toggle() } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { f in
                        HStack(spacing: 8) {
                            Text(f.path).font(.mono(11)).foregroundStyle(Color.text2).lineLimit(1).truncationMode(.head)
                            Text(f.noise?.word ?? "").font(.system(size: 10.5)).foregroundStyle(Color.text3)
                            Spacer()
                            DiffStat(additions: f.additions, deletions: f.deletions, bar: false, size: 10)
                        }
                    }
                }
                .padding(.leading, 24)
                .transition(.opacity)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4])))
        .padding(.top, 36)
    }
}
