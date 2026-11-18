// Selecting code in the Code tab. The diff is drawn in many separate canvases that come and go as it scrolls, so
// the selection lives here, in terms of the diff itself (which hunk, which line, which character), and each canvas
// draws whatever part of it falls on its lines. A drag that starts in one canvas follows the pointer into the others,
// and scrolls the diff when the pointer goes past its top or bottom edge. ⌘C, or Copy in the right-click menu, copies
// the code as written: no line numbers, no + or −, tabs as tabs.

import AppKit

/// A place in the diff: which hunk (by its place in the Code tab's reading order), which of its lines, and which
/// character of that line as drawn (tabs as four spaces).
struct CodePos: Comparable, Hashable {
    var order: Int
    var line: Int
    var char: Int

    static func < (a: CodePos, b: CodePos) -> Bool { (a.order, a.line, a.char) < (b.order, b.line, b.char) }

    /// The line it's on, for comparing lines.
    var row: LineKey { LineKey(order: order, line: line) }
}

struct LineKey: Comparable, Hashable {
    var order: Int
    var line: Int
    static func < (a: LineKey, b: LineKey) -> Bool { (a.order, a.line) < (b.order, b.line) }
}

@MainActor
final class CodeSelection {
    weak var session: PRSession?

    /// The hunks as the Code tab shows them, top to bottom.
    private(set) var hunkIds: [String] = []
    private var orderOf: [String: Int] = [:]

    /// What's selected, start before end; nil when nothing is.
    private(set) var range: (lo: CodePos, hi: CodePos)?
    var isEmpty: Bool { range == nil }

    /// What the drag started on (a point, a word or a line), and how it grows: 1 by characters, 2 words, 3 lines.
    private var anchor: (lo: CodePos, hi: CodePos)?
    private var unit = 1

    private let canvases = NSHashTable<ChunkCanvas>.weakObjects()
    private weak var window: NSWindow?
    private weak var scroll: NSScrollView?
    private var dragMonitor: Any?
    private var keyMonitor: Any?
    private var timer: Timer?
    private var lastPoint: NSPoint = .zero

    deinit {
        // Monitors and the timer are let go of by the session that owns this, which ends on the main thread.
        MainActor.assumeIsolated {
            if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            timer?.invalidate()
        }
    }

    // MARK: The diff's order

    /// Called whenever the Code tab's rows are rebuilt. A new order (chapters regrouped, a filter) clears the selection,
    /// since its places would point at other lines.
    func setOrder(_ ids: [String]) {
        guard ids != hunkIds else { return }
        hunkIds = ids
        orderOf = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        clear()
    }

    func order(of hunk: String) -> Int? { orderOf[hunk] }

    func register(_ canvas: ChunkCanvas) { canvases.add(canvas) }

    // MARK: Lines

    /// A line as drawn: tabs as four spaces.
    static func shown(_ raw: String) -> NSString {
        (raw.contains("\t") ? raw.replacingOccurrences(of: "\t", with: "    ") : raw) as NSString
    }

    private func hunk(_ order: Int) -> Hunk? {
        guard hunkIds.indices.contains(order) else { return nil }
        return session?.diff?.hunk(hunkIds[order])
    }

    private func shown(_ key: LineKey) -> NSString {
        guard let h = hunk(key.order), h.lines.indices.contains(key.line) else { return "" }
        return Self.shown(h.lines[key.line].text)
    }

    /// The text between two places on one line, as written (a tab that was drawn as spaces is a tab again).
    static func original(_ raw: String, from s: Int, to e: Int) -> String {
        let u = Array(raw.utf16)
        var shown = 0, start: Int?, end: Int?
        for (i, c) in u.enumerated() {
            if start == nil && shown >= s { start = i }
            if end == nil && shown >= e { end = i; break }
            shown += c == 9 ? 4 : 1
        }
        let a = min(start ?? u.count, u.count), b = max(min(end ?? u.count, u.count), a)
        return String(decoding: u[a..<b], as: UTF16.self)
    }

    /// The word, run of spaces, or single mark at a place.
    private func word(at p: CodePos) -> (CodePos, CodePos) {
        let s = shown(p.row)
        guard s.length > 0 else { return (p, p) }
        let i = min(max(p.char, 0), s.length - 1)
        func kind(_ c: unichar) -> Int {
            if c == 95 || c == 36 { return 0 }                                     // _ and $ belong to names
            if let u = UnicodeScalar(c), CharacterSet.alphanumerics.contains(u) { return 0 }
            if c == 32 || c == 9 { return 1 }
            return 2
        }
        let k = kind(s.character(at: i))
        var a = i, b = i + 1
        if k != 2 {
            while a > 0 && kind(s.character(at: a - 1)) == k { a -= 1 }
            while b < s.length && kind(s.character(at: b)) == k { b += 1 }
        }
        return (CodePos(order: p.order, line: p.line, char: a), CodePos(order: p.order, line: p.line, char: b))
    }

    /// A whole line, with its line break: from its start to the start of the next.
    private func line(at p: CodePos) -> (CodePos, CodePos) {
        (CodePos(order: p.order, line: p.line, char: 0), CodePos(order: p.order, line: p.line + 1, char: 0))
    }

    // MARK: Selecting

    private func set(_ lo: CodePos, _ hi: CodePos) {
        let old = range
        range = lo < hi ? (lo, hi) : nil
        repaint(old, range)
    }

    func clear() {
        let old = range
        range = nil
        anchor = nil
        repaint(old, nil)
    }

    /// Redraws only the lines whose look changed: where the selection's start or end moved.
    private func repaint(_ old: (lo: CodePos, hi: CodePos)?, _ new: (lo: CodePos, hi: CodePos)?) {
        var spans: [(CodePos, CodePos)] = []
        switch (old, new) {
        case (nil, nil): return
        case (let o?, nil): spans = [o]
        case (nil, let n?): spans = [n]
        case (let o?, let n?):
            if o.lo != n.lo { spans.append((min(o.lo, n.lo), max(o.lo, n.lo))) }
            if o.hi != n.hi { spans.append((min(o.hi, n.hi), max(o.hi, n.hi))) }
        }
        for c in canvases.allObjects {
            for (a, b) in spans { c.repaint(from: a.row, to: b.row) }
        }
    }

    /// Where the pointer is, in the diff. Between two runs of lines (over a file's name, a comment), the nearer one.
    private func position(at point: NSPoint) -> CodePos? {
        guard let window else { return nil }
        var best: (pos: CodePos, distance: CGFloat)?
        for c in canvases.allObjects where c.window === window {
            let p = c.convert(point, from: nil)
            if p.y >= 0 && p.y < c.bounds.height { return c.position(at: p) }
            let distance = p.y < 0 ? -p.y : p.y - c.bounds.height
            guard best == nil || distance < best!.distance,
                  let pos = p.y < 0 ? c.startPosition : c.endPosition else { continue }
            best = (pos, distance)
        }
        return best?.pos
    }

    /// The selection grown from where the drag started to `head`, by characters, words or lines.
    private func grow(to head: CodePos) {
        guard let anchor else { return }
        let piece: (CodePos, CodePos) = unit == 3 ? line(at: head) : unit == 2 ? word(at: head) : (head, head)
        set(min(anchor.lo, piece.0), max(anchor.hi, piece.1))
    }

    /// A press on the code: one click puts the start there, two select a word, three a line, and ⇧ extends what's
    /// selected. Then the drag follows the pointer until the button comes up.
    func begin(_ event: NSEvent, at pos: CodePos, in canvas: ChunkCanvas) {
        Self.trace("begin clicks=\(event.clickCount) pos=\(pos) key=\(canvas.window?.isKeyWindow ?? false)")
        window = canvas.window
        scroll = canvas.enclosingScrollView
        lastPoint = event.locationInWindow
        if event.modifierFlags.contains(.shift), anchor != nil {
            unit = 1
            grow(to: pos)
        } else {
            unit = min(max(event.clickCount, 1), 3)
            let piece = unit == 3 ? line(at: pos) : unit == 2 ? word(at: pos) : (pos, pos)
            anchor = piece
            set(piece.0, piece.1)
        }
        watchKeys()
        follow()
    }

    private func follow() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.type == .leftMouseUp {
                    self.end()
                    return event
                }
                self.lastPoint = event.locationInWindow
                if let pos = self.position(at: self.lastPoint) { self.grow(to: pos) }
                return nil
            }
        }
        // Past the top or bottom of the diff, it scrolls, faster the further the pointer goes.
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscroll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func end() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func autoscroll() {
        guard let scroll, let doc = scroll.documentView else { Self.trace("autoscroll: no scroll view"); return }
        let clip = scroll.contentView
        let p = clip.convert(lastPoint, from: nil)
        let b = clip.bounds
        // How far past an edge, and whether that's towards the end of the diff.
        var past: CGFloat = 0, onward = false
        if p.y < b.minY { past = b.minY - p.y; onward = !clip.isFlipped }
        else if p.y > b.maxY { past = p.y - b.maxY; onward = clip.isFlipped }
        guard past > 0 else { return }
        Self.trace("autoscroll past=\(Int(past)) y=\(Int(b.origin.y)) flipped=\(clip.isFlipped)")
        let step = min(4 + past * 0.35, 70)
        let maxY = max(doc.frame.height - b.height, 0)
        let towardEnd: CGFloat = clip.isFlipped ? 1 : -1
        let y = min(max(b.origin.y + (onward ? step : -step) * towardEnd, 0), maxY)
        guard y != b.origin.y else { return }
        clip.scroll(to: NSPoint(x: b.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        if let pos = position(at: lastPoint) { grow(to: pos) }
    }

    // MARK: Copying

    /// The selected code as written, lines joined by line breaks.
    var text: String? {
        guard let (lo, hi) = range else { return nil }
        var out = ""
        var key = lo.row
        while key <= hi.row {
            guard let h = hunk(key.order) else { break }
            if key.line >= h.lines.count {
                key = LineKey(order: key.order + 1, line: 0)
                continue
            }
            let raw = h.lines[key.line].text
            let isFirst = key == lo.row, isLast = key == hi.row
            out += Self.original(raw, from: isFirst ? lo.char : 0, to: isLast ? hi.char : Self.shown(raw).length)
            if isLast { break }
            out += "\n"
            key.line += 1
        }
        return out
    }

    /// FATHOM_TRACE_SELECT=1 logs what the selection does, to stderr.
    static let tracing = QA.env["FATHOM_TRACE_SELECT"] == "1"
    static func trace(_ s: @autoclosure () -> String) {
        if tracing { FileHandle.standardError.write(Data(("select: " + s() + "\n").utf8)) }
    }

    func copy() {
        Self.trace("copy \(range.map { "\($0.lo)-\($0.hi)" } ?? "nothing")")
        guard let text, !text.isEmpty else { return }
        Self.pasteboard.clearContents()
        Self.pasteboard.setString(text, forType: .string)
    }

    /// The general pasteboard; a private one for tests, so they never touch what you copied.
    static var pasteboard: NSPasteboard {
        if let name = QA.env["FATHOM_PASTEBOARD"] { return NSPasteboard(name: NSPasteboard.Name(name)) }
        return .general
    }

    /// ⌘C copies the selection while the Code tab is in front and you're not typing in a box.
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, !self.isEmpty,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "c",
                      session.tab == .changes, session.store?.session === session,
                      event.window === self.window,
                      !(event.window?.firstResponder is NSText) else { return event }
                self.copy()
                return nil
            }
        }
    }
}
