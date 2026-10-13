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

    var summary: PRSummary {
        PRSummary(ref: ref, title: title, author: author, authorAvatar: authorAvatar, ownerAvatar: ownerAvatar,
                  additions: additions, deletions: deletions, changedFiles: changedFiles, updatedAt: updatedAt,
                  isDraft: isDraft, state: state, reviewDecision: reviewDecision, checks: checks, headSha: headSha)
    }
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

struct Layer: Identifiable, Sendable {
    var id: String
    var name: String
    var role: String
}

struct Component: Identifiable, Sendable {
    var id: String
    var name: String
    var layer: String
    var kind: String
    var change: Change
    var files: [String]
    var summary: String   // a few words on what it is ("role")
}

struct Edge: Identifiable, Sendable {
    var id: String
    var from: String
    var to: String
    var label: String
    var change: Change
}

struct FlowStep: Sendable {
    var from: String
    var to: String
    var label: String
    var detail: String
}

struct Flow: Identifiable, Sendable {
    var id: Int
    var title: String
    var steps: [FlowStep]
}

struct SystemMap: Sendable {
    var layers: [Layer] = []
    var components: [Component] = []
    var edges: [Edge] = []
    var flows: [Flow] = []

    init() {}

    /// `partial` is for a map still being written: parts without a known layer yet, the part being written,
    /// and the flows wait until they are complete.
    init(_ j: J, partial: Bool = false) {
        layers = j["layers"].array.map { Layer(id: $0["id"].string, name: $0["name"].string, role: $0["role"].string) }
            .filter { !$0.id.isEmpty }
        var raw = j["components"].array
        if partial {
            if !raw.isEmpty && j["edges"].array.isEmpty { raw.removeLast() }
            let known = Set(layers.map(\.id))
            raw = raw.filter { known.contains($0["layer"].string) }
        }
        components = raw.map {
            Component(id: $0["id"].string, name: $0["name"].string, layer: $0["layer"].string, kind: $0["kind"].string,
                      change: Change(rawValue: $0["change"].string) ?? .unchanged, files: $0["files"].strings,
                      summary: $0["role"].stringOrNil ?? $0["summary"].string)
        }
        .filter { !$0.id.isEmpty && !$0.name.isEmpty }
        var seen = Set<String>()
        components = components.filter { seen.insert($0.id).inserted }
        let ids = Set(components.map(\.id))
        var rawEdges = j["edges"].array
        if partial && j["flows"].array.isEmpty && !rawEdges.isEmpty { rawEdges.removeLast() }
        edges = rawEdges.enumerated().compactMap { i, e in
            let from = e["from"].string, to = e["to"].string
            guard ids.contains(from), ids.contains(to), from != to else { return nil }
            return Edge(id: "\(from)>\(to)#\(i)", from: from, to: to, label: e["label"].string,
                        change: Change(rawValue: e["change"].string) ?? .unchanged)
        }
        flows = (partial ? [] : j["flows"].array).map { f in
            Flow(id: 0, title: f["title"].string, steps: f["steps"].array.compactMap { s in
                let from = s["from"].string, to = s["to"].string
                guard ids.contains(from), ids.contains(to) else { return nil }
                return FlowStep(from: from, to: to, label: s["label"].string, detail: s["detail"].string)
            })
        }
        .filter { !$0.steps.isEmpty }
        .enumerated()
        .map { i, f in Flow(id: i, title: f.title, steps: f.steps) }
    }

    var isEmpty: Bool { components.isEmpty }
    func component(_ id: String) -> Component? { components.first { $0.id == id } }
}

// MARK: - Review

struct PendingComment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var path: String
    var line: Int
    var side: String // RIGHT for new and context lines, LEFT for removed ones
    var body: String
    var hunk: String
}
