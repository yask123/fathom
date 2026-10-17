// What Fathom knows: pull requests from GitHub, and the brief and map Claude writes about them.

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

    /// Accepts a PR link, `owner/repo#123`, `owner/repo/pull/123` or a `fathom://` link.
    static func parse(_ text: String) -> PRRef? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["fathom://open?url=", "fathom://", "https://", "http://", "www.", "github.com/"] where s.hasPrefix(prefix) {
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

// MARK: - The brief

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

struct Brief: Sendable {
    var headline = ""
    var kind = ""
    var chapters: [Chapter] = []
    var notes: [HunkNote] = []
    var contracts: [Contract] = []

    init() {}

    init(_ j: J) {
        headline = j["headline"].string
        kind = j["kind"].string
        chapters = j["chapters"].array.enumerated().map { i, c in
            Chapter(id: i, title: c["title"].string,
                    attention: Attention(rawValue: c["attention"].string) ?? .skim, hunks: c["hunks"].strings)
        }
        notes = j["notes"].array.map { HunkNote(hunk: $0["hunk"].string, anchor: $0["anchor"].string, note: $0["note"].string) }
        contracts = j["contracts"].array.enumerated().compactMap { i, c in
            let name = c["name"].string
            guard !name.isEmpty else { return nil }
            return Contract(id: i, name: name, kind: c["kind"].string, change: Change(rawValue: c["change"].string) ?? .modified,
                            file: c["file"].string,
                            members: c["members"].array.map { ContractMember(name: $0["name"].string, change: Change(rawValue: $0["change"].string) ?? .modified) }
                                .filter { !$0.name.isEmpty })
        }
    }

    var isEmpty: Bool { headline.isEmpty && chapters.isEmpty }
}

/// An interface whose shape the PR changes: an endpoint, a type, a table, an event, a config key.
struct Contract: Identifiable, Sendable {
    var id: Int
    var name: String
    var kind: String
    var change: Change
    var file: String
    var members: [ContractMember]
}

struct ContractMember: Hashable, Sendable {
    var name: String
    var change: Change
}

// MARK: - The map

// MARK: - The story

/// A pull request told as a short illustrated story: the problem, the idea, how it works now, the choices made,
/// and where to read. Each page is a sentence and a small diagram.
struct Story: Sendable {
    struct Step: Sendable, Hashable {
        var from: String
        var to: String
        var does: String
        var data: String
        var isNew: Bool
    }

    struct Part: Sendable, Identifiable, Hashable {
        var id: String
        var name: String
        var kind: String
        var isNew: Bool
        var role: String
    }

    struct Link: Sendable, Hashable {
        var from: String
        var to: String
        var label: String
        var isNew: Bool
    }

    struct Choice: Sendable, Identifiable, Hashable {
        var id: Int
        var title: String
        var chose: String
        var over: String
        var why: String
        var stated: Bool
        var hunks: [String]
    }

    struct Look: Sendable, Hashable {
        var hunk: String
        var why: String
    }

    var problemTitle = ""
    var problemSteps: [Step] = []
    var pain = ""
    var painStep = -1
    var ideaTitle = ""
    var parts: [Part] = []
    var links: [Link] = []
    var solutionTitle = ""
    var solutionSteps: [Step] = []
    var choices: [Choice] = []
    var look: [Look] = []

    init() {}

    init(_ j: J) {
        func steps(_ a: [J]) -> [Step] {
            a.map { Step(from: $0["from"].string, to: $0["to"].string, does: $0["does"].string, data: $0["data"].string,
                         isNew: $0["new"].bool) }
                .filter { !$0.from.isEmpty && !$0.to.isEmpty }
        }
        let p = j["problem"], i = j["idea"], s = j["solution"]
        problemTitle = p["title"].string
        problemSteps = steps(p["steps"].array)
        pain = p["pain"].string
        painStep = p["painStep"].exists ? p["painStep"].int : -1
        ideaTitle = i["title"].string
        parts = i["parts"].array.map {
            Part(id: $0["id"].string, name: $0["name"].string, kind: $0["kind"].string, isNew: $0["new"].bool, role: $0["role"].string)
        }.filter { !$0.id.isEmpty && !$0.name.isEmpty }
        let ids = Set(parts.map(\.id))
        links = i["links"].array.map {
            Link(from: $0["from"].string, to: $0["to"].string, label: $0["label"].string, isNew: $0["new"].bool)
        }.filter { ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to }
        solutionTitle = s["title"].string
        solutionSteps = steps(s["steps"].array)
        choices = j["choices"].array.enumerated().map { n, c in
            Choice(id: n, title: c["title"].string, chose: c["chose"].string, over: c["over"].string, why: c["why"].string,
                   stated: c["stated"].bool, hunks: c["hunks"].strings)
        }.filter { !$0.title.isEmpty }
        look = j["look"].array.map { Look(hunk: $0["hunk"].string, why: $0["why"].string) }.filter { !$0.hunk.isEmpty }
    }

    var isEmpty: Bool { problemTitle.isEmpty && ideaTitle.isEmpty && solutionTitle.isEmpty }
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
