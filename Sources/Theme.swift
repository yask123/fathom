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

    static let text1 = Color(hex: 0xEDF1F7)
    static let text2 = Color(hex: 0xA9B2C1)
    static let text3 = Color(hex: 0x6F7889)

    /// The one accent: the colour of a sonar return.
    static let sonar = Color(hex: 0x62E6DC)
    static let added = Color(hex: 0x5ED795)
    static let changed = Color(hex: 0xF4B860)
    static let removed = Color(hex: 0xF36F7F)
    static let calm = Color(hex: 0x8EA4C8)

    static let cardTint = Color(hex: 0x0D121A, alpha: 0.5)
    static let sidebarTint = Color(hex: 0x0A1016, alpha: 0.42)

    /// Layer hues, surface to abyss.
    static let depth: [Color] = [0x62E6DC, 0x5BB4F2, 0x7F8CF6, 0xA68AF2, 0xCB8BDF].map { Color(hex: $0) }
    static func depth(_ i: Int) -> Color { depth[max(0, min(i, depth.count - 1))] }
}

extension Font {
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
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

/// Small caps label above a section.
struct Eyebrow: View {
    let text: String
    var color: Color = .text3

    init(_ text: String, color: Color = .text3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(color)
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
    var radius: CGFloat = 22

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
