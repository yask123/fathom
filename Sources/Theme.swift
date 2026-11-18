// The look: near-black, one violet signal, and three neon inks that mean something (new, changed, gone).
// Monospace for names and labels, the system face for sentences. Neon only on the edges: wires, outlines, marks.

import AppKit
import SwiftUI

/// What the app is called, in one place.
enum Brand {
    static let name = "Tracer"
    static let line = "Follow the change."
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// A colour for each appearance: neon on black, and a deeper ink of the same hue for paper.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: .adaptive(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    /// A film over the page: white on black, ink on paper. Hairlines, hovers and wells.
    static func wash(_ opacity: Double) -> Color { Color(nsColor: .wash(opacity)) }

    /// A recessed field (a text box, a code block).
    static func well(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.black.withAlphaComponent(CGFloat(opacity))
                : NSColor(srgbRed: 0.2, green: 0.22, blue: 0.32, alpha: CGFloat(opacity * 0.2))
        })
    }

    /// The text that sits on a bright fill (a badge, a dot, a button).
    static let ink = Color(nsColor: .inkInk)
    static let hair = wash(0.09)

    static let canvas = adaptive(light: 0xF4F4F7, dark: 0x08090D)
    static let sidebar = adaptive(light: 0xECECF1, dark: 0x0B0C12)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x0F1118)
    static let sheet = adaptive(light: 0xF7F7FA, dark: 0x0C0D13)
    /// What a figure's labels sit on, so they mask the lines behind them: the canvas itself.
    static let paper = canvas

    static let text1 = adaptive(light: 0x14151B, dark: 0xECEEF5)
    static let text2 = adaptive(light: 0x4C505E, dark: 0x9CA2B2)
    static let text3 = Color(nsColor: .text3Ink)

    /// The one accent: the colour of the trace itself, of anything live or selected.
    static let signal = Color(nsColor: .signalInk)
    // What a mark means, the way a diff means it: new, changed, gone.
    static let added = Color(nsColor: .addedInk)
    static let changed = adaptive(light: 0xA36700, dark: 0xFFC857)
    static let removed = Color(nsColor: .removedInk)
    static let calm = adaptive(light: 0x2C6BD0, dark: 0x6FB6FF)
    static let merged = adaptive(light: 0x7048C2, dark: 0xB49CFF)
    /// A plain wire in a figure.
    static let stroke = adaptive(light: 0x3B3F4C, dark: 0xB9BFCE)
    /// The trace itself where nothing changed: light, with the signal colour as its halo.
    static let trace = adaptive(light: 0x2A2D3A, dark: 0xEFEBFF)
    /// The ground the trace is drawn on.
    static let stage = adaptive(light: 0xFFFFFF, dark: 0x0B0C13, lightAlpha: 0.75, darkAlpha: 0.72)
    /// The far end of the headline's gradient.
    static let headlineEnd = adaptive(light: 0x3A2FA0, dark: 0xC9BEFF)
    /// One hue per process the trace passes through. None of them green, amber or red: those mean new, changed, gone.
    static let lanes: [Color] = [
        .signal,
        adaptive(light: 0x2C6BD0, dark: 0x6FB6FF),
        adaptive(light: 0x0E8C99, dark: 0x5EE0E6),
        adaptive(light: 0xB8409A, dark: 0xF58AD8),
        adaptive(light: 0x5B62D6, dark: 0x8C9BFF),
    ]

    static let cardTint = adaptive(light: 0xFFFFFF, dark: 0x0E1017, lightAlpha: 0.6, darkAlpha: 0.55)
}

/// The same colours for what AppKit draws itself (the lines of a diff): each is defined here once, and the SwiftUI
/// colour above is made from it.
extension NSColor {
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(isDark ? darkAlpha : lightAlpha))
        }
    }

    static func wash(_ opacity: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.82, green: 0.85, blue: 1, alpha: CGFloat(opacity))
                : NSColor(srgbRed: 0.08, green: 0.09, blue: 0.14, alpha: CGFloat(opacity * 0.85))
        }
    }

    static let inkInk = adaptive(light: 0xFFFFFF, dark: 0x06070B)
    static let text3Ink = adaptive(light: 0x858A99, dark: 0x5F6577)
    static let signalInk = adaptive(light: 0x5F45E0, dark: 0xA88CFF)
    static let addedInk = adaptive(light: 0x0C8A5E, dark: 0x4DF0A8)
    static let removedInk = adaptive(light: 0xD22B5B, dark: 0xFF5D8F)
}

extension Font {
    /// Headlines: the system face, set tight.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
    /// Sentences.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Names from the code, labels, numbers, keys.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.9)
    static let soft = Animation.smooth(duration: 0.35)
    static let slow = Animation.smooth(duration: 0.9)
}

/// A label: small monospaced capitals, spaced out.
struct Eyebrow: View {
    let text: String
    var color: Color = .text3

    init(_ text: String, color: Color = .text3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.mono(10.5, .medium))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

/// A hairline rule.
struct Rule: View {
    var opacity = 0.09
    var body: some View { Rectangle().fill(Color.wash(opacity)).frame(height: 0.5) }
}

/// A section of the trace: a short lit tick, its name in capitals, a count or note, then a hairline to the edge.
struct SectionMark<Trailing: View>: View {
    let title: String
    var note = ""
    var tint: Color = .signal
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule().fill(tint).frame(width: 14, height: 2)
                .shadow(color: tint.opacity(0.7), radius: 4)
            Text(title.uppercased())
                .font(.mono(11, .semibold))
                .tracking(1.6)
                .foregroundStyle(Color.text1)
            if !note.isEmpty {
                Text(note)
                    .font(.mono(11))
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
            }
            Rule(opacity: 0.08)
            trailing
        }
    }
}

extension SectionMark where Trailing == EmptyView {
    init(title: String, note: String = "", tint: Color = .signal) {
        self.init(title: title, note: note, tint: tint) { EmptyView() }
    }
}

/// A key and what it does, for the line of hints under a figure: [space] play.
struct KeyHint: View {
    let key: String
    let does: String

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.mono(10, .medium))
                .foregroundStyle(Color.text2)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 17)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.wash(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.wash(0.14), lineWidth: 0.5))
            Text(does)
                .font(.mono(10.5))
                .foregroundStyle(Color.text3)
        }
    }
}

/// A quiet action in monospace: "code →".
struct InkButton: View {
    let title: String
    var icon: String? = "arrow.right"
    var leading: String? = nil
    var tint: Color = .text3
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let leading { Image(systemName: leading).font(.system(size: 9.5, weight: .semibold)) }
                Text(title).font(.mono(11, .medium))
                if let icon { Image(systemName: icon).font(.system(size: 8.5, weight: .bold)) }
            }
            .foregroundStyle(hover ? Color.text1 : tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
    }
}

/// Dots every 22 points, barely there: the board a figure is drawn on.
struct DotGrid: View {
    var step: CGFloat = 22

    var body: some View {
        Canvas { ctx, size in
            var dots = Path()
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    dots.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                    x += step
                }
                y += step
            }
            ctx.fill(dots, with: .color(.wash(0.085)))
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// A pane of Liquid Glass, for what floats over the page.
    func card(_ radius: CGFloat = 22, tint: Color = .cardTint, interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                    in: .rect(cornerRadius: radius, style: .continuous))
    }

    func hairline(_ radius: CGFloat, opacity: Double = 0.09) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.wash(opacity), lineWidth: 0.5)
        }
    }

    /// A soft halo in the dark; nothing on paper, where a glow only smudges.
    func neon(_ color: Color, radius: CGFloat = 8, strength: Double = 0.55) -> some View {
        modifier(NeonGlow(color: color, radius: radius, strength: strength))
    }
}

private struct NeonGlow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let color: Color
    let radius: CGFloat
    let strength: Double

    func body(content: Content) -> some View {
        content.shadow(color: scheme == .dark ? color.opacity(strength) : .clear, radius: radius)
    }
}

/// A flat, quiet card for anything that scrolls or redraws often (glass is kept for what floats).
struct Surface: View {
    var radius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.adaptive(light: 0xFFFFFF, dark: 0x0C0D14, lightAlpha: 0.75, darkAlpha: 0.8))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.wash(0.07), lineWidth: 0.75)
            }
    }
}

/// Whether the keyboard is in a text field or editor, so single-key shortcuts (j, k, n, p, x, ← →, space) stand aside.
enum Typing {
    @MainActor static var active: Bool { NSApp.keyWindow?.firstResponder is NSText }
}

/// Switches for screenshots. FATHOM_NO_HOVER=1 ignores the pointer, so a capture shows no hover state.
enum QA {
    static let env = ProcessInfo.processInfo.environment
    static let noHover = env["FATHOM_NO_HOVER"] == "1"
    /// FATHOM_FLOW=before or after opens the flow on that telling; FATHOM_STEP=3 opens it stopped on a step.
    static let flow = env["FATHOM_FLOW"] ?? "diff"
    static let step = env["FATHOM_STEP"].flatMap(Int.init)
    /// FATHOM_SECTION=end opens the trace scrolled to its end.
    static let section = env["FATHOM_SECTION"]
    /// Nothing moves: everything is drawn as it ends up. Set for a picture rendered off screen (FATHOM_RENDER).
    static let still = env["FATHOM_RENDER"] != nil || env["FATHOM_STILL"] == "1"
    static func hover(_ h: Bool) -> Bool { noHover ? false : h }
}

// MARK: - Semantic colours

extension Change {
    var color: Color {
        switch self {
        case .added: .added
        case .modified: .changed
        case .removed: .removed
        case .unchanged: .text3
        }
    }

    var word: String {
        switch self {
        case .added: "new"
        case .modified: "changed"
        case .removed: "removed"
        case .unchanged: "context"
        }
    }

    /// The mark a diff gives it.
    var sign: String {
        switch self {
        case .added: "+"
        case .modified: "~"
        case .removed: "−"
        case .unchanged: ""
        }
    }
}

enum Glyph {
    /// The mark for a part of the system, by what sort of thing it is.
    static func part(_ kind: String) -> String {
        switch kind {
        case "person": "person.fill"
        case "ui": "macwindow"
        case "service": "gearshape.fill"
        case "api": "point.3.connected.trianglepath.dotted"
        case "store": "cylinder.split.1x2.fill"
        case "external": "cloud.fill"
        case "job": "clock.arrow.2.circlepath"
        case "config": "slider.horizontal.3"
        case "library": "shippingbox.fill"
        default: "square.stack.3d.up.fill"
        }
    }

    static func kindWord(_ kind: String) -> String {
        switch kind {
        case "feature": "feature"
        case "fix": "fix"
        case "refactor": "refactor"
        case "performance": "perf"
        case "infra": "infra"
        case "tests": "tests"
        case "docs": "docs"
        case "chore": "chore"
        case "mixed": "mixed"
        default: kind.lowercased()
        }
    }
}

// MARK: - Small shared pieces

/// A round avatar that loads from GitHub and falls back to initials.
struct Avatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 20

    var body: some View {
        AsyncImage(url: sized) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                ZStack {
                    Circle().fill(Color.wash(0.1))
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Color.text2)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.wash(0.1), lineWidth: 0.5))
    }

    private var sized: URL? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = c.queryItems ?? []
        items.removeAll { $0.name == "s" }
        items.append(URLQueryItem(name: "s", value: String(Int(size * 2))))
        c.queryItems = items
        return c.url ?? url
    }
}

/// +12 −4 with a proportional bar.
struct DiffStat: View {
    let additions: Int
    let deletions: Int
    var bar: Bool = true
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(Color.added)
            Text("−\(deletions)").foregroundStyle(Color.removed)
            if bar {
                let total = max(additions + deletions, 1)
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { i in
                        let filledAdd = Int((Double(additions) / Double(total) * 5).rounded())
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < filledAdd ? Color.added : Color.removed)
                            .opacity(additions + deletions == 0 ? 0.2 : 0.85)
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
        .font(.mono(size, .medium))
        .monospacedDigit()
    }
}

enum Fmt {
    static func ago(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 30 { return "\(Int(s / 86400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "just now", "4h ago", "on Oct 3": for a sentence.
    static func since(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 86400 * 30 { return "\(ago(date)) ago" }
        return "on \(ago(date))"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "4.2 s"
    static func seconds(_ s: Double) -> String {
        s < 10 ? String(format: "%.1f s", s) : "\(Int(s.rounded())) s"
    }
}

/// Small helpers for the words Claude writes.
enum Prose {
    /// "only new routes stop navigation" → "Only new routes stop navigation."
    static func sentence(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces)
        // A name from the code keeps its case: "conversation-v4 header…", "placeDetail is…".
        let word = out.prefix { !$0.isWhitespace }
        let code = word.contains { $0.isNumber || "-_.()/:".contains($0) } || word.dropFirst().contains(where: \.isUppercase)
        if let first = out.first, first.isLowercase, !code { out = first.uppercased() + out.dropFirst() }
        if let last = out.last, !".!?".contains(last) { out += "." }
        return out
    }

    /// The same without the full stop, for a headline.
    static func title(_ s: String) -> String {
        var out = sentence(s)
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
