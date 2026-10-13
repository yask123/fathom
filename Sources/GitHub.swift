// GitHub through the `gh` CLI the user is already signed in to. No tokens of our own.

import Foundation

enum GitHub {
    static var gh: String? { Shell.which("gh") }

    static func ghRun(_ args: [String], input: Data? = nil, timeout: TimeInterval = 60) async throws -> Shell.Output {
        guard let gh else { throw ShellError(message: "Install the GitHub CLI to use Fathom. Open Settings (⌘,) to set it up.") }
        let out = try await Shell.run(gh, args, input: input, timeout: timeout)
        if out.status != 0 {
            let text = out.errorText
            if signedOut(text) {
                throw ShellError(message: "The GitHub CLI isn't signed in. Open Settings (⌘,) to sign in.")
            }
            throw ShellError(message: text.isEmpty ? "gh exited with \(out.status)" : String(text.prefix(400)))
        }
        return out
    }

    /// gh's ways of saying there's no usable login: none yet, or a token GitHub no longer accepts.
    static func signedOut(_ error: String) -> Bool {
        let e = error.lowercased()
        return e.contains("gh auth login") || e.contains("not logged") || e.contains("bad credentials")
            || e.contains("http 401") || e.contains("requires authentication")
    }

    static func graphql(_ query: String, _ vars: [String: String] = [:], ints: [String: Int] = [:]) async throws -> J {
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (k, v) in vars { args += ["-f", "\(k)=\(v)"] }
        for (k, v) in ints { args += ["-F", "\(k)=\(v)"] }
        let out = try await ghRun(args)
        let j = J(data: out.stdout)
        if !j["data"].exists, let message = j["errors"][0]["message"].stringOrNil {
            throw ShellError(message: message)
        }
        return j["data"]
    }

    // MARK: Inbox

    static let prFragment = """
    fragment pr on PullRequest {
      number title url isDraft state updatedAt additions deletions changedFiles reviewDecision headRefOid
      repository { nameWithOwner owner { avatarUrl } }
      author { login avatarUrl }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    struct Inbox: Sendable {
        var viewer: Viewer
        var forYou: [PRSummary]
        var yours: [PRSummary]
        var reviewed: [PRSummary]
    }

    static func inbox() async throws -> Inbox {
        // `archived:false` hides some org PRs from GraphQL search, so it's left out on purpose.
        let query = prFragment + """
        query {
          viewer { login name avatarUrl }
          forYou: search(query: "is:pr is:open review-requested:@me sort:updated-desc", type: ISSUE, first: 30) { nodes { ...pr } }
          yours: search(query: "is:pr is:open author:@me sort:updated-desc", type: ISSUE, first: 30) { nodes { ...pr } }
          reviewed: search(query: "is:pr is:open reviewed-by:@me -author:@me sort:updated-desc", type: ISSUE, first: 20) { nodes { ...pr } }
        }
        """
        let d = try await graphql(query)
        let viewer = Viewer(login: d["viewer"]["login"].string, name: d["viewer"]["name"].string, avatar: d["viewer"]["avatarUrl"].url)
        let forYou = d["forYou"]["nodes"].array.compactMap(PRSummary.init)
        let yours = d["yours"]["nodes"].array.compactMap(PRSummary.init)
        let seen = Set(forYou.map(\.id))
        let reviewed = d["reviewed"]["nodes"].array.compactMap(PRSummary.init).filter { !seen.contains($0.id) }
        return Inbox(viewer: viewer, forYou: forYou, yours: yours, reviewed: reviewed)
    }

    // MARK: One pull request

    static func detail(_ ref: PRRef) async throws -> PRDetail {
        try await detailWithData(ref).0
    }

    /// The PR, and GitHub's raw answer so it can be kept on disk and read back with `parseDetail`.
    static func detailWithData(_ ref: PRRef) async throws -> (PRDetail, Data) {
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            diskUsage
            owner { avatarUrl }
            pullRequest(number: $number) {
              number title body state isDraft createdAt updatedAt additions deletions changedFiles
              baseRefName headRefName baseRefOid headRefOid reviewDecision
              author { login avatarUrl }
              labels(first: 12) { nodes { name } }
              commits(last: 40) { totalCount nodes { commit { oid messageHeadline committedDate statusCheckRollup { state } } } }
              latestReviews(first: 20) { nodes { author { login avatarUrl } state } }
            }
          }
        }
        """
        let out = try await ghRun(["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(ref.owner)",
                                   "-f", "name=\(ref.repo)", "-F", "number=\(ref.number)"])
        return (try parseDetail(ref, data: out.stdout), out.stdout)
    }

    static func parseDetail(_ ref: PRRef, data: Data) throws -> PRDetail {
        let j = J(data: data)
        if !j["data"].exists, let message = j["errors"][0]["message"].stringOrNil {
            throw ShellError(message: message)
        }
        let d = j["data"]
        let pr = d["repository"]["pullRequest"]
        guard pr.exists else { throw ShellError(message: "Couldn't find \(ref.id), or you don't have access to it") }
        let commits = pr["commits"]["nodes"].array.map {
            PRCommit(oid: $0["commit"]["oid"].string, headline: $0["commit"]["messageHeadline"].string, date: $0["commit"]["committedDate"].date)
        }
        return PRDetail(
            ref: ref,
            title: pr["title"].string,
            body: pr["body"].string,
            state: pr["state"].string,
            isDraft: pr["isDraft"].bool,
            author: pr["author"]["login"].stringOrNil ?? "ghost",
            authorAvatar: pr["author"]["avatarUrl"].url,
            ownerAvatar: d["repository"]["owner"]["avatarUrl"].url,
            createdAt: pr["createdAt"].date,
            updatedAt: pr["updatedAt"].date,
            baseRef: pr["baseRefName"].string,
            headRef: pr["headRefName"].string,
            baseSha: pr["baseRefOid"].string,
            headSha: pr["headRefOid"].string,
            additions: pr["additions"].int,
            deletions: pr["deletions"].int,
            changedFiles: pr["changedFiles"].int,
            commits: commits,
            commitCount: pr["commits"]["totalCount"].int,
            labels: pr["labels"]["nodes"].array.map { $0["name"].string },
            reviewDecision: pr["reviewDecision"].stringOrNil,
            checks: pr["commits"]["nodes"].array.last?["commit"]["statusCheckRollup"]["state"].stringOrNil,
            reviewers: pr["latestReviews"]["nodes"].array.map { ($0["author"]["login"].string, $0["author"]["avatarUrl"].url, $0["state"].string) },
            diskUsageKB: d["repository"]["diskUsage"].int
        )
    }

    static func diff(_ ref: PRRef) async throws -> String {
        do {
            return try await ghRun(["pr", "diff", String(ref.number), "--repo", ref.slug], timeout: 90).text
        } catch {
            let text = error.localizedDescription
            if text.contains("too large") || text.contains("exceeded") || text.contains("406") {
                throw ShellError(message: "GitHub won't serve a diff this large. Fathom reads PRs up to about 20,000 lines.")
            }
            throw error
        }
    }

    // MARK: Review

    enum Verdict: String, CaseIterable, Sendable {
        case comment = "COMMENT"
        case approve = "APPROVE"
        case requestChanges = "REQUEST_CHANGES"
    }

    static func submitReview(_ ref: PRRef, commit: String, verdict: Verdict, body: String, comments: [PendingComment]) async throws -> URL? {
        var payload: [String: Any] = ["commit_id": commit, "event": verdict.rawValue]
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload["body"] = body }
        if !comments.isEmpty {
            payload["comments"] = comments.map { ["path": $0.path, "line": $0.line, "side": $0.side, "body": $0.body] as [String: Any] }
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let out = try await ghRun(["api", "--method", "POST", "repos/\(ref.slug)/pulls/\(ref.number)/reviews", "--input", "-"], input: data)
        return J(data: out.stdout)["html_url"].url
    }
}
