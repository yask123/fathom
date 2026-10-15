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
        case composer(key: String, path: String, line: Int, side: String, hunk: String)
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
        h.combine(composing)
        h.combine(composingInPanel)
        h.combine(pending.map(\.id))
        h.combine(pending.map(\.body))
        h.combine(reviewed.sorted())
        h.combine(briefState.isRunning)
        let key = h.finalize()
        if let c = rowsCache, c.key == key { return c }
        let chapters = chapterInfos
        let rows = docRows(chapters)
        var owner: [String: Int] = [:]
        for r in rows { owner[r.id] = r.chapter }
        let c = RowsCache(key: key, chapters: chapters, rows: rows, chapterOfRow: owner)
        rowsCache = c
        return c
    }

    private var notesByHunk: [String: [HunkNote]] {
        var notes: [String: [HunkNote]] = [:]
        for n in brief.notes { notes[n.hunk, default: []].append(n) }
        return notes
    }

    private var commentsByLine: [String: [PendingComment]] {
        var comments: [String: [PendingComment]] = [:]
        for c in pending { comments["\(c.path):\(c.side):\(c.line)", default: []].append(c) }
        return comments
    }

    /// One hunk: its file, its note, its lines, and any comments on them.
    private func hunkRows(_ h: Hunk, _ f: DiffFile, chapter: Int, notes: [String: [HunkNote]],
                          comments: [String: [PendingComment]], inPanel: Bool = false) -> [DocRow] {
        var rows: [DocRow] = []
        rows.append(DocRow(id: "hunk:\(h.id)", chapter: chapter, kind: .fileHeader(f, h)))
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
                for c in comments[key] ?? [] {
                    rows.append(DocRow(id: "comment:\(c.id)", chapter: chapter, kind: .comment(c)))
                }
                if composing == key && composingInPanel == inPanel {
                    rows.append(DocRow(id: "composer:\(key)", chapter: chapter,
                                       kind: .composer(key: key, path: f.path, line: no, side: side, hunk: h.id)))
                }
            }
        }
        rows.append(DocRow(id: "end:\(h.id)", chapter: chapter, kind: .hunkEnd))
        return rows
    }

    func docRows(_ chapters: [ChapterInfo]) -> [DocRow] {
        guard let diff else { return [] }
        let notes = notesByHunk, comments = commentsByLine
        var rows: [DocRow] = []
        var shown = Set<String>()
        for ch in chapters {
            let hunks = ch.hunks.filter { id in fileFilter.map { f in diff.file(ofHunk: id).map { f.contains($0.path) } ?? false } ?? true }
            if hunks.isEmpty { continue }
            let collapsed = ch.attention == .skip && !expandedSkips.contains(ch.id) && fileFilter == nil
            rows.append(DocRow(id: "chapter:\(ch.id)", chapter: ch.id, kind: .chapter(ch, collapsed: collapsed)))
            if collapsed {
                shown.formUnion(hunks)
                continue
            }
            for hid in hunks {
                guard let h = diff.hunk(hid), let f = diff.file(ofHunk: hid), shown.insert(hid).inserted else { continue }
                rows += hunkRows(h, f, chapter: ch.id, notes: notes, comments: comments)
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
        return hunkRows(h, f, chapter: -2, notes: notesByHunk, comments: commentsByLine, inPanel: true)
    }
}

struct ChangesView: View {
    @Bindable var session: PRSession
    @State private var topRow: String?
    @State private var flash: String?
    @FocusState private var keys: Bool

    var body: some View {
        let cache = session.changesRows()
        HStack(alignment: .top, spacing: 14) {
            ChapterRail(session: session, chapters: cache.chapters, chapterOfRow: cache.chapterOfRow, topRow: $topRow) { id in
                withAnimation(Motion.spring) { topRow = "chapter:\(id)" }
            }
            .frame(width: 262)
            .padding(.bottom, 16)

            DiffList(session: session, rows: cache.rows, topRow: $topRow)
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
            guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            let rows = cache.rows
            let here = rows.firstIndex { $0.id == topRow } ?? 0
            func jump(_ prefix: String, forward: Bool) {
                let target = forward
                    ? rows[min(here + 1, rows.count)...].first { $0.id.hasPrefix(prefix) }
                    : rows[..<here].last { $0.id.hasPrefix(prefix) }
                if let t = target { withAnimation(Motion.spring) { topRow = t.id } }
            }
            switch press.characters {
            case "j": jump("hunk:", forward: true)
            case "k": jump("hunk:", forward: false)
            case "n": jump("chapter:", forward: true)
            case "p": jump("chapter:", forward: false)
            case "x": if let c = cache.chapterOfRow[topRow ?? ""], c >= 0 { session.toggleReviewed(c) }
            default: return .ignored
            }
            return .handled
        }
        .onChange(of: session.tab) { _, tab in keys = tab == .changes }
        .onChange(of: session.scrollTarget) { _, target in
            guard let target else { return }
            withAnimation(Motion.spring) { topRow = target }
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
            if let t = session.scrollTarget { topRow = t }
            keys = session.tab == .changes
        }
    }
}

/// The diff itself. It only hands its scroll position up, so scrolling doesn't redraw anything else.
struct DiffList: View {
    @Bindable var session: PRSession
    let rows: [DocRow]
    @Binding var topRow: String?

    var body: some View {
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
        .scrollPosition(id: $topRow, anchor: .top)
        .scrollIndicators(.automatic)
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
                        RailRow(session: session, chapter: ch, current: current == ch.id) { jump(ch.id) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
        .background(Surface(radius: 20))
        .animation(Motion.spring, value: chapters.map(\.id))
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
                        let side = l.kind == .del ? "LEFT" : "RIGHT"
                        session.composingInPanel = inPanel
                        session.composing = "\(f.path):\(side):\((l.kind == .del ? l.old : l.new) ?? h.newStart)"
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
        case .composer(let key, let path, let line, let side, let hunk):
            Composer(session: session, key: key, path: path, line: line, side: side, hunk: hunk)
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
            Text(line.old.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(Color.text3.opacity(0.55))
            Text(line.new.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(Color.text3.opacity(0.55))
            ZStack {
                if hover {
                    Button {
                        session.composingInPanel = inPanel
                        session.composing = key
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Color.ink)
                            .frame(width: 15, height: 15)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.sonar))
                    }
                    .buttonStyle(.plain)
                    .help("Comment on this line")
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
        .onHover { hover = QA.hover($0) }
    }

    private var key: String {
        let side = line.kind == .del ? "LEFT" : "RIGHT"
        let no = (line.kind == .del ? line.old : line.new) ?? 0
        return "\(file.path):\(side):\(no)"
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

struct CommentRow: View {
    @Bindable var session: PRSession
    let comment: PendingComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.sonar)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your comment · pending")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.text3)
                Text(comment.body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.text1)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                session.removeComment(comment.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.text3)
            }
            .buttonStyle(.plain)
            .help("Remove this comment")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.sonar.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.sonar.opacity(0.2), lineWidth: 0.75))
        .padding(.leading, 108)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }
}

struct Composer: View {
    @Bindable var session: PRSession
    let key: String
    let path: String
    let line: Int
    let side: String
    let hunk: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 64, maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.sonar.opacity(0.35), lineWidth: 0.75))
            HStack {
                Text("Line \(line) · \((path as NSString).lastPathComponent)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.text3)
                Spacer()
                Button("Cancel") { withAnimation(Motion.soft) { session.composing = nil } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Button("Add to review") {
                    session.addComment(path: path, line: line, side: side, body: text, hunk: hunk)
                }
                .buttonStyle(.glassProminent)
                .tint(Color(hex: 0x1F6F6B))
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.leading, 108)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .onAppear { focused = true }
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
