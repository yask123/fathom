// The Map tab: one line of what the PR does, then the system map. Click a part and its code opens beside it;
// play a flow and its steps do. Labels, not paragraphs.

import SwiftUI

struct MapView: View {
    @Bindable var session: PRSession

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14) {
                Headline(session: session)
                    .padding(.horizontal, 4)
                HStack(alignment: .top, spacing: 12) {
                    MapCanvas(session: session)
                    if let panel = session.panel {
                        SidePanel(session: session, panel: panel)
                            .frame(width: Self.panelWidth(geo.size.width))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    static func panelWidth(_ width: CGFloat) -> CGFloat { min(max(width * 0.44, 430), 680) }
}

/// What the PR does in one line, and a few quiet facts under it.
struct Headline: View {
    @Bindable var session: PRSession

    var body: some View {
        let b = session.brief
        VStack(alignment: .leading, spacing: 7) {
            if b.headline.isEmpty {
                if let failure = session.briefState.failure {
                    Failure(message: failure) { session.sound() }
                } else {
                    Skeleton(lines: [0.46], height: 24)
                        .frame(maxWidth: 820)
                }
            } else {
                Text(b.headline)
                    .font(.serif(25))
                    .tracking(-0.3)
                    .foregroundStyle(Color.text1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
            facts
        }
        .animation(Motion.soft, value: b.headline.isEmpty)
    }

    private var facts: some View {
        HStack(spacing: 8) {
            if !session.brief.kind.isEmpty {
                Text(Glyph.kindWord(session.brief.kind))
                dot
            }
            if let d = session.diff {
                Text("\(d.files.count) file\(d.files.count == 1 ? "" : "s")")
                dot
                DiffStat(additions: d.additions, deletions: d.deletions, bar: false, size: 11.5)
            }
            if session.isSounding {
                dot
                ReadingClock(session: session)
            } else if session.briefState.failure != nil && !session.brief.headline.isEmpty {
                dot
                Button("Outline incomplete · read again") { session.sound() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.changed)
            }
            Spacer(minLength: 12)
            if !session.map.isEmpty {
                MapKey(session: session)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.text3)
    }

    private var dot: some View {
        Text("·").foregroundStyle(Color.text3.opacity(0.6))
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
        if case .running(let d) = session.mapState { return d }
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
