// Claude Code as a subprocess (`claude -p`), on the user's own subscription.
// Streams what Claude is looking at, the structured answer as it's being written, and plain text for chat.

import Foundation

struct Activity: Identifiable, Hashable, Sendable {
    let id = UUID()
    var tool: String      // Read, Grep, Glob, …
    var target: String    // a repo path or a search
    var path: String?     // repo-relative path when the tool touched a file
    var date = Date()

    var verb: String {
        switch tool {
        case "Read": "Reading"
        case "Grep": "Searching"
        case "Glob": "Looking for"
        default: tool
        }
    }

    var icon: String {
        switch tool {
        case "Read": "doc.text"
        case "Grep": "magnifyingglass"
        case "Glob": "folder"
        default: "sparkle"
        }
    }
}

struct ClaudeFinish: Sendable {
    var structured: Data?
    var text: String
    var isError: Bool
    var message: String
    var session: String
    var cost: Double
}

enum ClaudeEvent: Sendable {
    case started(session: String)
    case activity(Activity)
    case text(String)        // a text delta
    case structured(String)  // the StructuredOutput JSON written so far
    case finished(ClaudeFinish)
}

enum Claude {
    static var executable: String? { Shell.which("claude") }

    /// Flags Fathom can't read a PR without. Anything else it uses is left out when an older Claude Code lacks it.
    static let required: Set<String> = ["--print", "--model", "--output-format", "--verbose", "--include-partial-messages",
                                        "--json-schema", "--system-prompt", "--tools"]

    struct Abilities: Sendable {
        var flags: Set<String> = []
        var commands: Set<String> = []
        var isCurrent: Bool { Claude.required.isSubset(of: flags) }
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var abilities: [String: Abilities] = [:]
    }
    private static let cache = Cache()

    /// What this copy of Claude Code understands, read from `claude --help` once per binary.
    static func abilities(_ exe: String) async -> Abilities {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date
        let key = exe + "@" + String(stamp?.timeIntervalSince1970 ?? 0)
        if let known = cache.lock.withLock({ cache.abilities[key] }) { return known }
        guard let out = try? await Shell.run(exe, ["--help"], timeout: 20) else { return Abilities() }
        let help = out.text + "\n" + String(decoding: out.stderr, as: UTF8.self)
        var found = Abilities()
        let flag = #/--[a-z][a-z0-9-]+/#
        found.flags = Set(help.matches(of: flag).map { String($0.output) })
        // Subcommands are listed two spaces in, under "Commands:".
        if let section = help.range(of: "Commands:") {
            for line in help[section.upperBound...].split(separator: "\n") where line.hasPrefix("  ") && !line.hasPrefix("   ") {
                if let word = line.split(separator: " ").first?.split(separator: "|").first { found.commands.insert(String(word)) }
            }
        }
        cache.lock.withLock { cache.abilities[key] = found }
        return found
    }

    struct Options: Sendable {
        var model = "opus"
        var effort = "medium"
        var system: String
        var schema: String?
        var tools: [String] = []
        var cwd: URL
        var session: UUID?
        var resume = false
    }

    static func run(_ prompt: String, _ o: Options) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let exe = executable else {
                continuation.finish(throwing: ShellError(message: "Install Claude Code to let Fathom read PRs. Open Settings (⌘,) to set it up."))
                return
            }

            let root = o.cwd.standardizedFileURL.path
            let task = Task.detached {
                let can = await abilities(exe)
                guard can.isCurrent else {
                    continuation.finish(throwing: ShellError(message: "This Claude Code is too old for Fathom. Run `claude update` in Terminal."))
                    return
                }
                var args = ["-p", "--model", o.model, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                            "--system-prompt", o.system, "--tools", o.tools.joined(separator: ",")]
                // Keep the user's own MCP servers, hooks, skills and browser out of a read-only job.
                if can.flags.contains("--strict-mcp-config") { args.append("--strict-mcp-config") }
                if can.flags.contains("--setting-sources") { args += ["--setting-sources", ""] }
                if can.flags.contains("--disable-slash-commands") { args.append("--disable-slash-commands") }
                if can.flags.contains("--no-chrome") { args.append("--no-chrome") }
                if can.flags.contains("--permission-prompts") { args += ["--permission-prompts", "none"] }
                if can.flags.contains("--effort") { args += ["--effort", o.effort] }
                if let schema = o.schema { args += ["--json-schema", schema] }
                if let s = o.session, can.flags.contains("--session-id"), can.flags.contains("--resume") {
                    args += o.resume ? ["--resume", s.uuidString.lowercased()] : ["--session-id", s.uuidString.lowercased()]
                } else if can.flags.contains("--no-session-persistence") {
                    args += ["--no-session-persistence"]
                }

                var structuredIndex: Int?
                var structuredText = ""
                var finished = false
                var wroteText = false
                var newMessage = false
                do {
                    for try await line in Shell.lines(exe, args, cwd: o.cwd, input: Data(prompt.utf8)) {
                        if Task.isCancelled { break }
                        let e = J(data: Data(line.utf8))
                        switch e["type"].string {
                        case "system" where e["subtype"].string == "init":
                            continuation.yield(.started(session: e["session_id"].string))
                        case "stream_event":
                            let ev = e["event"]
                            switch ev["type"].string {
                            case "message_start":
                                structuredIndex = nil
                                newMessage = true
                            case "content_block_start":
                                if ev["content_block"]["type"].string == "tool_use", ev["content_block"]["name"].string == "StructuredOutput" {
                                    structuredIndex = ev["index"].int
                                    structuredText = ""
                                }
                            case "content_block_delta":
                                let d = ev["delta"]
                                if d["type"].string == "input_json_delta", ev["index"].int == structuredIndex {
                                    structuredText += d["partial_json"].string
                                    continuation.yield(.structured(structuredText))
                                } else if d["type"].string == "text_delta" {
                                    // Text from a later turn (after a tool call) starts a new paragraph.
                                    if newMessage && wroteText { continuation.yield(.text("\n\n")) }
                                    newMessage = false
                                    wroteText = true
                                    continuation.yield(.text(d["text"].string))
                                }
                            default: break
                            }
                        case "assistant":
                            for c in e["message"]["content"].array where c["type"].string == "tool_use" {
                                let name = c["name"].string
                                guard name != "StructuredOutput" else { continue }
                                continuation.yield(.activity(activity(name, c["input"], root: root)))
                            }
                        case "result":
                            finished = true
                            var data: Data?
                            if e["structured_output"].exists, let raw = e["structured_output"].raw,
                               JSONSerialization.isValidJSONObject(raw) {
                                data = try? JSONSerialization.data(withJSONObject: raw)
                            }
                            let text = e["result"].string
                            if data == nil, e["is_error"].bool == false, text.hasPrefix("{") { data = Data(text.utf8) }
                            let isError = e["is_error"].bool
                            continuation.yield(.finished(ClaudeFinish(
                                structured: data, text: text, isError: isError,
                                message: isError ? friendly(text.isEmpty ? e["subtype"].string : text) : "",
                                session: e["session_id"].string, cost: e["total_cost_usd"].double)))
                        default: break
                        }
                    }
                    if !finished && !Task.isCancelled {
                        continuation.finish(throwing: ShellError(message: "Claude stopped before answering"))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    // Once the result is in, a non-zero exit adds nothing; keep Claude's own message.
                    if finished {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: ShellError(message: friendly(error.localizedDescription)))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func activity(_ tool: String, _ input: J, root: String) -> Activity {
        func rel(_ p: String) -> String {
            var s = p
            if s.hasPrefix(root + "/") { s.removeFirst(root.count + 1) }
            else if let r = s.range(of: "/private" + root + "/") { s = String(s[r.upperBound...]) }
            return s
        }
        switch tool {
        case "Read":
            let p = rel(input["file_path"].string)
            return Activity(tool: tool, target: p, path: p)
        case "Grep":
            var t = input["pattern"].string
            if t.count > 48 { t = String(t.prefix(46)) + "…" }
            let p = input["path"].stringOrNil.map(rel)
            return Activity(tool: tool, target: t, path: p)
        case "Glob":
            return Activity(tool: tool, target: input["pattern"].string, path: nil)
        default:
            return Activity(tool: tool, target: "", path: nil)
        }
    }

    static func friendly(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("login") || m.contains("log in") || m.contains("authenticat") || m.contains("oauth") {
            return "Claude Code isn't signed in. Open Settings (⌘,) to sign in."
        }
        if m.contains("usage limit") || m.contains("rate limit") || m.contains("limit reached") {
            return "You've hit your Claude usage limit for now. Try again after it resets."
        }
        if m.contains("overloaded") { return "Claude is overloaded right now. Try again in a minute." }
        return String(message.prefix(300))
    }
}

/// Closes a JSON document that was cut off mid-stream so it parses, keeping a half-written string value.
/// Unfinished keys, numbers and literals are dropped back to the last complete member.
enum PartialJSON {
    private enum State { case objKey, objColon, objValue, objNext, arrValue, arrNext }
    private struct Frame {
        var isObject: Bool
        var state: State
        var safeEnd: Int
    }

    static func parse(_ text: String) -> Any? {
        guard let done = complete(text) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(done.utf8))
    }

    static func complete(_ text: String) -> String? {
        let b = Array(text.utf8)
        var stack: [Frame] = []
        var inString = false, stringIsKey = false, escape = false
        var unicodeLeft = 0, unicodeStart = 0
        var literal = false
        var started = false
        var rootDone = false

        func valueDone(_ end: Int) {
            if stack.isEmpty { rootDone = true; return }
            stack[stack.count - 1].state = stack[stack.count - 1].isObject ? .objNext : .arrNext
            stack[stack.count - 1].safeEnd = end
        }

        var i = 0
        while i < b.count {
            let c = b[i]
            if inString {
                if unicodeLeft > 0 { unicodeLeft -= 1 }
                else if escape {
                    escape = false
                    if c == 0x75 { unicodeLeft = 4; unicodeStart = i - 1 }
                }
                else if c == 0x5C { escape = true }
                else if c == 0x22 {
                    inString = false
                    if stringIsKey { stack[stack.count - 1].state = .objColon } else { valueDone(i + 1) }
                }
                i += 1
                continue
            }
            if literal {
                if c == 0x2C || c == 0x7D || c == 0x5D || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 {
                    literal = false
                    valueDone(i)
                } else {
                    i += 1
                    continue
                }
            }
            switch c {
            case 0x7B:
                started = true
                stack.append(Frame(isObject: true, state: .objKey, safeEnd: i + 1))
            case 0x5B:
                started = true
                stack.append(Frame(isObject: false, state: .arrValue, safeEnd: i + 1))
            case 0x7D, 0x5D:
                if !stack.isEmpty { stack.removeLast() }
                valueDone(i + 1)
            case 0x22:
                inString = true
                stringIsKey = stack.last.map { $0.isObject && $0.state == .objKey } ?? false
            case 0x3A:
                if !stack.isEmpty { stack[stack.count - 1].state = .objValue }
            case 0x2C:
                if let top = stack.last { stack[stack.count - 1].state = top.isObject ? .objKey : .arrValue }
            case 0x20, 0x0A, 0x0D, 0x09:
                break
            default:
                literal = true
            }
            i += 1
        }

        guard started else { return nil }
        if stack.isEmpty { return rootDone ? text : nil }

        var cut = b.count
        var tail: [UInt8] = []
        if inString {
            if stringIsKey {
                cut = stack[stack.count - 1].safeEnd
            } else {
                var end = b.count
                if escape { end -= 1 }
                if unicodeLeft > 0 { end = unicodeStart }   // a half-written \uXXXX
                cut = end
                tail = [0x22]
            }
        } else if literal {
            cut = stack[stack.count - 1].safeEnd
        } else {
            switch stack[stack.count - 1].state {
            case .objKey, .objColon, .objValue, .arrValue: cut = stack[stack.count - 1].safeEnd
            case .objNext, .arrNext: break
            }
        }
        var out = Array(b[0..<cut]) + tail
        for f in stack.reversed() { out.append(f.isObject ? 0x7D : 0x5D) }
        return String(decoding: out, as: UTF8.self)
    }
}
