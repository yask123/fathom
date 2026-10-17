// Small pieces the story and the changes share: skeletons, the reading clock, markdown and interface cards.

import SwiftUI

// MARK: - Interfaces

struct InterfaceCard: View {
    @Bindable var session: PRSession
    let contract: Contract
    var fill = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.calm)
                Text(contract.name)
                    .font(.mono(12.5, .semibold))
                    .foregroundStyle(Color.text1)
                    .lineLimit(contract.name.contains(" ") ? 2 : 1)
                    .minimumScaleFactor(0.72)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                ChangeTag(change: contract.change)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.03))
            .overlay(alignment: .bottom) { Rule() }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(contract.members.prefix(8).enumerated()), id: \.offset) { _, m in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(sign(m.change))
                            .font(.mono(11, .bold))
                            .foregroundStyle(m.change == .unchanged ? Color.text3 : m.change.color)
                            .frame(width: 10)
                        Text(m.name)
                            .font(.mono(11))
                            .foregroundStyle(m.change == .unchanged ? Color.text3 : Color.text1.opacity(0.9))
                            .strikethrough(m.change == .removed, color: Color.removed.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if contract.members.count > 8 {
                    Text("+\(contract.members.count - 8) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                        .padding(.leading, 17)
                }
                if contract.members.isEmpty {
                    Text(contract.change == .added ? "new" : contract.change == .removed ? "removed" : "changed")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Text(contract.file)
                .font(.mono(10.5))
                .foregroundStyle(Color.text3)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: fill ? .infinity : 252, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(hex: 0x0B0F16).opacity(0.9)))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(hover ? Color.calm.opacity(0.55) : Color.white.opacity(0.1), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hover = QA.hover($0) }
        .onTapGesture { session.go(toFile: contract.file, containing: contract.name) }
        .help("\(contract.file) — click to read it in Changes")
        .animation(Motion.snappy, value: hover)
    }

    private var icon: String {
        switch contract.kind {
        case "endpoint": "network"
        case "type": "curlybraces"
        case "table": "tablecells"
        case "event": "bolt.horizontal"
        case "config": "slider.horizontal.3"
        case "function": "function"
        case "cli": "terminal"
        default: "square.on.square"
        }
    }

    private func sign(_ c: Change) -> String {
        switch c {
        case .added: "+"
        case .removed: "−"
        case .modified: "~"
        case .unchanged: "·"
        }
    }
}

struct ChangeTag: View {
    let change: Change

    var body: some View {
        if change != .unchanged {
            Text(change == .added ? "NEW" : change == .removed ? "REMOVED" : "CHANGED")
                .font(.mono(9, .medium))
                .tracking(1.2)
                .foregroundStyle(change.color)
        }
    }
}


/// "Reading 0:12", with a small ping, while Claude works.
struct ReadingClock: View {
    @Bindable var session: PRSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            HStack(spacing: 6) {
                SonarPip().frame(width: 12, height: 12)
                Text("Reading \(Fmt.clock(tl.date.timeIntervalSince(started)))")
                    .monospacedDigit()
            }
        }
    }

    private var started: Date {
        if case .running(let d) = session.briefState { return d }
        if case .running(let d) = session.storyState { return d }
        return .now
    }
}

// MARK: - Bits

/// The PR description as the author wrote it, minus template clutter.
enum AuthorNote {
    /// Drops HTML comments, images and badge clutter that PR templates leave behind.
    static func clean(_ body: String) -> String {
        var s = body.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<img[^>]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// GitHub comments as they read on github.com: HTML tidied, folded extras (tool output, prompts for agents) left
/// folded, and long ones shortened until asked.
enum GHText {
    static func clean(_ body: String) -> String {
        var s = AuthorNote.clean(body)
        s = s.replacingOccurrences(of: #"(?s)<details[^>]*>.*?</details>"#, with: "", options: [.regularExpression, .caseInsensitive])
        // Tags go only outside code: a suggestion or snippet keeps its <div>s.
        var lines: [String] = []
        var fence = false
        for line in s.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fence.toggle()
                lines.append(line)
            } else {
                lines.append(fence ? line : tidy(line))
            }
        }
        s = lines.joined(separator: "\n")
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of prose with its HTML taken out, leaving `inline code` alone.
    private static func tidy(_ line: String) -> String {
        line.components(separatedBy: "`").enumerated().map { i, part in
            guard i % 2 == 0 else { return part }
            return part
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"</?(details|summary|sub|sup|p|div|span|b|strong|i|em|blockquote|code|pre|table|tr|td|th|tbody|thead|a|h[1-6]|ul|ol|li|hr)\b[^>]*>"#,
                                      with: "", options: [.regularExpression, .caseInsensitive])
        }
        .joined(separator: "`")
    }

    /// The first paragraph or so of a long comment, cut where a paragraph ends; nil when it's short already.
    static func short(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard text.count > 900 || lines.count > 14 else { return nil }
        var out: [String] = []
        var count = 0
        var fence = false
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fence.toggle() }
            out.append(l)
            count += l.count
            if !fence && l.trimmingCharacters(in: .whitespaces).isEmpty && (count > 380 || out.count > 7) { break }
            if count > 650 && !fence { break }
        }
        if fence { out.append("```") }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + " …"
    }

    /// One line to stand for a folded conversation.
    static func firstLine(_ body: String) -> String {
        // Markdown marks out first, then escapes undone, so `snake\_case` and `a > b` read as written.
        let s = clean(body)
            .replacingOccurrences(of: #"(?m)^\s*(#{1,6}|>)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\\)(\*\*|__|`)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!>])"#, with: "$1", options: .regularExpression)
        return s.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
    }
}

struct Failure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.changed)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Try again", action: retry)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }
}

/// Shimmering placeholder lines while Claude is still thinking.
struct Skeleton: View {
    let lines: [CGFloat]
    var height: CGFloat = 12
    var spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                    ShimmerBar(radius: height / 2.4)
                        .frame(width: geo.size.width * w, height: height)
                }
            }
        }
        .frame(height: CGFloat(lines.count) * height + CGFloat(max(lines.count - 1, 0)) * spacing)
    }
}

/// Wraps chips onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

/// Parsed markdown, kept so streaming updates and hovers don't re-parse every paragraph on every frame.
private final class MarkdownMemo: @unchecked Sendable {
    static let shared = MarkdownMemo()
    private var store: [String: AttributedString] = [:]
    private let lock = NSLock()

    func value(_ key: String, make: () -> AttributedString) -> AttributedString {
        lock.lock()
        if let hit = store[key] { lock.unlock(); return hit }
        lock.unlock()
        let made = make()
        lock.lock()
        if store.count > 4000 { store.removeAll(keepingCapacity: true) }
        store[key] = made
        lock.unlock()
        return made
    }
}

/// Inline markdown (backticks, bold) as an AttributedString, with code in a brighter monospace.
func md(_ text: String, base: Color, code: Color, size: CGFloat? = nil) -> AttributedString {
    MarkdownMemo.shared.value("\(text)\u{1}\(base)\u{1}\(code)\u{1}\(size ?? 0)") {
        parseMarkdown(text, base: base, code: code, size: size)
    }
}

private func parseMarkdown(_ text: String, base: Color, code: Color, size: CGFloat?) -> AttributedString {
    var a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    a.foregroundColor = base
    for run in a.runs {
        if let intent = run.inlinePresentationIntent, intent.contains(.code) {
            a[run.range].foregroundColor = code
            a[run.range].font = .system(size: (size ?? 13) * 0.94, weight: .medium, design: .monospaced)
        }
    }
    return a
}

// MARK: - Environment

private struct InPanelKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Diff rows drawn inside the side panel drop what the panel already says (which part a file belongs to).
    var inPanel: Bool {
        get { self[InPanelKey.self] }
        set { self[InPanelKey.self] = newValue }
    }
}
