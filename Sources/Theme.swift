// Fathom's look: deep ink water, one sonar accent, and depth hues for the layers of a system.

import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    static let ink = Color(hex: 0x06080C)
    static let ink2 = Color(hex: 0x0C1017)
    static let ink3 = Color(hex: 0x141A25)
    static let hair = Color.white.opacity(0.08)

    static let text1 = Color(hex: 0xE8EBF0)
    static let text2 = Color(hex: 0xA2AAB7)
    static let text3 = Color(hex: 0x6C7483)

    /// The one accent: the colour of a sonar return, kept quiet.
    static let sonar = Color(hex: 0x6CCDC8)
    // Meaning, in inks rather than neons: new, changed, removed.
    static let added = Color(hex: 0x6DC59B)
    static let changed = Color(hex: 0xD6AC6B)
    static let removed = Color(hex: 0xDE7B7B)
    static let calm = Color(hex: 0x8EA4C8)

    static let cardTint = Color(hex: 0x0D121A, alpha: 0.5)
    static let sidebarTint = Color(hex: 0x0A1016, alpha: 0.42)

    /// Layer hues, surface to abyss.
    static let depth: [Color] = [0x62E6DC, 0x5BB4F2, 0x7F8CF6, 0xA68AF2, 0xCB8BDF].map { Color(hex: $0) }
    static func depth(_ i: Int) -> Color { depth[max(0, min(i, depth.count - 1))] }
}

extension Font {
    /// STIX Two, the face of scientific journals, for titles and the story's sentences, with old-style figures.
    /// New York if it's missing.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Typeface.stix(size, weight: weight)
    }
    static func serifItalic(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Typeface.stix(size, weight: weight, italic: true)
    }
    /// Small capitals, as in a book's running heads and a journal's "Fig. 1.": every letter small, spaced by the caller.
    static func smallCaps(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Typeface.stix(size, weight: weight, caps: .all)
    }
    /// A run-in head: a capital, then small capitals ("Problem." as in a structured abstract).
    static func runIn(_ size: CGFloat) -> Font {
        Typeface.stix(size, caps: .lower)
    }
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

enum Typeface {
    static let hasSTIX = NSFont(name: "STIXTwoText", size: 12) != nil

    enum Caps { case none, lower, all }

    /// STIX Two Text with its OpenType features: old-style figures always, small capitals when asked.
    static func stix(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false, caps: Caps = .none) -> Font {
        guard hasSTIX else {
            let f = Font.system(size: size, weight: weight, design: .serif)
            return italic ? f.italic() : caps == .none ? f : f.smallCaps()
        }
        var traits: [NSFontDescriptor.TraitKey: Any] = [.weight: nsWeight(weight).rawValue]
        if italic { traits[.symbolic] = NSFontDescriptor.SymbolicTraits.italic.rawValue }
        var features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kNumberCaseType, .selectorIdentifier: kLowerCaseNumbersSelector],
        ]
        if caps != .none { features.append([.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]) }
        if caps == .all { features.append([.typeIdentifier: kUpperCaseType, .selectorIdentifier: kUpperCaseSmallCapsSelector]) }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: "STIX Two Text", .traits: traits, .featureSettings: features])
        guard let font = NSFont(descriptor: descriptor, size: size) else { return .system(size: size, design: .serif) }
        return Font(font as CTFont)
    }

    private static func nsWeight(_ w: Font.Weight) -> NSFont.Weight {
        switch w {
        case .medium: .medium
        case .semibold: .semibold
        case .bold, .heavy, .black: .bold
        default: .regular
        }
    }
}

/// A section label, set like a paper's: small monospaced capitals, spaced out.
struct Eyebrow: View {
    let text: String
    var color: Color = .text3

    init(_ text: String, color: Color = .text3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.smallCaps(12.5))
            .tracking(1.1)
            .foregroundStyle(color)
    }
}

/// A hairline rule.
struct Rule: View {
    var opacity = 0.08
    var body: some View { Rectangle().fill(Color.white.opacity(opacity)).frame(height: 0.5) }
}

/// A figure on a faint engineering grid with registration marks at its corners, and a caption under it set the
/// way journals set them: "Fig. 1." in small capitals, then the sentence.
struct Figure<Content: View>: View {
    let number: Int
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
                .padding(.vertical, 26)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity)
                .background(GridPaper())
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.045), lineWidth: 0.5))
                .overlay(CropMarks())
            if !caption.isEmpty {
                (Text("Fig. \(number).").font(.smallCaps(14)).foregroundStyle(Color.text2)
                 + Text("   " + caption).font(.serif(14.5)).foregroundStyle(Color.text3))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }
}

/// The small L-shaped marks a draughtsman puts at a plate's corners.
struct CropMarks: View {
    var body: some View {
        Canvas { ctx, size in
            let l: CGFloat = 9, inset: CGFloat = -0.5
            var p = Path()
            for (x, y, dx, dy) in [(inset, inset, 1.0, 1.0), (size.width - inset, inset, -1.0, 1.0),
                                   (inset, size.height - inset, 1.0, -1.0), (size.width - inset, size.height - inset, -1.0, -1.0)] {
                p.move(to: CGPoint(x: x + dx * l, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * l))
            }
            ctx.stroke(p, with: .color(.white.opacity(0.32)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }
}

/// A book's running head: where you are, in small capitals, over a hairline.
struct RunningHead: View {
    let left: String
    let right: String

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(left).lineLimit(1)
                Spacer(minLength: 20)
                Text(right).lineLimit(1)
            }
            .font(.smallCaps(12))
            .tracking(1.2)
            .foregroundStyle(Color.text3)
            Rule(opacity: 0.1)
        }
    }
}

/// The colour a figure's paper comes out as, for labels and parts that sit on it and mask the grid.
extension Color {
    static let paper = Color(hex: 0x0D1015)
}

/// Dots every 16 points, barely there: the paper the figures are drawn on.
struct GridPaper: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 16
            var dots = Path()
            var y = step
            while y < size.height {
                var x = step
                while x < size.width {
                    dots.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                    x += step
                }
                y += step
            }
            ctx.fill(dots, with: .color(.white.opacity(0.07)))
        }
        .background(Color.white.opacity(0.012))
        .allowsHitTesting(false)
    }
}

extension View {
    /// A pane of dark Liquid Glass.
    func card(_ radius: CGFloat = 22, tint: Color = .cardTint, interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                    in: .rect(cornerRadius: radius, style: .continuous))
    }

    func hairline(_ radius: CGFloat, opacity: Double = 0.08) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(opacity), lineWidth: 0.5)
        }
    }
}

/// A flat, quiet card for anything that scrolls or redraws often (glass is kept for the chrome).
struct Surface: View {
    var radius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(hex: 0x0A0E15).opacity(0.66))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.065), lineWidth: 0.75)
            }
    }
}

/// Whether the keyboard is in a text field or editor, so single-key shortcuts (j, k, n, p, x, ← →) stand aside.
enum Typing {
    @MainActor static var active: Bool { NSApp.keyWindow?.firstResponder is NSText }
}

/// Switches for screenshots. FATHOM_NO_HOVER=1 ignores the pointer, so a capture shows no hover state.
enum QA {
    static let noHover = ProcessInfo.processInfo.environment["FATHOM_NO_HOVER"] == "1"
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
        case .added: "New"
        case .modified: "Changed"
        case .removed: "Removed"
        case .unchanged: "Context"
        }
    }
}

enum Glyph {
    static func component(_ kind: String) -> String {
        switch kind {
        case "ui": "macwindow"
        case "api": "network"
        case "service": "gearshape.2"
        case "state": "circle.hexagongrid"
        case "store": "cylinder"
        case "external": "globe"
        case "job": "clock.arrow.2.circlepath"
        case "config": "slider.horizontal.3"
        case "library": "shippingbox"
        case "test": "checkmark.seal"
        default: "square"
        }
    }

    static func kindWord(_ kind: String) -> String {
        switch kind {
        case "feature": "Feature"
        case "fix": "Fix"
        case "refactor": "Refactor"
        case "performance": "Performance"
        case "infra": "Infrastructure"
        case "tests": "Tests"
        case "docs": "Docs"
        case "chore": "Chore"
        case "mixed": "Mixed"
        default: kind.capitalized
        }
    }
}

// MARK: - Backdrop

/// The window's water: still, deep, with a little light at the surface and grain.

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
                    Circle().fill(Color.ink3)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Color.text2)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
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
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
