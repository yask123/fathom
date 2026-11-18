// What the app asks Claude, and how the diff is laid out so Claude can point back into it.

import Foundation

enum Analyst {
    // MARK: Prompt

    /// The PR, its files and its diff with every hunk labelled (f3h2), within a size budget.
    static func prompt(_ d: PRDetail, _ diff: ParsedDiff, budget: Int = 180_000) -> String {
        var out: [String] = []
        out.append("# Pull request \(d.ref.id)")
        out.append("Title: \(d.title)")
        out.append("Author: \(d.author)")
        out.append("Branch: \(d.headRef) → \(d.baseRef)")
        if !d.labels.isEmpty { out.append("Labels: \(d.labels.joined(separator: ", "))") }
        let body = d.body.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append("Description:\n" + (body.isEmpty ? "(none)" : String(body.prefix(5000))))
        if !d.commits.isEmpty {
            out.append("Commits (\(d.commitCount)):\n" + d.commits.suffix(30).map { "- \($0.headline)" }.joined(separator: "\n"))
        }
        out.append("")
        out.append("# Files (\(diff.files.count))")
        for f in diff.files {
            var line = "\(f.id) \(f.path) · \(f.status.rawValue) · +\(f.additions) −\(f.deletions)"
            if f.status == .renamed { line += " · from \(f.oldPath)" }
            if let n = f.noise { line += " · mechanical (\(n.word))" }
            out.append(line)
        }
        out.append("")
        out.append("# Diff")

        var used = out.reduce(0) { $0 + $1.count }
        var omitted: [String] = []
        for f in diff.files {
            let ids = f.hunks.map(\.id).joined(separator: ", ")
            if f.noise != nil || f.isBinary {
                if !f.hunks.isEmpty { out.append("\n## \(f.id) \(f.path) — omitted, mechanical (hunks: \(ids))") }
                continue
            }
            if used > budget {
                omitted.append("\(f.id) \(f.path) (hunks: \(ids))")
                continue
            }
            out.append("\n## \(f.id) \(f.path) (\(f.status.rawValue))")
            // Long prose and data (QA transcripts, fixtures, docs) only need to be recognised, not read.
            let ext = (f.path as NSString).pathExtension.lowercased()
            let prose = proseExtensions.contains(ext) && f.hunks.reduce(0) { $0 + $1.lines.count } > 80
            var proseLeft = 40
            for h in f.hunks {
                let end = h.newStart + max(h.newCount - 1, 0)
                var header = "@@ \(h.id) · new lines \(h.newStart)–\(end)"
                if !h.section.isEmpty { header += " · \(h.section)" }
                out.append(header)
                let rendered = h.lines.map { l -> String in
                    switch l.kind {
                    case .add: "+" + l.text
                    case .del: "-" + l.text
                    default: " " + l.text
                    }
                }
                if prose {
                    let take = min(proseLeft, rendered.count)
                    out.append(contentsOf: rendered.prefix(take))
                    if rendered.count > take { out.append("… \(rendered.count - take) more lines of .\(ext) not shown …") }
                    proseLeft -= take
                    used += rendered.prefix(take).reduce(0) { $0 + $1.count + 1 }
                    continue
                }
                if rendered.count > 420 {
                    out.append(contentsOf: rendered.prefix(340))
                    out.append("… \(rendered.count - 380) lines not shown …")
                    out.append(contentsOf: rendered.suffix(40))
                } else {
                    out.append(contentsOf: rendered)
                }
                used += rendered.prefix(420).reduce(0) { $0 + $1.count + 1 }
            }
        }
        if !omitted.isEmpty {
            out.append("\n# Not shown (diff too large; judge them by name)")
            out.append(contentsOf: omitted)
        }
        return out.joined(separator: "\n")
    }

    static let proseExtensions: Set<String> = ["txt", "md", "markdown", "mdx", "rst", "adoc", "csv", "tsv", "log", "json",
                                                "jsonl", "ndjson", "xml", "html", "htm", "svg", "snap", "ipynb"]

    // MARK: The trace

    /// The whole picture: one request's path through the system, before and after, and the forks in the road. It's
    /// written in the order it's drawn, so the page fills in from the top while Claude is still writing. It draws; it
    /// does not review: no risks, no advice, no questions. Those are the reader's to find.
    static let traceSystem = """
    You are Tracer. An AI wrote this pull request and its tests pass. An engineer wants to see what it does before \
    reading a line: one request's path through the system, before the change and after it. You draw; they think. \
    You are not reviewing: no risks, no advice, no opinions, no questions. Write almost nothing: short phrases, \
    names exactly as in the code. No praise, no filler, no hedging. If a phrase would fit any pull request, cut it.

    Everything you need is in the diff; its hunks are labelled like f3h2 (file 3, hunk 2). Answer straight away.

    Every PR answers a problem. A bug fix: what went wrong. A feature: what you couldn't do before. A refactor: what \
    made the code hard to change. Infra or tests: what was fragile or slow.

    Fields, in this order:
    - headline: what the change does, at most 8 words, starting with a verb. Plain and concrete.
    - kind: the dominant kind of change.
    - was: the situation before, at most 11 words, as a user or caller experienced it. Not the fix.
    - now: the same situation after, at most 11 words.
    - how: the key idea of the change, at most 11 words, the way you'd say it at a whiteboard.
    - cast: the parts the journey passes through, 3–6, in the order it meets them. id: a short lowercase handle. \
    name: as written in the code, at most 22 characters (a type, function or file name, never a path), or "You" for \
    the person or outside caller who starts it. kind: person, ui, service, api, store, external (someone else's \
    service), job, config or library. role: at most 3 words. where: the process or deployable it runs in, at most \
    2 words ("iOS app", "API server", "Postgres"), the same words for parts that run together; empty for a person. \
    change: added (new in this PR), changed (its code changes) or unchanged (context it talks to).
    - flow: one request's journey, told once for both versions, in time order, 3–8 steps. from and to are cast ids; \
    equal when a part works on its own. does: at most 4 words. data: what travels, at most 3 words, or empty. \
    status: same (happens before and after), removed (only before), added (only after) or changed (both, \
    differently). Only for a changed step, was holds what it did before, at most 5 words. Only for a step that \
    isn't same, hunk is the id of the hunk where that change lives. The before journey (same, changed and removed \
    steps) and the after journey (same, changed and added steps) must each read as complete.
    - breaks: the index in flow of the step where it went wrong before, or -1 when the problem was a step that was \
    missing. pain: at most 6 words, what went wrong there.
    - forks: 0–3 places where the change took one road and a reasonable engineer might have taken another, most \
    consequential first; none when there are none. title: the question decided, at most 5 words. chose: what this \
    PR does, at most 4 words. over: 1–2 roads not taken, at most 4 words each. why: at most 9 words, from the PR's \
    own description or comments when they say. step: the index in flow of the step where the choice shows, or -1. \
    hunk: the hunk id where it lives.
    """

    static let traceSchema = """
    {"type":"object","additionalProperties":false,"required":["headline","kind","was","now","how","cast","flow","breaks","pain","forks"],"properties":{
     "headline":{"type":"string"},
     "kind":{"type":"string","enum":["feature","fix","refactor","performance","infra","tests","docs","chore","mixed"]},
     "was":{"type":"string"},"now":{"type":"string"},"how":{"type":"string"},
     "cast":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","name","kind","role","where","change"],"properties":{"id":{"type":"string"},"name":{"type":"string"},"kind":{"type":"string","enum":["person","ui","service","api","store","external","job","config","library"]},"role":{"type":"string"},"where":{"type":"string"},"change":{"type":"string","enum":["added","changed","unchanged"]}}}},
     "flow":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","does","data","status"],"properties":{"from":{"type":"string"},"to":{"type":"string"},"does":{"type":"string"},"data":{"type":"string"},"status":{"type":"string","enum":["same","removed","added","changed"]},"was":{"type":"string"},"hunk":{"type":"string"}}}},
     "breaks":{"type":"integer"},
     "pain":{"type":"string"},
     "forks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","chose","over","why","step","hunk"],"properties":{
       "title":{"type":"string"},"chose":{"type":"string"},"over":{"type":"array","items":{"type":"string"}},
       "why":{"type":"string"},"step":{"type":"integer"},"hunk":{"type":"string"}}}}
    }}
    """

    // MARK: The outline

    /// For the Code tab: the diff in reading order. Nothing on the trace waits for it.
    static let outlineSystem = """
    You are Tracer. You sort a pull request's diff into reading order for a reviewer who will read the code next. \
    Names and labels only: no explanations, no opinions.

    Every hunk in the diff is labelled with an id like f3h2 (file 3, hunk 2). Refer to hunks only by these ids.

    Fields, in this order:
    - chapters: group every hunk that is not omitted into 2–7 chapters by purpose, in the best reading order. \
    title: a noun phrase of at most 4 words ("Redis budget", "Photo carousel"). attention: focus (logic worth \
    reading), skim (wiring, layout, glue) or skip (mechanical: renames, imports, docs, config bumps, boilerplate \
    tests). Each hunk id in exactly one chapter.
    - notes: one per hunk in a focus chapter, at most 6 words naming what it does ("Caches photos per place").
    """

    static let outlineSchema = """
    {"type":"object","additionalProperties":false,"required":["chapters","notes"],"properties":{
     "chapters":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","attention","hunks"],"properties":{"title":{"type":"string"},"attention":{"type":"string","enum":["focus","skim","skip"]},"hunks":{"type":"array","items":{"type":"string"}}}}},
     "notes":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["hunk","note"],"properties":{"hunk":{"type":"string"},"note":{"type":"string"}}}}
    }}
    """

    // MARK: Questions

    static let askSystem = """
    You are Tracer, answering an engineer's question about a pull request they are reviewing. The first message holds \
    the PR and its diff with hunk ids (f3h2). When the current directory holds the repository at the PR's head commit, \
    use Read, Grep and Glob to check facts instead of guessing.

    Answer only what was asked, like a colleague at their desk: short and concrete, usually under 80 words. Lead with \
    the answer. Don't review the code or give opinions unless asked. Point at code as `path/to/file.ext:line`. Say \
    plainly when something is uncertain. Markdown sparingly; no headings.
    """

    static func askOpening(_ d: PRDetail, _ diff: ParsedDiff, headline: String, question: String) -> String {
        var s = "Here is the pull request I'm reviewing.\n\n" + prompt(d, diff, budget: 140_000)
        if !headline.isEmpty { s += "\n\nIn one line: \(headline)" }
        s += "\n\n# My question\n\(question)"
        return s
    }
}
