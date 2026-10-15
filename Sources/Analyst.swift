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

    // MARK: The story

    static let storySystem = """
    You are Fathom's storyteller. An AI wrote this pull request and a bot has already checked that it does what it \
    claims. A senior engineer now wants to understand it the way they'd understand a colleague's design: what was \
    wrong, the one idea that fixes it, how things flow now, and the choices made along the way. You tell that as a \
    short illustrated story: a sentence and a small diagram per page. Plain words, names as in the code, no \
    opinions, no review, no praise, no risk talk.

    The diff is in your prompt. When the current directory holds the repository at the PR's head commit, you may use \
    Glob, Grep and Read to see how the changed code is called. At most about 4 lookups. Then answer.

    Every PR answers a problem. A bug fix: what went wrong. A feature: what you couldn't do before. A refactor: what \
    made the code hard to change. Infra or tests: what was fragile or slow.

    Fields, in this order:
    - problem.title: the situation before, at most 12 words, in terms of what a user or caller experienced ("Asking \
    a question mid-walk ended the walk"). Not the fix.
    - problem.steps: 2–5 steps of how it went before, as a sequence: from and to are actors (a person like "You", or \
    parts named as in the code), does is at most 6 words, data is what travels, at most 4 words, or empty.
    - problem.pain: at most 8 words, what goes wrong or what's missing. painStep: the index of the step where it \
    hurts, or -1 when the problem is that a step was missing.
    - idea.title: the key idea of the solution, at most 14 words, the way you'd say it at a whiteboard ("Answer \
    common questions on the phone; send only the rest to the server").
    - idea.parts: 2–6 parts that carry the idea. id, name as in the code, kind, new (added by this PR), role at most \
    5 words. idea.links: up to 7, from and to are part ids, label at most 4 words, new.
    - solution.title: how it works now, at most 12 words.
    - solution.steps: 2–7 steps, the same story as problem.steps told again after the change, with the same actor \
    names where they're the same part. new marks a step this PR adds.
    - choices: 1–4 design decisions a staff engineer would want to know about: where the PR chose one approach over \
    a reasonable other. title at most 8 words; chose at most 12 words; over, the alternative it didn't take, at most \
    10 words (empty if none is obvious); why at most 14 words; stated true when the PR description or a code comment \
    says why, false when you infer it. hunks: 1–2 hunk ids where the choice lives.
    - look: 2–4 hunks that carry the idea, the ones to read if you read nothing else, in reading order. why at most \
    10 words.
    """

    static let storySchema = """
    {"type":"object","additionalProperties":false,"required":["problem","idea","solution","choices","look"],"properties":{
     "problem":{"type":"object","additionalProperties":false,"required":["title","steps","pain","painStep"],"properties":{
       "title":{"type":"string"},
       "steps":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","does","data"],"properties":{"from":{"type":"string"},"to":{"type":"string"},"does":{"type":"string"},"data":{"type":"string"}}}},
       "pain":{"type":"string"},"painStep":{"type":"integer"}}},
     "idea":{"type":"object","additionalProperties":false,"required":["title","parts","links"],"properties":{
       "title":{"type":"string"},
       "parts":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","name","kind","new","role"],"properties":{"id":{"type":"string"},"name":{"type":"string"},"kind":{"type":"string","enum":["ui","api","service","state","store","external","job","config","library","test"]},"new":{"type":"boolean"},"role":{"type":"string"}}}},
       "links":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","label","new"],"properties":{"from":{"type":"string"},"to":{"type":"string"},"label":{"type":"string"},"new":{"type":"boolean"}}}}}},
     "solution":{"type":"object","additionalProperties":false,"required":["title","steps"],"properties":{
       "title":{"type":"string"},
       "steps":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","does","data","new"],"properties":{"from":{"type":"string"},"to":{"type":"string"},"does":{"type":"string"},"data":{"type":"string"},"new":{"type":"boolean"}}}}}},
     "choices":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","chose","over","why","stated","hunks"],"properties":{"title":{"type":"string"},"chose":{"type":"string"},"over":{"type":"string"},"why":{"type":"string"},"stated":{"type":"boolean"},"hunks":{"type":"array","items":{"type":"string"}}}}},
     "look":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["hunk","why"],"properties":{"hunk":{"type":"string"},"why":{"type":"string"}}}}
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
