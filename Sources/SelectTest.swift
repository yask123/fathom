// A self-test for selecting and copying code. FATHOM_SELECTTEST=1 opens the Code tab and drives it with synthetic
// mouse and key events handed straight to the app (the real pointer never moves, and the window never needs to come
// to the front, so it can run while the Mac is in use): a double-click, a triple-click,
// a drag that runs past the bottom edge so the diff scrolls, and a drag from one run of lines into the next. Each is
// copied with ⌘C into a private pasteboard (FATHOM_PASTEBOARD) and checked against the diff. The results go to
// FATHOM_BENCH_OUT and stderr; the last selection stays on screen for a screenshot.

import AppKit

@MainActor
enum SelectTest {
    private static var results: [String] = []
    private static var hits: [String] = []
    private static var failures = 0

    static func run(_ session: PRSession) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let scroll = ScrollBench.diffScrollView(in: window) else { return report() }
        let clip = scroll.contentView
        func canvases() -> [ChunkCanvas] {
            var out: [ChunkCanvas] = []
            func walk(_ v: NSView) {
                if let c = v as? ChunkCanvas { out.append(c) }
                v.subviews.forEach(walk)
            }
            walk(scroll)
            // On screen, top to bottom.
            let visible = clip.convert(clip.bounds, to: nil)
            return out.filter { $0.window != nil && visible.intersects($0.convert($0.bounds, to: nil)) && $0.lineCount > 0 }
                .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        }
        func point(_ c: ChunkCanvas, line: Int, char: Double) -> NSPoint {
            c.convert(CGPoint(x: CodeStyle.textX + CodeStyle.charWidth * char, y: c.lineTop(line) + CodeStyle.lineHeight / 2), to: nil)
        }
        // A press goes straight to the code under it, as a click on a window in front would; drags, releases and
        // keys go through the app (NSApp.sendEvent), where the selection's monitors see them. Nothing is activated.
        func post(_ type: NSEvent.EventType, _ at: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) async {
            if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
                if type == .leftMouseDown, let hit = window.contentView?.superview?.hitTest(at) as? ChunkCanvas {
                    hit.mouseDown(with: e)
                } else if type == .leftMouseDown {
                    hits.append("press at \(Int(at.x)),\(Int(at.y)) hit \(window.contentView?.superview?.hitTest(at).map { String(describing: Swift.type(of: $0)) } ?? "nothing")")
                } else {
                    NSApp.sendEvent(e)
                }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags) async {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        func copied() async -> String {
            CodeSelection.pasteboard.clearContents()
            await key("c", code: 8, flags: .command)
            return CodeSelection.pasteboard.string(forType: .string) ?? ""
        }
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            results.append("{\"test\":\"\(name)\",\"ok\":\(ok),\"detail\":\(json(detail))}")
        }
        func raw(_ c: ChunkCanvas, _ line: Int) -> String {
            guard let h = session.diff?.hunk(c.hunkId), h.lines.indices.contains(c.firstLine + line) else { return "" }
            return h.lines[c.firstLine + line].text
        }

        var list = canvases()
        guard let a = list.first(where: { $0.lineCount >= 4 }) else {
            check("setup", false, "no canvas with four lines on screen")
            return report()
        }

        // A double-click picks out a word.
        let wordLine = (0..<a.lineCount).first { raw(a, $0).contains { $0.isLetter } } ?? 0
        let text = raw(a, wordLine)
        let col = text.firstIndex { $0.isLetter }.map { text.distance(from: text.startIndex, to: $0) } ?? 0
        await post(.leftMouseDown, point(a, line: wordLine, char: Double(col) + 0.6))
        await post(.leftMouseUp, point(a, line: wordLine, char: Double(col) + 0.6))
        await post(.leftMouseDown, point(a, line: wordLine, char: Double(col) + 0.6), clicks: 2)
        await post(.leftMouseUp, point(a, line: wordLine, char: Double(col) + 0.6), clicks: 2)
        let word = await copied()
        check("double-click word", !word.isEmpty && !word.contains(" ") && text.contains(word) && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" },
              "\(word) from: \(text)")

        // A triple-click takes the whole line, with its line break.
        await post(.leftMouseDown, point(a, line: 1, char: 2), clicks: 3)
        await post(.leftMouseUp, point(a, line: 1, char: 2), clicks: 3)
        let line = await copied()
        check("triple-click line", line == raw(a, 1) + "\n", line)

        // ⌘C with nothing selected leaves the pasteboard alone; a plain click clears the selection.
        await post(.leftMouseDown, point(a, line: 2, char: 3))
        await post(.leftMouseUp, point(a, line: 2, char: 3))
        CodeSelection.pasteboard.clearContents()
        CodeSelection.pasteboard.setString("untouched", forType: .string)
        await key("c", code: 8, flags: .command)
        check("click clears", session.selection.isEmpty && CodeSelection.pasteboard.string(forType: .string) == "untouched",
              "empty: \(session.selection.isEmpty)")

        // A drag past the bottom edge scrolls the diff and keeps selecting.
        let before = clip.bounds.origin.y
        let start = point(a, line: 0, char: 0)
        let below = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.isFlipped ? clip.bounds.maxY + 60 : clip.bounds.minY - 60), to: nil)
        await post(.leftMouseDown, start)
        await post(.leftMouseDragged, NSPoint(x: start.x + 40, y: start.y - 30))
        await post(.leftMouseDragged, below)
        try? await Task.sleep(for: .milliseconds(900))
        let moved = abs(clip.bounds.origin.y - before)
        await post(.leftMouseUp, below)
        let long = await copied()
        let lines = long.split(separator: "\n", omittingEmptySubsequences: false).count
        check("drag past the edge scrolls", moved > 200 && lines > 30, "scrolled \(Int(moved)) pt, \(lines) lines copied")
        await key("\u{1b}", code: 53, flags: [])
        check("esc clears", session.selection.isEmpty, "empty: \(session.selection.isEmpty)")

        // A drag from one run of lines into the next, left on screen for the picture.
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: before))
        scroll.reflectScrolledClipView(clip)
        try? await Task.sleep(for: .milliseconds(500))
        list = canvases()
        guard let i = list.firstIndex(where: { $0.lineCount >= 3 }), i + 1 < list.count else {
            check("two runs on screen", false, "found \(list.count) canvases")
            return report()
        }
        let c1 = list[i], c2 = list[i + 1]
        let from = point(c1, line: 1, char: 4), to = point(c2, line: min(2, c2.lineCount - 1), char: 10)
        await post(.leftMouseDown, from)
        for k in 1...6 {
            let t = CGFloat(k) / 6
            await post(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        await post(.leftMouseUp, to)
        let across = await copied()
        let head = CodeSelection.original(raw(c1, 1), from: 4, to: CodeSelection.shown(raw(c1, 1)).length)
        let tailLine = raw(c2, min(2, c2.lineCount - 1))
        let tail = CodeSelection.original(tailLine, from: 0, to: 10)
        check("drag across runs", across.hasPrefix(head) && across.hasSuffix(tail) && across.contains("\n"),
              "\(across.split(separator: "\n", omittingEmptySubsequences: false).count) lines: \(across.prefix(80))…\(across.suffix(40))")
        report()
    }

    private static func json(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    private static func report() {
        let out = "{\"failures\":\(failures),\"missed\":\(json(hits.joined(separator: "; "))),\"results\":[" + results.joined(separator: ",") + "]}"
        if let path = QA.env["FATHOM_BENCH_OUT"] { try? out.write(toFile: path, atomically: true, encoding: .utf8) }
        FileHandle.standardError.write(Data((out + "\n").utf8))
    }
}
