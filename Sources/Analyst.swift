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
    You are Fathom. An AI wrote this pull request and its tests pass. A senior engineer now wants to understand it the \
    way they'd understand a colleague's design at a whiteboard: how the system behaved before and how it behaves now, \
    the parts involved and what crosses between them, and the engineering idea it rests on. You draw; they think. \
    Write almost nothing: short phrases, names exactly as in the code. No praise, no filler, no hedging. Never use \
    words like robust, seamless, comprehensive, enhanced, leverage, ensure. If a phrase would fit any pull request, \
    cut it.

    The diff is in your prompt. When the current directory holds the repository at the PR's head commit, you may use \
    Glob, Grep and Read to see how the changed code is called. At most about 4 lookups. Then answer.

    Every PR answers a problem. A bug fix: what went wrong. A feature: what you couldn't do before. A refactor: what \
    made the code hard to change. Infra or tests: what was fragile or slow.

    Fields, in this order:
    - problem: the situation before, at most 12 words, as a user or caller experienced it ("Asking a question \
    mid-walk ended the walk"). Not the fix.
    - after: the same situation now, at most 12 words, as the user or caller experiences it.
    - flow: one request's journey through the system, told once for both versions, in time order: 3–9 steps. from \
    and to are actors: a person like "You", or parts named as in the code; from equals to for work a part does on \
    its own. does: at most 6 words. data: what travels, at most 4 words, or empty. status: same (happens before and \
    after), removed (only before), added (only after), or changed (both, differently). For a changed step, wasDoes \
    and wasData hold the old does and data where they differ; otherwise leave them empty. Keep actor names identical \
    across steps. The before journey is the same, changed and removed steps; the after journey is the same, changed \
    and added steps. Both must read as complete journeys.
    - breaks: the index in flow of the step where it went wrong before, or -1 when the problem was a step that was \
    missing. pain: at most 8 words, what goes wrong there.
    - move: the key idea of the fix, at most 14 words, the way you'd say it at a whiteboard ("Answer common \
    questions on the phone; send only the rest to the server").
    - parts: the system the change lives in, 3–7 parts. id; name as in the code; kind; change: added (by this PR), \
    changed (its code changes), or unchanged (context it talks to); role at most 5 words; where: the process or \
    deployable it runs in, at most 3 words ("iOS app", "API server", "Postgres", "GitHub Actions"), the same words \
    for parts that run together.
    - links: up to 8. from and to are part ids. label: what crosses that boundary, at most 4 words. change: added, \
    changed, removed or unchanged.
    - concept: the general engineering idea this change rests on, the one a reviewer would be glad to learn or \
    recall, by its usual name ("Local-first fallback", "Idempotency key", "Optimistic update with rollback", \
    "Debounce", "Versioned API"). name at most 4 words. gist: at most 28 words, the idea in general, with no project \
    names. here: at most 18 words, how this PR uses it. kin: at most 10 words, where engineers meet the same idea \
    elsewhere.
    - terms: 0–5 names from this codebase or domain a newcomer would trip on. term as written; meaning at most 12 words.
    """

    static let storySchema = """
    {"type":"object","additionalProperties":false,"required":["problem","after","flow","breaks","pain","move","parts","links","concept","terms"],"properties":{
     "problem":{"type":"string"},
     "after":{"type":"string"},
     "flow":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","does","data","status","wasDoes","wasData"],"properties":{"from":{"type":"string"},"to":{"type":"string"},"does":{"type":"string"},"data":{"type":"string"},"status":{"type":"string","enum":["same","removed","added","changed"]},"wasDoes":{"type":"string"},"wasData":{"type":"string"}}}},
     "breaks":{"type":"integer"},
     "pain":{"type":"string"},
     "move":{"type":"string"},
     "parts":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","name","kind","change","role","where"],"properties":{"id":{"type":"string"},"name":{"type":"string"},"kind":{"type":"string","enum":["ui","api","service","state","store","external","job","config","library","test"]},"change":{"type":"string","enum":["added","changed","unchanged"]},"role":{"type":"string"},"where":{"type":"string"}}}},
     "links":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","label","change"],"properties":{"from":{"type":"string"},"to":{"type":"string"},"label":{"type":"string"},"change":{"type":"string","enum":["added","changed","removed","unchanged"]}}}},
     "concept":{"type":"object","additionalProperties":false,"required":["name","gist","here","kin"],"properties":{"name":{"type":"string"},"gist":{"type":"string"},"here":{"type":"string"},"kin":{"type":"string"}}},
     "terms":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["term","meaning"],"properties":{"term":{"type":"string"},"meaning":{"type":"string"}}}}
    }}
    """

    // MARK: The critique

    static let critiqueSystem = """
    You are Fathom's referee. An AI wrote this pull request and its tests pass. A staff engineer must decide whether \
    to ship it, and wants their judgement to be fast and sharp: what the change trades away, what could go wrong in \
    production, and which questions deserve their attention. Be specific to this diff: name the parts, conditions and \
    values involved. Never give generic advice ("add more tests", "consider edge cases", "handle errors", "document \
    this"). Never invent problems: if something is fine, leave it out; fewer, truer items beat a full list. Plain \
    words, no praise, no hedging, names exactly as in the code.

    The diff is in your prompt. When the current directory holds the repository at the PR's head commit, you may use \
    Glob, Grep and Read to check who calls the changed code or what a value really is. At most about 5 lookups. Then \
    answer.

    Every hunk in the diff is labelled with an id like f3h2 (file 3, hunk 2). Refer to hunks only by these ids.

    Fields, in this order:
    - price: what the change costs or gives up, at most 14 words: its main trade-off in one line.
    - choices: 1–3 design decisions where a reasonable engineer could have gone another way. title: the question \
    decided, at most 7 words ("Where common questions are answered"). options: 2–3, the one this PR chose first, \
    each at most 4 words. criteria: 2–4 qualities that separate the options, at most 2 words each ("Latency", \
    "Works offline", "Code size"), each with a score per option from 0 to 4 (4 is best), in the options' order. \
    Score honestly: the chosen option should lose on something. why: at most 16 words, why this PR's option won. \
    stated: true when the PR description or a code comment says why, false when you infer it. hunks: 1–2 hunk ids \
    where the choice lives.
    - door: two-way when reverting this PR cleanly restores the old behaviour; one-way when something outlives a \
    revert: migrated or rewritten data, a published API, schema or file format, messages already sent, deleted \
    state, a shipped app version. doorWhy: at most 14 words.
    - risks: 0–4 ways this could fail in production, most serious first; none when there are none. title at most 8 \
    words. when: the trigger, at most 12 words. effect: who notices what, at most 10 words. likelihood and impact \
    from 1 (low) to 3 (high). guard: what in this diff prevents or catches it, at most 8 words, or empty when \
    nothing does. hunks: 1–2 hunk ids.
    - questions: 2–4 questions you would put to the author, ones the diff leaves open, about behaviour rather than \
    style, each answerable. q at most 20 words. why: at most 12 words, what hangs on the answer. hunk: the hunk id \
    where to look.
    - evidence: 2–4 hunks that carry the change, the ones to read if you read nothing else, in reading order. why at \
    most 10 words. marks: 1–3 lines worth a margin note: anchor is a fragment of one added line copied exactly, at \
    most 40 characters; note at most 8 words.
    """

    static let critiqueSchema = """
    {"type":"object","additionalProperties":false,"required":["price","choices","door","doorWhy","risks","questions","evidence"],"properties":{
     "price":{"type":"string"},
     "choices":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","options","criteria","why","stated","hunks"],"properties":{
       "title":{"type":"string"},
       "options":{"type":"array","items":{"type":"string"}},
       "criteria":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","scores"],"properties":{"name":{"type":"string"},"scores":{"type":"array","items":{"type":"integer"}}}}},
       "why":{"type":"string"},"stated":{"type":"boolean"},"hunks":{"type":"array","items":{"type":"string"}}}}},
     "door":{"type":"string","enum":["two-way","one-way"]},
     "doorWhy":{"type":"string"},
     "risks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","when","effect","likelihood","impact","guard","hunks"],"properties":{"title":{"type":"string"},"when":{"type":"string"},"effect":{"type":"string"},"likelihood":{"type":"integer"},"impact":{"type":"integer"},"guard":{"type":"string"},"hunks":{"type":"array","items":{"type":"string"}}}}},
     "questions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["q","why","hunk"],"properties":{"q":{"type":"string"},"why":{"type":"string"},"hunk":{"type":"string"}}}},
     "evidence":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["hunk","why","marks"],"properties":{"hunk":{"type":"string"},"why":{"type":"string"},"marks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["anchor","note"],"properties":{"anchor":{"type":"string"},"note":{"type":"string"}}}}}}}
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
