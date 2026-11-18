// What the app knows: pull requests from GitHub, and what Claude reads in them (the trace and the outline).

import Foundation

// MARK: - Lenient JSON

/// A forgiving view over decoded JSON. Missing or mistyped fields read as empty, which suits
/// half-streamed answers from Claude and GraphQL nodes that come back null.
struct J {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }
    init(data: Data) { raw = try? JSONSerialization.jsonObject(with: data) }

    subscript(_ key: String) -> J { J((raw as? [String: Any])?[key]) }
    subscript(_ index: Int) -> J {
        guard let a = raw as? [Any], a.indices.contains(index) else { return J(nil) }
        return J(a[index])
    }

    var string: String { (raw as? String) ?? "" }
    var stringOrNil: String? { raw as? String }
    var int: Int { (raw as? NSNumber)?.intValue ?? 0 }
    var double: Double { (raw as? NSNumber)?.doubleValue ?? 0 }
    var bool: Bool { (raw as? Bool) ?? false }
    var array: [J] { (raw as? [Any])?.map(J.init) ?? [] }
    var strings: [String] { (raw as? [Any])?.compactMap { $0 as? String } ?? [] }
    var exists: Bool { raw != nil && !(raw is NSNull) }
    var url: URL? { stringOrNil.flatMap(URL.init(string:)) }
    var date: Date? { stringOrNil.flatMap { J.iso.date(from: $0) ?? J.isoFrac.date(from: $0) } }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - GitHub

struct PRRef: Hashable, Codable, Identifiable, Sendable {
    var owner: String
    var repo: String
    var number: Int

    var id: String { "\(owner)/\(repo)#\(number)" }
    var slug: String { "\(owner)/\(repo)" }
    var web: URL { URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")! }
    var fileKey: String { "\(owner)__\(repo)__\(number)" }

    /// Accepts a PR link, `owner/repo#123`, `owner/repo/pull/123` or one of the app's own links (`tracer://`, and
    /// `fathom://` from before the rename).
    static func parse(_ text: String) -> PRRef? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["tracer://open?url=", "tracer://", "fathom://open?url=", "fathom://", "https://", "http://", "www.", "github.com/"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        s = s.removingPercentEncoding ?? s
        for prefix in ["https://", "http://", "www.", "github.com/"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        let pattern = #"^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:/pulls?/|#|/)(\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let o = Range(m.range(at: 1), in: s), let r = Range(m.range(at: 2), in: s), let n = Range(m.range(at: 3), in: s),
              let number = Int(s[n]) else { return nil }
        return PRRef(owner: String(s[o]), repo: String(s[r]), number: number)
    }
}

struct PRSummary: Identifiable, Hashable, Codable, Sendable {
    var ref: PRRef
    var title: String
    var author: String
    var authorAvatar: URL?
    var ownerAvatar: URL?
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var updatedAt: Date?
    var isDraft: Bool
    var state: String
    var reviewDecision: String?
    var checks: String?
    var headSha: String

    var id: String { ref.id }

    init(ref: PRRef, title: String, author: String, authorAvatar: URL?, ownerAvatar: URL?, additions: Int, deletions: Int,
         changedFiles: Int, updatedAt: Date?, isDraft: Bool, state: String, reviewDecision: String?, checks: String?, headSha: String) {
        self.ref = ref
        self.title = title
        self.author = author
        self.authorAvatar = authorAvatar
        self.ownerAvatar = ownerAvatar
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.state = state
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.headSha = headSha
    }

    init?(_ n: J) {
        let slug = n["repository"]["nameWithOwner"].string.split(separator: "/")
        guard slug.count == 2, n["number"].int > 0 else { return nil }
        ref = PRRef(owner: String(slug[0]), repo: String(slug[1]), number: n["number"].int)
        title = n["title"].string
        author = n["author"]["login"].stringOrNil ?? "ghost"
        authorAvatar = n["author"]["avatarUrl"].url
        ownerAvatar = n["repository"]["owner"]["avatarUrl"].url
        additions = n["additions"].int
        deletions = n["deletions"].int
        changedFiles = n["changedFiles"].int
        updatedAt = n["updatedAt"].date
        isDraft = n["isDraft"].bool
        state = n["state"].stringOrNil ?? "OPEN"
        reviewDecision = n["reviewDecision"].stringOrNil
        checks = n["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["state"].stringOrNil
        headSha = n["headRefOid"].string
    }
}

struct PRCommit: Hashable, Sendable {
    var oid: String
    var headline: String
    var date: Date?
}

/// One comment from GitHub: on a line of the diff, or on the pull request as a whole.
struct GHComment: Identifiable, Hashable, Sendable {
    var id: String
    var databaseId: Int
    var author: String
    var avatar: URL?
    var body: String
    var createdAt: Date?
    var url: URL?
    /// For a review: APPROVED, CHANGES_REQUESTED or COMMENTED. Empty for a plain comment.
    var verdict = ""

    var isBot = false
    var displayName: String { author.replacingOccurrences(of: "[bot]", with: "") }

    init?(_ n: J, verdict: String = "") {
        id = n["id"].string
        guard !id.isEmpty else { return nil }
        databaseId = n["databaseId"].int
        author = n["author"]["login"].stringOrNil ?? "ghost"
        avatar = n["author"]["avatarUrl"].url
        isBot = n["author"]["__typename"].string == "Bot" || author.hasSuffix("[bot]")
        body = n["body"].string
        createdAt = n["createdAt"].date ?? n["submittedAt"].date
        url = n["url"].url
        self.verdict = verdict
    }
}

/// A conversation on one line of the diff.
struct ReviewThread: Identifiable, Hashable, Sendable {
    var id: String
    var path: String
    var line: Int?          // nil once the line is gone from the latest commit
    var side: String        // LEFT for a removed line
    var isResolved: Bool
    var isOutdated: Bool
    var comments: [GHComment]
    /// About the whole file rather than a line.
    var onFile = false

    var key: String? { onFile ? nil : line.map { "\(path):\(side):\($0)" } }
    var replyTo: Int? { comments.first?.databaseId }
}

struct PRDetail: Sendable {
    var ref: PRRef
    var title: String
    var body: String
    var state: String
    var isDraft: Bool
    var author: String
    var authorAvatar: URL?
    var ownerAvatar: URL?
    var createdAt: Date?
    var updatedAt: Date?
    var baseRef: String
    var headRef: String
    var baseSha: String
    var headSha: String
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var commits: [PRCommit]
    var commitCount: Int
    var labels: [String]
    var reviewDecision: String?
    var checks: String?
    var reviewers: [(login: String, avatar: URL?, state: String)]
    var diskUsageKB: Int
    var threads: [ReviewThread] = []
    /// Comments on the PR as a whole and review summaries, oldest first.
    var conversation: [GHComment] = []

    var summary: PRSummary {
        PRSummary(ref: ref, title: title, author: author, authorAvatar: authorAvatar, ownerAvatar: ownerAvatar,
                  additions: additions, deletions: deletions, changedFiles: changedFiles, updatedAt: updatedAt,
                  isDraft: isDraft, state: state, reviewDecision: reviewDecision, checks: checks, headSha: headSha)
    }
}

/// A repository in the switcher: its open pull requests, and how many wait for you.
struct RepoInfo: Identifiable, Hashable, Codable, Sendable {
    var slug: String
    var open: Int
    var pushedAt: Date?
    var id: String { slug }
    var owner: String { String(slug.split(separator: "/").first ?? "") }
    var name: String { String(slug.split(separator: "/").last ?? "") }
}

struct Viewer: Sendable, Equatable, Codable {
    var login: String
    var name: String
    var avatar: URL?
}

// MARK: - The outline

enum Attention: String, Sendable {
    case focus, skim, skip

    var word: String {
        switch self {
        case .focus: "Read"
        case .skim: "Skim"
        case .skip: "Skip"
        }
    }
}

enum Change: String, Sendable {
    case added, modified, removed, unchanged
}

struct Chapter: Identifiable, Sendable {
    var id: Int
    var title: String
    var attention: Attention
    var hunks: [String]
}

struct HunkNote: Sendable {
    var hunk: String
    var anchor: String
    var note: String
}

/// The diff sorted into reading order for the Code tab: chapters by purpose, and a few words on each change.
struct Brief: Sendable {
    var chapters: [Chapter] = []
    var notes: [HunkNote] = []

    init() {}

    init(_ j: J) {
        chapters = j["chapters"].array.enumerated().map { i, c in
            Chapter(id: i, title: c["title"].string,
                    attention: Attention(rawValue: c["attention"].string) ?? .skim, hunks: c["hunks"].strings)
        }
        notes = j["notes"].array.map { HunkNote(hunk: $0["hunk"].string, anchor: $0["anchor"].string, note: $0["note"].string) }
    }

    var isEmpty: Bool { chapters.isEmpty }
}

// MARK: - The trace

/// What the change does, drawn: one request's journey through the system, told once for before and after, with the
/// parts it passes through and where each one runs.
struct Trace: Sendable {
    /// Whether a step of the journey happens before, after, or both.
    enum Status: String, Sendable {
        case same, removed, added, changed
    }

    /// A part the journey passes through, or the person who starts it.
    struct Actor: Sendable, Identifiable, Hashable {
        var id: String
        var name: String
        /// What sort of thing it is (person, ui, service, api, store, external, job, config, library), for its mark.
        var kind: String
        var role: String
        /// The process or deployable it runs in ("iOS app", "API server"); empty for a person.
        var place: String
        var change: Change

        var isPerson: Bool {
            let n = name.lowercased()
            return kind == "person" || n == "you" || n == "user" || (place.isEmpty && id == "you")
        }
    }

    /// A place where the change took one road over another.
    struct Fork: Sendable, Identifiable, Hashable {
        var id: Int
        var title: String
        var chose: String
        var over: [String]
        var why: String
        /// The step of the flow where the choice shows, or -1.
        var step: Int
        var hunk: String
    }

    /// One step of the journey, told once for both versions.
    struct Step: Sendable, Hashable, Identifiable {
        var id: Int
        var from: String
        var to: String
        var does: String
        var data: String
        var status: Status
        var was: String
        /// Where this step's change lives in the diff, when it changes.
        var hunk: String

        var inBefore: Bool { status != .added }
        var inAfter: Bool { status != .removed }
        /// The step as it went before the change.
        var beforeDoes: String { status == .changed && !was.isEmpty ? was : does }
    }

    var headline = ""
    var kind = ""
    var was = ""
    var now = ""
    var how = ""
    var cast: [Actor] = []
    var flow: [Step] = []
    var breaks = -1
    var pain = ""
    var forks: [Fork] = []

    init() {}

    /// `partial` is for an answer still being written: the entry Claude is in the middle of is left out until it's
    /// whole, so a half-typed id never shows up as a part of its own.
    init(_ j: J, partial: Bool = false) {
        headline = j["headline"].string
        kind = j["kind"].string
        was = j["was"].string
        now = j["now"].string
        how = j["how"].string
        var actors = j["cast"].array.map {
            Actor(id: $0["id"].string, name: $0["name"].string, kind: $0["kind"].string, role: $0["role"].string,
                  place: $0["where"].string, change: Self.change($0["change"].string))
        }
        var steps = j["flow"].array.map { s in
            Step(id: 0, from: s["from"].string, to: s["to"].string, does: s["does"].string, data: s["data"].string,
                 status: Status(rawValue: s["status"].string) ?? .same, was: s["was"].string, hunk: s["hunk"].string)
        }
        if partial && !j["breaks"].exists {
            if steps.isEmpty { if !actors.isEmpty { actors.removeLast() } } else { steps.removeLast() }
        }
        actors = actors.filter { !$0.id.isEmpty && !$0.name.isEmpty }
        steps = steps.filter { !$0.from.isEmpty && !$0.to.isEmpty && !$0.does.isEmpty }
        var known = Set(actors.map(\.id))
        if partial {
            // Mid-answer, a step that names a part not in the cast is one whose id is still being typed: it waits.
            steps = steps.filter { known.contains($0.from) && known.contains($0.to) }
        } else {
            // In the finished answer, a step may name a part the cast left out; it joins under its own name.
            for s in steps {
                for id in [s.from, s.to] where known.insert(id).inserted {
                    actors.append(Actor(id: id, name: id, kind: "", role: "", place: "", change: .unchanged))
                }
            }
        }
        cast = actors
        flow = steps.enumerated().map { i, s in var s = s; s.id = i; return s }
        breaks = j["breaks"].exists ? j["breaks"].int : -1
        pain = j["pain"].string
        var fs = j["forks"].array.enumerated().map { n, f in
            Fork(id: n, title: f["title"].string, chose: f["chose"].string, over: f["over"].strings.filter { !$0.isEmpty },
                 why: f["why"].string, step: f["step"].exists ? f["step"].int : -1, hunk: f["hunk"].string)
        }
        // The fork still being written waits until it's whole.
        if partial, !fs.isEmpty { fs.removeLast() }
        forks = fs.filter { !$0.title.isEmpty && !$0.chose.isEmpty }
    }

    static func change(_ s: String) -> Change {
        switch s {
        case "added": .added
        case "removed": .removed
        case "unchanged": .unchanged
        default: .modified
        }
    }

    var isEmpty: Bool { headline.isEmpty && was.isEmpty && cast.isEmpty }
    func actor(_ id: String) -> Actor? { cast.first { $0.id == id } }
}

// MARK: - Review

/// An open comment box.
struct Compose: Equatable {
    enum Kind: Equatable {
        case new
        case reply(Int)
        case edit(UUID)
    }

    var kind: Kind
    var path: String
    var line: Int
    var side: String
    var hunk: String
    var thread: String? = nil
    var inPanel = false

    var key: String { "\(path):\(side):\(line)" }
    var draftKey: String {
        switch kind {
        case .new: "new:\(key)"
        case .reply: "reply:\(thread ?? key)"
        case .edit(let id): "edit:\(id)"
        }
    }
}

struct PendingComment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var path: String
    var line: Int
    var side: String // RIGHT for new and context lines, LEFT for removed ones
    var body: String
    var hunk: String
    /// Set for a reply to someone's thread: the first comment's id. Replies go out after the review.
    var replyTo: Int?
}
