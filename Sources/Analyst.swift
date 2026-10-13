// What Fathom asks Claude, and how the diff is laid out so Claude can point back into it.

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

    // MARK: The outline

    static let briefSystem = """
    You are Fathom. You prepare a pull request for an engineer who will understand it through diagrams and then think \
    for themselves. Write almost nothing: a headline, names and labels. No explanations, no opinions, no review \
    comments, no risk talk.

    Every hunk in the diff is labelled with an id like f3h2 (file 3, hunk 2). Refer to hunks only by these ids.

    Fields, in this order:
    - headline: what the change does, at most 10 words, starting with a verb. Plain and concrete.
    - kind: the dominant kind of change.
    - chapters: group every hunk that is not omitted into 2–8 chapters by purpose, in the best reading order. title: \
    a noun phrase of at most 4 words ("Redis budget", "Photo carousel"). attention: focus (logic worth reading), skim \
    (wiring, layout, glue) or skip (mechanical: renames, imports, docs, config bumps, boilerplate tests). Each hunk id \
    in exactly one chapter.
    - contracts: interfaces whose shape this PR changes — HTTP or RPC endpoints, public types, structs and classes, \
    database tables, events and messages, config keys and env vars, CLI flags. 0–8, most important first; skip private \
    helpers. name as written in the code. file: its path from the diff. members: up to 8 parts that changed, each at \
    most 5 words written as code ("photos: [PlacePhoto]", "GET ?name&lat&lng", "budget INT NOT NULL"), with their change.
    - notes: one per hunk in a focus or skim chapter, at most 7 words naming what it does ("Caches photos per place").
    """

    static let briefSchema = """
    {"type":"object","additionalProperties":false,
     "required":["headline","kind","chapters","contracts","notes"],
     "properties":{
      "headline":{"type":"string"},
      "kind":{"type":"string","enum":["feature","fix","refactor","performance","infra","tests","docs","chore","mixed"]},
      "chapters":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","attention","hunks"],"properties":{"title":{"type":"string"},"attention":{"type":"string","enum":["focus","skim","skip"]},"hunks":{"type":"array","items":{"type":"string"}}}}},
      "contracts":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","kind","change","file","members"],"properties":{
         "name":{"type":"string"},
         "kind":{"type":"string","enum":["endpoint","type","table","event","config","function","cli"]},
         "change":{"type":"string","enum":["added","modified","removed"]},
         "file":{"type":"string"},
         "members":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","change"],"properties":{"name":{"type":"string"},"change":{"type":"string","enum":["added","modified","removed","unchanged"]}}}}}}},
      "notes":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["hunk","note"],"properties":{"hunk":{"type":"string"},"note":{"type":"string"}}}}
     }}
    """

    // MARK: The map

    static let mapSystem = """
    You are Fathom's cartographer. You draw the part of a system that a pull request touches as a layered diagram an \
    engineer reads in seconds. Labels only: no sentences, no opinions, no review.

    The diff is in your prompt. When the current directory holds the repository at the PR's head commit, use Glob, \
    Grep and Read to see how the changed code connects to the rest of the system — callers, entry points, stores, \
    services, external APIs. At most about 6 lookups, only for what the diff doesn't show. Then answer.

    Name things as the code does.

    Fields, in this order:
    - layers: 2–5, top to bottom. Top is closest to the user or the entry point (screens, routes, CLI); bottom is \
    storage, the OS or external services. name: at most 2 words, as this codebase would say ("SwiftUI views", \
    "Next.js API"). role: at most 4 words.
    - components: 4–14 boxes — types, modules, services, stores, endpoints, external APIs; not every file. Include \
    unchanged neighbours only when they explain a flow. name: at most 3 words, as in the code, no backticks. kind: the \
    closest fit. change. files: repo paths (empty for external services). role: at most 6 words, what it is ("Photo \
    carousel view", "Daily request budget").
    - edges: up to 18, directed from caller or sender to callee or receiver. label: at most 3 words ("fetch photos"). change.
    - flows: 1–3 runtime paths this PR creates or changes. title: at most 4 words. steps: in order, each along an \
    edge (from, to), label at most 4 words ("POST place", "cache miss").
    """

    static let mapSchema = """
    {"type":"object","additionalProperties":false,
     "required":["layers","components","edges","flows"],
     "properties":{
      "layers":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","name","role"],"properties":{"id":{"type":"string"},"name":{"type":"string"},"role":{"type":"string"}}}},
      "components":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","name","layer","kind","change","files","role"],"properties":{
         "id":{"type":"string"},"name":{"type":"string"},"layer":{"type":"string"},
         "kind":{"type":"string","enum":["ui","api","service","state","store","external","job","config","library","test"]},
         "change":{"type":"string","enum":["added","modified","removed","unchanged"]},
         "files":{"type":"array","items":{"type":"string"}},"role":{"type":"string"}}}},
      "edges":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","label","change"],"properties":{"from":{"type":"string"},"to":{"type":"string"},"label":{"type":"string"},"change":{"type":"string","enum":["added","modified","removed","unchanged"]}}}},
      "flows":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","steps"],"properties":{"title":{"type":"string"},"steps":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","label"],"properties":{"from":{"type":"string"},"to":{"type":"string"},"label":{"type":"string"}}}}}}}
     }}
    """

    // MARK: Questions

    static let askSystem = """
    You are Fathom, answering an engineer's question about a pull request they are reviewing. The first message holds \
    the PR and its diff with hunk ids (f3h2). When the current directory holds the repository at the PR's head commit, \
    use Read, Grep and Glob to check facts instead of guessing.

    Answer only what was asked, like a colleague at their desk: short and concrete, usually under 80 words. Lead with \
    the answer. Don't review the code or give opinions unless asked. Point at code as `path/to/file.ext:line`. Say \
    plainly when something is uncertain. Markdown sparingly; no headings.
    """

    static func askOpening(_ d: PRDetail, _ diff: ParsedDiff, brief: Brief, question: String) -> String {
        var s = "Here is the pull request I'm reviewing.\n\n" + prompt(d, diff, budget: 140_000)
        if !brief.headline.isEmpty { s += "\n\nIn one line: \(brief.headline)" }
        s += "\n\n# My question\n\(question)"
        return s
    }
}
