// Where Fathom keeps things: soundings (Claude's brief + map per PR commit), recent PRs, review progress,
// and shallow checkouts that Claude reads while it draws the map.

import Foundation

/// One finished reading of a PR at one commit.
struct Sounding: Codable, Sendable {
    var ref: PRRef
    var headSha: String
    var model: String
    var brief: Data?
    var map: Data?
    var briefSeconds: Double?
    var mapSeconds: Double?
    var createdAt: Date
    var version: Int?

    /// Bumped when the prompts change shape; older readings are read again.
    static let current = 2
}

/// Small state that survives relaunches.
struct SavedState: Codable {
    var recents: [PRSummary] = []
    var reviewed: [String: [Int]] = [:]          // "owner/repo#n@sha" → chapter ids marked understood
    var pending: [String: [PendingComment]] = [:] // "owner/repo#n" → unsent review comments
    var model = "opus"
    var ping = true
    var autoRead = false
    var inbox: CachedInbox?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recents = try c.decodeIfPresent([PRSummary].self, forKey: .recents) ?? []
        reviewed = try c.decodeIfPresent([String: [Int]].self, forKey: .reviewed) ?? [:]
        pending = try c.decodeIfPresent([String: [PendingComment]].self, forKey: .pending) ?? [:]
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "opus"
        ping = try c.decodeIfPresent(Bool.self, forKey: .ping) ?? true
        autoRead = try c.decodeIfPresent(Bool.self, forKey: .autoRead) ?? false
        inbox = try? c.decodeIfPresent(CachedInbox.self, forKey: .inbox)
    }
}

/// The inbox as last seen, so the sidebar fills in before GitHub answers.
struct CachedInbox: Codable {
    var viewer: Viewer
    var forYou: [PRSummary]
    var yours: [PRSummary]
    var reviewed: [PRSummary]
}

/// A PR's details and diff as GitHub last served them.
struct CachedPR {
    var detail: Data
    var diff: String
}

enum Library {
    static let root: URL = {
        if let custom = ProcessInfo.processInfo.environment["FATHOM_HOME"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Fathom", directoryHint: .isDirectory)
    }()

    static var soundings: URL { root.appending(path: "soundings", directoryHint: .isDirectory) }
    static var prs: URL { root.appending(path: "prs", directoryHint: .isDirectory) }
    static var stateFile: URL { root.appending(path: "state.json") }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func soundingURL(_ ref: PRRef, sha: String) -> URL {
        soundings.appending(path: "\(ref.fileKey)__\(sha.prefix(12)).json")
    }

    // MARK: PRs on disk

    private static func prDir(_ ref: PRRef) -> URL { prs.appending(path: ref.fileKey, directoryHint: .isDirectory) }

    static func loadPR(_ ref: PRRef) -> CachedPR? {
        let dir = prDir(ref)
        guard let detail = try? Data(contentsOf: dir.appending(path: "detail.json")),
              let diff = try? String(contentsOf: dir.appending(path: "diff.patch"), encoding: .utf8) else { return nil }
        return CachedPR(detail: detail, diff: diff)
    }

    /// The head commit of the cached copy, read without loading the diff.
    static func cachedHead(_ ref: PRRef) -> String? {
        try? String(contentsOf: prDir(ref).appending(path: "head"), encoding: .utf8)
    }

    static func savePR(_ ref: PRRef, detail: Data, diff: String, head: String) {
        let dir = prDir(ref)
        ensure(dir)
        try? detail.write(to: dir.appending(path: "detail.json"), options: .atomic)
        try? diff.write(to: dir.appending(path: "diff.patch"), atomically: true, encoding: .utf8)
        try? head.write(to: dir.appending(path: "head"), atomically: true, encoding: .utf8)
    }

    /// Keeps the most recently saved PRs.
    static func prunePRs(keep: Int) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: prs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = dirs.map { url -> (URL, Date) in
            let head = url.appending(path: "head")
            let date = (try? head.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: url) }
    }

    static func loadSounding(_ ref: PRRef, sha: String) -> Sounding? {
        guard let data = try? Data(contentsOf: soundingURL(ref, sha: sha)) else { return nil }
        return try? decoder.decode(Sounding.self, from: data)
    }

    static func saveSounding(_ s: Sounding) {
        ensure(soundings)
        guard let data = try? encoder.encode(s) else { return }
        try? data.write(to: soundingURL(s.ref, sha: s.headSha), options: .atomic)
    }

    /// PRs (any commit) that have been sounded, for the sidebar's little marks.
    static func soundedKeys() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: soundings.path)) ?? []
        return Set(names.compactMap { name -> String? in
            // owner__repo__number__sha; owners can't contain "_", repo names can.
            let parts = name.replacingOccurrences(of: ".json", with: "").components(separatedBy: "__")
            guard parts.count >= 4 else { return nil }
            let repo = parts[1..<(parts.count - 2)].joined(separator: "__")
            return "\(parts[0])/\(repo)#\(parts[parts.count - 2])@\(parts[parts.count - 1])"
        })
    }

    static func loadState() -> SavedState {
        guard let data = try? Data(contentsOf: stateFile), let s = try? decoder.decode(SavedState.self, from: data) else { return SavedState() }
        return s
    }

    static func saveState(_ s: SavedState) {
        ensure(root)
        guard let data = try? encoder.encode(s) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Shallow, read-only checkouts of PR heads, one git worktree per PR sharing one object store per repo.
actor Checkouts {
    static let shared = Checkouts()

    private var busy = Set<String>()        // repos with git work in flight; one at a time per repo
    private var inUse: [URL: Int] = [:]     // checkouts open sessions are reading; never pruned

    func hold(_ tree: URL) { inUse[tree.standardizedFileURL, default: 0] += 1 }

    func release(_ tree: URL) {
        let key = tree.standardizedFileURL
        inUse[key] = (inUse[key] ?? 1) - 1
        if inUse[key] ?? 0 <= 0 { inUse[key] = nil }
    }

    private var git: String { Shell.which("git") ?? "/usr/bin/git" }

    private var credentials: [String] {
        guard let gh = GitHub.gh else { return [] }
        return ["-c", "credential.helper=", "-c", "credential.helper=!\(gh) auth git-credential"]
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL? = nil, timeout: TimeInterval = 240) async throws -> String {
        let out = try await Shell.run(git, credentials + args, cwd: dir, timeout: timeout)
        guard out.status == 0 else {
            throw ShellError(message: out.errorText.isEmpty ? "git \(args.first ?? "") failed" : String(out.errorText.prefix(300)))
        }
        return out.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The PR's head commit on disk, fetched shallowly. Reuses what's already there.
    func prepare(_ ref: PRRef, sha: String) async throws -> URL {
        // The actor lets other calls in at every await, so serialise each repo's git work by hand.
        while busy.contains(ref.slug) {
            try await Task.sleep(for: .milliseconds(150))
        }
        busy.insert(ref.slug)
        defer { busy.remove(ref.slug) }
        let fm = FileManager.default
        let base = Library.root.appending(path: "repos/\(ref.owner)/\(ref.repo)", directoryHint: .isDirectory)
        let tree = Library.root.appending(path: "trees/\(ref.owner)/\(ref.repo)/pr-\(ref.number)", directoryHint: .isDirectory)
        let local = "refs/fathom/pr-\(ref.number)"

        if fm.fileExists(atPath: tree.appending(path: ".git").path),
           let head = try? await run(["rev-parse", "HEAD"], in: tree), head == sha {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: tree.path)
            return tree
        }

        // Idempotent setup, so a run that was cut short between init and remote heals itself.
        if !fm.fileExists(atPath: base.appending(path: ".git").path) {
            Library.ensure(base)
            try await run(["init", "-q"], in: base)
        }
        if (try? await run(["remote", "get-url", "origin"], in: base)) == nil {
            try await run(["remote", "add", "origin", "https://github.com/\(ref.slug).git"], in: base)
        }
        try await run(["fetch", "-q", "--depth=1", "--no-tags", "--filter=blob:none", "origin", "+pull/\(ref.number)/head:\(local)"], in: base)

        if fm.fileExists(atPath: tree.appending(path: ".git").path) {
            try await run(["checkout", "-q", "--force", "--detach", local], in: tree)
        } else {
            try? fm.removeItem(at: tree)
            Library.ensure(tree.deletingLastPathComponent())
            _ = try? await run(["worktree", "prune"], in: base)
            try await run(["worktree", "add", "-q", "--force", "--detach", tree.path, local], in: base)
        }
        await prune(base: base, keep: tree)
        return tree
    }

    /// Keeps the twelve most recently used checkouts across all repos, so disk use stays bounded.
    private func prune(base: URL, keep: URL) async {
        let fm = FileManager.default
        let trees = Library.root.appending(path: "trees", directoryHint: .isDirectory)
        var all: [(tree: URL, used: Date, base: URL)] = []
        for owner in (try? fm.contentsOfDirectory(atPath: trees.path)) ?? [] {
            for repo in (try? fm.contentsOfDirectory(atPath: trees.appending(path: owner).path)) ?? [] {
                let dir = trees.appending(path: "\(owner)/\(repo)", directoryHint: .isDirectory)
                for pr in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where pr.hasPrefix("pr-") {
                    let url = dir.appending(path: pr, directoryHint: .isDirectory)
                    let used = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
                    all.append((url, used, Library.root.appending(path: "repos/\(owner)/\(repo)", directoryHint: .isDirectory)))
                }
            }
        }
        for old in all.sorted(by: { $0.used > $1.used }).dropFirst(12)
        where old.tree.standardizedFileURL != keep.standardizedFileURL && inUse[old.tree.standardizedFileURL] == nil {
            _ = try? await run(["worktree", "remove", "--force", old.tree.path], in: old.base)
            try? fm.removeItem(at: old.tree)
        }
    }
}
