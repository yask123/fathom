// The lines of a diff, drawn. A run of up to two dozen lines is one AppKit view that draws its own gutter, signs,
// tints and text with Core Text. (One SwiftUI view per line, each with its own text layout, hover tracking and clip,
// made the Code tab stutter: a screenful was ~50 views to build and measure every time it scrolled into sight.)
// AppKit asks a canvas to draw again as it scrolls, so drawing is kept cheap: lines are typeset once and kept, and
// only the lines in the strip being asked for are drawn.

import AppKit
import SwiftUI

/// Every line of the diff, coloured, as the canvas wants it. Built off the main thread, read on it.
final class CodeLines: @unchecked Sendable {
    let lines: [String: NSAttributedString]   // "f3h2:17" → the line
    init(_ lines: [String: NSAttributedString]) { self.lines = lines }
}

enum CodeStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let lineHeight: CGFloat = 18
    /// A wrapped line's further rows sit a little closer.
    static let wrapHeight: CGFloat = 16
    static let numberWidth: CGFloat = 42
    static let signWidth: CGFloat = 24
    static var textX: CGFloat { numberWidth * 2 + signWidth }
    /// The change rail: a line of light between the numbers and the code, solid where lines were added and dashed
    /// where they were removed (the trace page's own marks for new and gone).
    static var railX: CGFloat { numberWidth * 2 + 4 }
    static let railWidth: CGFloat = 2
    /// Removed code is a ghost: still readable, but the eye lands on what's new.
    static let ghost: CGFloat = 0.66
    static let trailing: CGFloat = 14
    static let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    static let ascent = CTFontGetAscent(font)
    static let descent = CTFontGetDescent(font)
    /// How many lines one view draws. More means fewer views; fewer means a smaller picture to keep per view.
    static let chunk = 24
    /// The colour behind the words that changed inside an edited line. Its own key, not `.backgroundColor`: Core
    /// Text draws that one itself, and upside down here, where the text is flipped for a top-down view.
    static let mark = NSAttributedString.Key("TracerChangedWords")
    /// Behind selected code.
    static let selection = NSColor.adaptive(light: 0x5F45E0, dark: 0xA88CFF, lightAlpha: 0.22, darkAlpha: 0.32)

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.replacingOccurrences(of: "\t", with: "    "),
                           attributes: [.font: font, .foregroundColor: CodeInk.textNS])
    }
}

struct CodeChunk: NSViewRepresentable {
    let hunk: Hunk
    let range: Range<Int>
    let last: Bool
    let code: CodeLines?
    let stamp: Int
    /// A line to light up for a moment (where a jump landed), as its index in the hunk.
    let flash: Int?
    /// What's selected in the diff; each canvas draws its part.
    let selection: CodeSelection
    /// Called with a line's index in the hunk when its number is clicked.
    let comment: (Int) -> Void

    func makeNSView(context: Context) -> ChunkCanvas {
        let v = ChunkCanvas()
        fill(v)
        return v
    }

    func updateNSView(_ v: ChunkCanvas, context: Context) { fill(v) }

    private func fill(_ v: ChunkCanvas) {
        v.comment = comment
        v.selection = selection
        v.hunkId = hunk.id
        selection.register(v)
        // The lines just before and after this run, so a rail that carries on into the next canvas isn't capped here.
        v.before = range.lowerBound > 0 ? hunk.lines[range.lowerBound - 1].kind : nil
        v.after = range.upperBound < hunk.lines.count ? hunk.lines[range.upperBound].kind : nil
        v.load(key: "\(hunk.id):\(range.lowerBound)-\(range.upperBound):\(stamp):\(last)", first: range.lowerBound, last: last) {
            range.map { i in
                let l = hunk.lines[i]
                return ChunkCanvas.Line(kind: l.kind, old: l.old, new: l.new,
                                        text: code?.lines["\(hunk.id):\(i)"] ?? CodeStyle.plain(l.text))
            }
        }
        v.setFlash(flash.flatMap { range.contains($0) ? $0 - range.lowerBound : nil })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChunkCanvas, context: Context) -> CGSize? {
        var w = proposal.width ?? nsView.bounds.width
        if !w.isFinite || w <= 0 { w = max(nsView.bounds.width, 600) }
        return CGSize(width: w, height: nsView.height(for: w))
    }
}

final class ChunkCanvas: NSView {
    struct Line {
        var kind: LineKind
        var old: Int?
        var new: Int?
        var text: NSAttributedString
    }

    var comment: ((Int) -> Void)?
    weak var selection: CodeSelection?
    var hunkId = ""
    var before: LineKind?
    var after: LineKind?

    /// Counts for the scroll benchmark: canvases alive, times one was asked to draw, and lines drawn.
    nonisolated(unsafe) static var alive = 0
    nonisolated(unsafe) static var made = 0
    nonisolated(unsafe) static var draws = 0
    nonisolated(unsafe) static var linesDrawn = 0

    private var lines: [Line] = []
    private var key = ""
    private var first = 0
    private var last = false
    private var flash: Int?
    private var hover: Int?
    private var tracking: NSTrackingArea?
    /// Each line typeset, kept between draws: its rows (one, or several when it wraps) and its two numbers.
    private var set: [[CTLine]?] = []
    private var numbers: [(old: CTLine?, new: CTLine?)?] = []

    // Where each line sits at the width last laid out; a line too long for it breaks into rows.
    private var laidWidth: CGFloat = -1
    private var tops: [CGFloat] = []
    private var breaks: [[CFRange]?] = []
    private var total: CGFloat = 0

    init() {
        super.init(frame: .zero)
        Self.alive += 1
        Self.made += 1
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// A drag here selects code; it never moves the window.
    override var mouseDownCanMoveWindow: Bool { false }

    func load(key: String, first: Int, last: Bool, lines make: () -> [Line]) {
        guard key != self.key else { return }
        self.key = key
        self.first = first
        self.last = last
        lines = make()
        laidWidth = -1
        hover = nil
        setAccessibilityValue(lines.map(\.text.string).joined(separator: "\n"))
        needsDisplay = true
    }

    func setFlash(_ line: Int?) {
        guard line != flash else { return }
        flash = line
        needsDisplay = true
    }

    func height(for width: CGFloat) -> CGFloat {
        layout(width)
        return total
    }

    private func height(_ i: Int) -> CGFloat {
        guard let rows = breaks[i], rows.count > 1 else { return CodeStyle.lineHeight }
        return CodeStyle.lineHeight + CGFloat(rows.count - 1) * CodeStyle.wrapHeight
    }

    private func layout(_ width: CGFloat) {
        guard width != laidWidth || tops.count != lines.count else { return }
        laidWidth = width
        let room = max(width - CodeStyle.textX - CodeStyle.trailing, 80)
        tops = []
        breaks = []
        set = Array(repeating: nil, count: lines.count)
        numbers = Array(repeating: nil, count: lines.count)
        var y: CGFloat = 0
        for line in lines {
            let length = line.text.length
            var rows: [CFRange]?
            // Almost every line fits: a monospaced one does when its characters do, with no measuring. (A line with
            // wide characters could be a little longer than it counts; the slack covers the usual few.)
            if CGFloat(length) * CodeStyle.charWidth > room - 2 * CodeStyle.charWidth {
                let setter = CTTypesetterCreateWithAttributedString(line.text)
                var start = 0
                var found: [CFRange] = []
                while start < length {
                    let count = max(CTTypesetterSuggestLineBreak(setter, start, Double(room)), 1)
                    found.append(CFRange(location: start, length: count))
                    start += count
                    // A line that would run to hundreds of rows (a minified file) stops at forty.
                    if found.count >= 40 { break }
                }
                if found.count > 1 { rows = found }
            }
            tops.append(y)
            breaks.append(rows)
            y += rows.map { CodeStyle.lineHeight + CGFloat($0.count - 1) * CodeStyle.wrapHeight } ?? CodeStyle.lineHeight
        }
        total = y
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        set = Array(repeating: nil, count: lines.count)
        numbers = Array(repeating: nil, count: lines.count)
        needsDisplay = true
    }

    deinit { Self.alive -= 1 }


    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !lines.isEmpty else { return }
        Self.draws += 1
        layout(bounds.width)
        if last {
            // The hunk's foot is rounded, like the file header's top.
            let r = bounds, radius: CGFloat = 5
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - radius, y: r.maxY), radius: radius)
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - radius), radius: radius)
            p.closeSubpath()
            ctx.addPath(p)
            ctx.clip()
        }
        NSColor.wash(0.03).setFill()
        bounds.fill(using: .sourceOver)

        let baseline = (CodeStyle.lineHeight - (CodeStyle.ascent + CodeStyle.descent)) / 2 + CodeStyle.ascent
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        for (i, line) in lines.enumerated() {
            let top = tops[i], h = height(i)
            let rect = CGRect(x: 0, y: top, width: bounds.width, height: h)
            guard rect.intersects(dirtyRect) else { continue }
            Self.linesDrawn += 1
            let hovered = hover == i

            let changed = line.kind == .add || line.kind == .del
            let railX = CodeStyle.railX
            if changed {
                // The tint starts at the rail and fades to the right, so a long run of changes reads as light
                // falling from the line, not as a slab of colour. The gutter stays dark.
                ctx.saveGState()
                ctx.clip(to: CGRect(x: railX, y: top, width: bounds.width - railX, height: h))
                ctx.drawLinearGradient(Self.wash(line.kind, hovered: hovered, dark: dark),
                                       start: CGPoint(x: railX, y: 0), end: CGPoint(x: max(bounds.width, railX + 400), y: 0), options: [])
                ctx.restoreGState()
                if hovered { NSColor.wash(0.03).setFill(); CGRect(x: 0, y: top, width: railX, height: h).fill(using: .sourceOver) }
            } else if hovered {
                NSColor.wash(0.03).setFill(); rect.fill(using: .sourceOver)
            }
            if flash == i {
                NSColor.signalInk.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
            }

            // The rail. Added lines join into one unbroken line with a soft glow; each removed line is a dash.
            if changed {
                let ink = line.kind == .add ? NSColor.addedInk : NSColor.removedInk
                let starts = (i > 0 ? lines[i - 1].kind : before) != line.kind
                let ends = (i + 1 < lines.count ? lines[i + 1].kind : after) != line.kind
                var y0 = top, y1 = top + h
                if line.kind == .del {
                    y0 += 4; y1 -= 4
                } else {
                    if starts { y0 += 2 }
                    if ends { y1 -= 2 }
                    ink.withAlphaComponent(0.09).setFill()
                    CGRect(x: railX - 4, y: y0, width: CodeStyle.railWidth + 8, height: y1 - y0).fill(using: .sourceOver)
                    ink.withAlphaComponent(0.2).setFill()
                    CGRect(x: railX - 1.5, y: y0, width: CodeStyle.railWidth + 3, height: y1 - y0).fill(using: .sourceOver)
                }
                ink.withAlphaComponent(line.kind == .add ? 1 : 0.85).setFill()
                let bar = CGRect(x: railX, y: y0, width: CodeStyle.railWidth, height: y1 - y0)
                if line.kind == .del || starts || ends {
                    NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                    // A cap is rounded only where the run really ends; the other end stays square to meet its neighbour.
                    if line.kind == .add && !starts { CGRect(x: railX, y: y0, width: CodeStyle.railWidth, height: 2).fill(using: .sourceOver) }
                    if line.kind == .add && !ends { CGRect(x: railX, y: y1 - 2, width: CodeStyle.railWidth, height: 2).fill(using: .sourceOver) }
                } else {
                    bar.fill(using: .sourceOver)
                }
            }

            // The gutter: old and new line numbers, right-aligned in their columns. A changed line's own number
            // takes the change's colour; all of them brighten under the pointer.
            let pair = numbers[i] ?? {
                let made = (old: line.old.map { Self.number($0, line.kind == .del ? .removedInk : .text3Ink) },
                            new: line.new.map { Self.number($0, line.kind == .add ? .addedInk : .text3Ink) })
                numbers[i] = made
                return made
            }()
            ctx.saveGState()
            ctx.setAlpha(hovered ? 0.95 : changed ? 0.78 : 0.5)
            for (column, n, ct) in [(0, line.old, pair.old), (1, line.new, pair.new)] {
                guard let n, let ct else { continue }
                let w = CGFloat(n < 10 ? 1 : n < 100 ? 2 : n < 1000 ? 3 : n < 10000 ? 4 : n < 100000 ? 5 : 6) * CodeStyle.charWidth
                ctx.textPosition = CGPoint(x: CGFloat(column + 1) * CodeStyle.numberWidth - w - 4, y: top + baseline)
                CTLineDraw(ct, ctx)
            }
            ctx.restoreGState()

            // The sign, or the comment button while the pointer is on the line.
            let signX = railX + CodeStyle.railWidth
            let signW = CodeStyle.textX - signX
            if hovered {
                let b = CGRect(x: signX + (signW - 16) / 2, y: top + (CodeStyle.lineHeight - 16) / 2, width: 16, height: 16)
                NSColor.signalInk.setFill()
                NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).fill()
                ctx.setStrokeColor(NSColor.inkInk.cgColor)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: b.midX - 3.5, y: b.midY)); ctx.addLine(to: CGPoint(x: b.midX + 3.5, y: b.midY))
                ctx.move(to: CGPoint(x: b.midX, y: b.midY - 3.5)); ctx.addLine(to: CGPoint(x: b.midX, y: b.midY + 3.5))
                ctx.strokePath()
            } else if changed {
                ctx.saveGState()
                ctx.setAlpha(0.7)
                ctx.textPosition = CGPoint(x: signX + (signW - CodeStyle.charWidth) / 2, y: top + baseline)
                CTLineDraw(line.kind == .add ? Self.plus : Self.minus, ctx)
                ctx.restoreGState()
            }

            // The text: one Core Text line, or one per row when it wraps.
            let rows = typeset(i)
            if let picked = selected(i) { paintSelection(picked, line: i, rows: rows, top: top) }
            let ghost = line.kind == .del && !hovered
            if ghost { ctx.saveGState(); ctx.setAlpha(CodeStyle.ghost) }
            for (k, ct) in rows.enumerated() {
                let range = breaks[i]?[k] ?? CFRange(location: 0, length: line.text.length)
                drawLine(ct, of: line.text, range: range, in: ctx, y: top + baseline + CGFloat(k) * CodeStyle.wrapHeight)
            }
            if ghost { ctx.restoreGState() }
        }
    }

    /// A line's rows, typeset the first time they're needed and then kept.
    private func typeset(_ i: Int) -> [CTLine] {
        if let made = set[i] { return made }
        let text = lines[i].text
        let made: [CTLine]
        if let ranges = breaks[i] {
            let setter = CTTypesetterCreateWithAttributedString(text)
            made = ranges.map { CTTypesetterCreateLine(setter, $0) }
        } else {
            made = [CTLineCreateWithAttributedString(text)]
        }
        set[i] = made
        return made
    }

    private func rowRange(_ i: Int, _ k: Int) -> CFRange {
        breaks[i]?[k] ?? CFRange(location: 0, length: lines[i].text.length)
    }

    // MARK: Selection

    private var order: Int? { selection?.order(of: hunkId) }

    /// The part of line `i` that's selected: from, to, and whether the selection runs on past its end.
    private func selected(_ i: Int) -> (from: Int, to: Int, on: Bool)? {
        guard let range = selection?.range, let o = order else { return nil }
        let key = LineKey(order: o, line: first + i)
        guard key >= range.lo.row, key <= range.hi.row else { return nil }
        let isLast = key == range.hi.row
        let from = key == range.lo.row ? range.lo.char : 0
        let to = isLast ? range.hi.char : lines[i].text.length
        guard from < to || !isLast else { return nil }
        return (from, to, !isLast)
    }

    private func paintSelection(_ picked: (from: Int, to: Int, on: Bool), line i: Int, rows: [CTLine], top: CGFloat) {
        CodeStyle.selection.setFill()
        for (k, ct) in rows.enumerated() {
            let r = rowRange(i, k)
            let y = top + CGFloat(k) * CodeStyle.wrapHeight
            let h = k == rows.count - 1 ? CodeStyle.lineHeight : CodeStyle.wrapHeight
            let a = max(picked.from, r.location), b = min(picked.to, r.location + r.length)
            var x0 = CodeStyle.textX, x1 = CodeStyle.textX
            if a < b {
                x0 += CTLineGetOffsetForStringIndex(ct, a, nil)
                x1 += CTLineGetOffsetForStringIndex(ct, b, nil)
            } else if k == rows.count - 1 && picked.on {
                x0 += CTLineGetOffsetForStringIndex(ct, r.location + r.length, nil)
                x1 = x0
            } else {
                continue
            }
            // A selection that carries on to the next line shows the line break as one more character.
            if k == rows.count - 1 && picked.on { x1 += CodeStyle.charWidth * 0.6 }
            CGRect(x: x0, y: y, width: max(x1 - x0, 1), height: h).fill(using: .sourceOver)
        }
    }

    /// For the selection self-test.
    var lineCount: Int { lines.count }
    var firstLine: Int { first }
    func lineTop(_ i: Int) -> CGFloat {
        layout(bounds.width)
        return tops.indices.contains(i) ? tops[i] : 0
    }

    /// The first and last places on this canvas, for a pointer that's above or below it.
    var startPosition: CodePos? { order.map { CodePos(order: $0, line: first, char: 0) } }
    var endPosition: CodePos? {
        guard let o = order, let line = lines.last else { return nil }
        return CodePos(order: o, line: first + lines.count - 1, char: line.text.length)
    }

    /// The place in the code under a point: the character boundary nearest to it, on the row it's on.
    func position(at p: CGPoint) -> CodePos? {
        guard let o = order, !lines.isEmpty else { return nil }
        layout(bounds.width)
        if p.y < 0 { return startPosition }
        guard let i = index(at: p) else { return endPosition }
        let rows = typeset(i)
        let k = min(max(Int((p.y - tops[i]) / CodeStyle.wrapHeight), 0), rows.count - 1)
        let r = rowRange(i, k)
        var char = r.location
        if p.x > CodeStyle.textX {
            let found = CTLineGetStringIndexForPosition(rows[k], CGPoint(x: p.x - CodeStyle.textX, y: 0))
            char = found == kCFNotFound ? r.location + r.length : min(max(found, r.location), r.location + r.length)
        }
        return CodePos(order: o, line: first + i, char: char)
    }

    /// Redraws the lines between two lines of the diff, where they fall on this canvas.
    func repaint(from a: LineKey, to b: LineKey) {
        guard let o = order, !tops.isEmpty, tops.count == lines.count else {
            needsDisplay = true
            return
        }
        let lo = max(a.order == o ? a.line : (a.order < o ? first : Int.max), first)
        let hi = min(b.order == o ? b.line : (b.order > o ? first + lines.count - 1 : Int.min), first + lines.count - 1)
        guard lo <= hi else { return }
        let top = tops[lo - first]
        let bottom = tops[hi - first] + height(hi - first)
        setNeedsDisplay(CGRect(x: 0, y: top, width: bounds.width, height: bottom - top))
    }

    private static func number(_ n: Int, _ ink: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: String(n), attributes: [.font: CodeStyle.font, .foregroundColor: ink]))
    }

    /// The light an added or removed line throws to the right of the rail: strongest beside it, nearly gone by the
    /// far edge. Made once for each kind, look and state.
    nonisolated(unsafe) private static var washes: [String: CGGradient] = [:]
    private static func wash(_ kind: LineKind, hovered: Bool, dark: Bool) -> CGGradient {
        let key = "\(kind == .add ? "a" : "d")\(hovered ? 1 : 0)\(dark ? 1 : 0)"
        if let made = washes[key] { return made }
        let ink = kind == .add ? NSColor.addedInk : NSColor.removedInk
        let lift: CGFloat = hovered ? 0.05 : 0
        let near: CGFloat = kind == .add ? 0.155 : 0.135
        let stops: [CGFloat] = [near + lift, 0.07 + lift, 0.035 + lift]
        let made = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: stops.map { ink.withAlphaComponent($0).cgColor } as CFArray, locations: [0, 0.42, 1])!
        washes[key] = made
        return made
    }
    private static let plus = CTLineCreateWithAttributedString(NSAttributedString(string: "+", attributes: [.font: CodeStyle.font, .foregroundColor: NSColor.addedInk]))
    private static let minus = CTLineCreateWithAttributedString(NSAttributedString(string: "−", attributes: [.font: CodeStyle.font, .foregroundColor: NSColor.removedInk]))

    /// One row of text at a baseline, with the words that changed inside an edited line marked behind it.
    private func drawLine(_ ct: CTLine, of text: NSAttributedString, range: CFRange, in ctx: CGContext, y: CGFloat) {
        let whole = NSRange(location: range.location, length: range.length)
        text.enumerateAttribute(CodeStyle.mark, in: whole) { value, r, _ in
            guard let color = value as? NSColor else { return }
            let x0 = CTLineGetOffsetForStringIndex(ct, r.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(ct, r.location + r.length, nil)
            color.setFill()
            let box = CGRect(x: CodeStyle.textX + x0 - 1.5, y: y - CodeStyle.ascent - 0.5, width: max(x1 - x0, 1) + 3, height: CodeStyle.ascent + CodeStyle.descent + 1)
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        }
        ctx.textPosition = CGPoint(x: CodeStyle.textX, y: y)
        CTLineDraw(ct, ctx)
    }

    // MARK: The pointer

    private func index(at p: CGPoint) -> Int? {
        guard p.y >= 0, p.y < total, !tops.isEmpty else { return nil }
        // The last line that starts at or above the point.
        var lo = 0, hi = tops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tops[mid] <= p.y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func setHover(_ i: Int?) {
        let next = QA.noHover ? nil : i
        guard next != hover else { return }
        let old = hover
        hover = next
        for k in [old, next].compactMap({ $0 }) where k < tops.count {
            setNeedsDisplay(CGRect(x: 0, y: tops[k], width: bounds.width, height: height(k)))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointer(at: event) }
    override func mouseMoved(with event: NSEvent) { pointer(at: event) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func pointer(at event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setHover(index(at: p))
        // A text cursor over the code; a hand over the line numbers, which start a comment.
        (p.x < CodeStyle.textX ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: 0, width: CodeStyle.textX, height: bounds.height), cursor: .pointingHand)
        addCursorRect(CGRect(x: CodeStyle.textX, y: 0, width: max(bounds.width - CodeStyle.textX, 0), height: bounds.height), cursor: .iBeam)
    }

    /// A click on the line numbers or the sign starts a comment on that line, as on GitHub. On the code, a press
    /// starts a selection: drag to select, double-click for a word, triple-click for a line, ⇧-click to extend.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        CodeSelection.trace("mouseDown \(hunkId):\(first) at \(Int(p.x)),\(Int(p.y)) clicks=\(event.clickCount)")
        if p.x < CodeStyle.textX, !event.modifierFlags.contains(.shift), let i = index(at: p) {
            comment?(first + i)
        } else if let selection, let pos = position(at: p) {
            setHover(nil)
            selection.begin(event, at: pos, in: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(copySelection), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = !(selection?.isEmpty ?? true)
        menu.addItem(copy)
        if let i = index(at: convert(event.locationInWindow, from: nil)) {
            let line = NSMenuItem(title: "Copy Line", action: #selector(copyLine(_:)), keyEquivalent: "")
            line.target = self
            line.tag = first + i
            menu.addItem(line)
            menu.addItem(.separator())
            let note = NSMenuItem(title: "Comment on This Line", action: #selector(commentOnLine(_:)), keyEquivalent: "")
            note.target = self
            note.tag = first + i
            menu.addItem(note)
        }
        return menu
    }

    @objc private func copySelection() { selection?.copy() }

    @objc private func copyLine(_ item: NSMenuItem) {
        guard let o = order, let s = selection, s.hunkIds.indices.contains(o),
              let h = s.session?.diff?.hunk(s.hunkIds[o]), h.lines.indices.contains(item.tag) else { return }
        CodeSelection.pasteboard.clearContents()
        CodeSelection.pasteboard.setString(h.lines[item.tag].text, forType: .string)
    }

    @objc private func commentOnLine(_ item: NSMenuItem) { comment?(item.tag) }
}
