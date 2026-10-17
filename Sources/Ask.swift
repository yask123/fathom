// Ask: a glass bar at the bottom of every PR. Claude answers with the PR and the repo in front of it,
// and any `file:line` it mentions jumps to that line in Changes.

import SwiftUI

struct AskPanel: View {
    @Bindable var session: PRSession
    @State private var text = ""
    @FocusState private var focused: Bool

    private let suggestions = [
        "What calls this?",
        "Where does the data come from?",
        "What was here before?",
        "Which tests cover it?",
    ]

    var body: some View {
        VStack(spacing: 10) {
            if !session.askMessages.isEmpty {
                Conversation(session: session)
                    .frame(maxWidth: 780)
                    .transition(.opacity.combined(with: .offset(y: 16)))
            } else {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button {
                            session.ask(s)
                        } label: {
                            Text(s)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.text2)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.tint(Color.cardTint).interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            bar
        }
        .padding(.horizontal, 24)
        .animation(Motion.spring, value: session.askMessages.isEmpty)
        .onAppear { focused = true }
        .onChange(of: session.askFocusTick) { focused = true }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sonar)
                .symbolEffect(.pulse, isActive: session.askRunning)
            TextField("Ask anything about this pull request", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.text1)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
            if text.isEmpty {
                Text("⌘K")
                    .font(.mono(10.5, .semibold))
                    .foregroundStyle(Color.text3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.wash(0.06)))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.ink)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(session.askRunning ? Color.text3 : Color.sonar))
                }
                .buttonStyle(.plain)
                .disabled(session.askRunning)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: 620)
        .glassEffect(.regular.tint(Color.adaptive(light: 0xFFFFFF, dark: 0x0E141D, lightAlpha: 0.6, darkAlpha: 0.6)).interactive(), in: .capsule)
        .overlay {
            Capsule().strokeBorder(Color.sonar.opacity(focused ? 0.4 : 0.1), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func send() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !session.askRunning else { return }
        text = ""
        session.ask(q)
    }
}

struct Conversation: View {
    @Bindable var session: PRSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Eyebrow("Asking Claude")
                Text(session.checkout == nil ? "· diff only" : "· with the repo at this commit")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.text3)
                Spacer()
                Button("Clear") { session.clearAsk() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.text3)
                    .disabled(session.askRunning)
                Button {
                    withAnimation(Motion.spring) { session.askOpen = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.text3)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(session.askMessages) { m in
                            MessageView(session: session, message: m)
                                .id(m.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.never)
                .onChange(of: session.askMessages.last?.text) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: session.askMessages.count) {
                    withAnimation(Motion.soft) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.tint(Color.adaptive(light: 0xFAF8F2, dark: 0x0B1018, lightAlpha: 0.78, darkAlpha: 0.72)), in: .rect(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
    }
}

struct MessageView: View {
    @Bindable var session: PRSession
    let message: AskMessage

    var body: some View {
        if message.fromUser {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.text1)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.sonar.opacity(0.13)))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.sonar.opacity(0.2), lineWidth: 0.5))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if !message.activity.isEmpty {
                    ActivityLine(activity: message.activity, done: message.done)
                }
                if message.text.isEmpty && !message.done {
                    HStack(spacing: 8) {
                        SonarPip().frame(width: 14, height: 14)
                        Text(message.activity.isEmpty ? "Thinking…" : "Looking through the code…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.text3)
                    }
                } else {
                    MarkdownText(text: message.text, failed: message.failed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ActivityLine: View {
    let activity: [Activity]
    let done: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Motion.soft) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 10, weight: .semibold))
                    Text(summary)
                        .font(.system(size: 11))
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Color.text3)
            }
            .buttonStyle(.plain)
            if open || !done {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(open ? activity : Array(activity.suffix(2))) { a in
                        HStack(spacing: 6) {
                            Image(systemName: a.icon).font(.system(size: 9.5)).foregroundStyle(Color.sonar.opacity(0.7))
                            Text(a.verb).foregroundStyle(Color.text3)
                            Text(a.target).font(.mono(10.5)).foregroundStyle(Color.text2).lineLimit(1).truncationMode(.head)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(.leading, 2)
            }
        }
    }

    private var summary: String {
        let files = Set(activity.compactMap { $0.tool == "Read" ? $0.path : nil }).count
        let searches = activity.filter { $0.tool != "Read" }.count
        var parts: [String] = []
        if files > 0 { parts.append("read \(files) file\(files == 1 ? "" : "s")") }
        if searches > 0 { parts.append("\(searches) search\(searches == 1 ? "" : "es")") }
        return (done ? "Checked: " : "Checking: ") + parts.joined(separator: ", ")
    }
}

/// Just enough Markdown for answers: paragraphs, bullets, headings and fenced code.
struct MarkdownText: View {
    let text: String
    var failed = false

    enum Block: Hashable {
        case paragraph(String)
        case bullet(String, ordered: String?)
        case heading(String)
        case code(String, lang: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s):
                    Text(linked(s))
                        .font(.system(size: 13))
                        .lineSpacing(3.5)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let s, let ordered):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ?? "•")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.sonar.opacity(0.8))
                            .frame(minWidth: 10, alignment: .trailing)
                        Text(linked(s))
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .heading(let s):
                    Text(linked(s))
                        .font(.system(size: 13.5, weight: .semibold))
                        .padding(.top, 4)
                case .code(let s, let lang) where lang == "suggestion":
                    SuggestionBlock(lines: s.components(separatedBy: "\n"))
                case .code(let s, let lang):
                    let lines = s.components(separatedBy: "\n")
                    let painted = Highlighter.highlight(lines, Language(path: "x.\(lang.isEmpty ? "txt" : lang)"))
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(painted.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.mono(11.5))
                            }
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.never)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.well(0.32)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.wash(0.06), lineWidth: 0.5))
                }
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        var lang = ""
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))) }
            para = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code {
                    out.append(.code(c.joined(separator: "\n"), lang: lang))
                    code = nil
                } else {
                    flush()
                    code = []
                    lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2)), ordered: nil))
            } else if let r = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                flush()
                out.append(.bullet(String(line[r.upperBound...]), ordered: String(line[r]).trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"), lang: lang)) }
        flush()
        return out
    }

    static let sourceExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "kts", "c", "h", "cc", "cpp",
        "hpp", "m", "mm", "cs", "php", "dart", "scala", "ex", "exs", "lua", "sql", "sh", "zsh", "bash", "css", "scss",
        "html", "vue", "svelte", "erb", "json", "yml", "yaml", "toml", "md", "mdx", "xml", "plist", "gradle", "proto", "graphql",
    ]

    /// `src/app.ts:12` or `route.ts` — but not `brief.summary` or `self.view`.
    static func looksLikeFile(_ code: String) -> Bool {
        guard code.range(of: #"^[\w./@-]+\.\w+(:\d+(-\d+)?)?$"#, options: .regularExpression) != nil else { return false }
        let path = String(code.split(separator: ":").first ?? "")
        let ext = (path as NSString).pathExtension.lowercased()
        return sourceExtensions.contains(ext)
    }

    /// Inline markdown, with `path/file.ext:12` code spans turned into jump links.
    private func linked(_ s: String) -> AttributedString {
        var a = md(s, base: failed ? .changed : .text1.opacity(0.92), code: Color.adaptive(light: 0x155E59, dark: 0xBFE9E4), size: 13)
        for run in a.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            let code = String(a[run.range].characters)
            if MarkdownText.looksLikeFile(code),
               let url = URL(string: "fathom-ref://open?ref=" + (code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code)) {
                a[run.range].link = url
                a[run.range].underlineStyle = .single
            }
        }
        return a
    }
}

extension PRSession {
    /// Opens `path:line` from an answer: the line in Changes if it's in the diff, else the file on GitHub.
    func go(toReference url: URL) {
        let ref = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ref" }?.value ?? ""
        let parts = ref.split(separator: ":")
        let path = String(parts.first ?? "")
        let line = parts.count > 1 ? Int(parts[1].split(separator: "-").first ?? "") : nil
        guard let diff, let file = diff.file(path: path) else {
            if let sha = detail?.headSha, let web = URL(string: "https://github.com/\(self.ref.slug)/blob/\(sha)/\(path)\(line.map { "#L\($0)" } ?? "")") {
                NSWorkspace.shared.open(web)
            }
            return
        }
        if let line {
            for h in file.hunks {
                if let i = h.lines.firstIndex(where: { $0.new == line }) {
                    go(toHunk: h.id, anchor: "")
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(220))
                        scrollTarget = "line:\(h.id):\(i)"
                    }
                    return
                }
            }
            // The line isn't part of the diff: show it in context on GitHub.
            if let sha = detail?.headSha,
               let web = URL(string: "https://github.com/\(self.ref.slug)/blob/\(sha)/\(file.path)#L\(line)") {
                NSWorkspace.shared.open(web)
            }
            return
        }
        if let h = file.hunks.first { go(toHunk: h.id) }
    }
}

/// A ```suggestion block: the new text for the line, as GitHub shows it.
struct SuggestionBlock: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Suggested change", systemImage: "plus.forwardslash.minus")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.text3)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("+").foregroundStyle(Color.added)
                    Text(line.isEmpty ? " " : line).foregroundStyle(Color.text1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.mono(11.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.added.opacity(0.09))
            }
        }
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.well(0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.added.opacity(0.22), lineWidth: 0.5))
    }
}
