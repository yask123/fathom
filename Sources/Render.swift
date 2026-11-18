// Off screen, with no window: draw a pull request's trace to a picture and quit, and optionally read it first.
//   FATHOM_RENDER=/out.png FATHOM_RENDER_PR=owner/repo#12   draw the trace of a pull request that's already on disk
//   FATHOM_READ=1                                          have Claude read it first (and keep the reading)
//   FATHOM_RENDER_WIDTH=1500, FATHOM_FLOW=before, FATHOM_STEP=3, FATHOM_APPEARANCE=light
//   FATHOM_STAGE_JSON=/out.json, FATHOM_STAGE_WIDTH=1180   also write the stage's geometry (for the website's live trace)
// Nothing appears on screen and nothing takes the keyboard, so this is how the look is checked while the Mac is in use.

import AppKit
import SwiftUI

@MainActor
enum Render {
    /// The app's store, or, when a picture was asked for, the picture and then the end of the process.
    static func boot() -> AppStore {
        let env = QA.env
        guard let out = env["FATHOM_RENDER"], let target = env["FATHOM_RENDER_PR"], let ref = PRRef.parse(target) else { return AppStore() }
        let light = env["FATHOM_APPEARANCE"] == "light"
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)!
        NSApplication.shared.appearance = appearance

        let store = AppStore()
        let session = PRSession(ref: ref, store: store, background: true)
        guard session.showCached() else { quit("no copy of \(ref.id) on disk under \(Library.root.path)") }

        if env["FATHOM_READ"] == "1" {
            wait { await Shell.loadLoginEnvironment() }
            let started = Date()
            session.sound()
            // Until the reading is kept (or has failed), not just until its last word.
            while Date().timeIntervalSince(started) < 120,
                  session.isSounding || (session.soundedAt == nil && session.traceState.failure == nil && session.briefState.failure == nil) {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            var line = "read \(ref.id):"
            if case .done(let s) = session.traceState { line += String(format: " trace %.1f s", s) }
            if case .done(let s) = session.briefState { line += String(format: ", outline %.1f s", s) }
            if let first = session.firstPaint { line += String(format: ", first words %.1f s", first) }
            if let f = session.traceState.failure { line += " trace failed: \(f)" }
            if let f = session.briefState.failure { line += " outline failed: \(f)" }
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }

        if env["FATHOM_LINT"] == "1" { lint(session.trace, ref: ref) }
        if let path = env["FATHOM_STAGE_JSON"] {
            appearance.performAsCurrentDrawingAppearance {
                export(session.trace, width: env["FATHOM_STAGE_WIDTH"].flatMap(Double.init) ?? 1180, to: path)
            }
        }

        let width = env["FATHOM_RENDER_WIDTH"].flatMap(Double.init) ?? 1500
        let page = TracePage(session: session, mode: FlowMode(rawValue: QA.flow) ?? .diff, cursor: QA.step, hover: .constant(nil),
                             playing: false, setMode: { _ in }, pick: { _ in }, togglePlay: {})
            .padding(.horizontal, 40)
            .padding(.top, 24)
            .padding(.bottom, 34)
            .frame(width: width)
            .background(Backdrop())
            .environment(store)
            .environment(\.colorScheme, light ? .light : .dark)

        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: page)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                png = rep.representation(using: .png, properties: [:])
            }
        }
        guard let png, (try? png.write(to: URL(fileURLWithPath: out))) != nil else { quit("couldn't draw \(ref.id)") }
        FileHandle.standardError.write(Data("drew \(out)\n".utf8))
        exit(0)
    }

    /// The stage as numbers: where every rail, piece of line, dot and word goes at one width, with colours as hex and
    /// paths as SVG. The website draws its live trace from this, so it's the app's own layout, not a copy of it.
    private static func export(_ trace: Trace, width: Double, to path: String) {
        func hex(_ c: Color) -> String {
            guard let n = NSColor(c).usingColorSpace(.sRGB) else { return "#ffffff" }
            return String(format: "#%02x%02x%02x", Int((n.redComponent * 255).rounded()), Int((n.greenComponent * 255).rounded()), Int((n.blueComponent * 255).rounded()))
        }
        func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        func svg(_ p: Path) -> String {
            var d = ""
            p.forEach { e in
                switch e {
                case .move(let to): d += "M\(r(to.x)) \(r(to.y))"
                case .line(let to): d += "L\(r(to.x)) \(r(to.y))"
                case .quadCurve(let to, let c): d += "Q\(r(c.x)) \(r(c.y)) \(r(to.x)) \(r(to.y))"
                case .curve(let to, let c1, let c2): d += "C\(r(c1.x)) \(r(c1.y)) \(r(c2.x)) \(r(c2.y)) \(r(to.x)) \(r(to.y))"
                case .closeSubpath: d += "Z"
                }
            }
            return d
        }
        var tellings: [String: Any] = [:]
        for mode in FlowMode.allCases {
            let plan = StagePlan(trace: trace, mode: mode, width: width)
            let bump = StagePlan.gap(plan.rows.count) / 2 - 3
            tellings[mode.rawValue] = [
                "width": width, "height": r(plan.height), "headerW": r(plan.headerW), "colW": r(plan.colW), "lead": r(plan.lead), "whole": plan.whole,
                "lanes": plan.lanes.map { ["name": $0.name, "hue": hex($0.hue), "x": r($0.rect.minX), "y": r($0.rect.minY), "w": r($0.rect.width), "h": r($0.rect.height)] },
                "rows": plan.rows.map { row in
                    ["id": row.id, "name": row.actor.name, "role": row.actor.role, "kind": row.actor.isPerson ? "person" : row.actor.kind,
                     "person": row.actor.isPerson, "sign": row.actor.isPerson ? "" : row.actor.change.sign, "signColor": hex(row.actor.change.color),
                     "y": r(row.y), "hue": hex(row.hue),
                     "inLane": plan.lanes.contains { abs($0.rect.minY - (row.y - bump)) < 1 }] as [String: Any]
                },
                "columns": plan.columns.map { ["step": $0.step, "x0": r($0.x0), "dot": r($0.dot), "status": $0.status.rawValue, "number": $0.number] as [String: Any] },
                "segs": plan.segs.map { ["d": svg($0.path), "step": $0.step ?? -1, "color": hex($0.color), "glow": hex($0.glow),
                                         "style": $0.style == .live ? "live" : $0.style == .ghost ? "ghost" : "handoff", "at": $0.at, "span": $0.span] as [String: Any] },
                "dots": plan.dots.map { ["x": r($0.p.x), "y": r($0.p.y), "step": $0.step ?? -1, "kind": "\($0.kind)", "color": hex($0.color), "at": $0.at] as [String: Any] },
                "labels": plan.labels.map { l in
                    ["id": l.id, "x": r(l.p.x), "y": r(l.p.y), "side": "\(l.side)", "width": r(l.width), "ghost": l.ghost, "at": l.at, "color": hex(l.color),
                     "does": mode == .before ? l.step.beforeDoes : l.step.does, "data": l.step.data] as [String: Any]
                },
                "pain": plan.pain.map { ["x": r(plan.painAt?.x ?? $0.p.x), "y": r($0.p.y), "text": $0.text, "at": $0.at] as [String: Any] } as Any? ?? NSNull(),
            ] as [String: Any]
        }
        let doc: [String: Any] = [
            "headline": Prose.title(trace.headline), "kind": Glyph.kindWord(trace.kind), "was": trace.was, "now": trace.now, "how": trace.how,
            "breaks": trace.breaks,
            "steps": trace.flow.map { ["id": $0.id, "from": $0.from, "to": $0.to, "does": $0.does, "was": $0.was, "data": $0.data, "status": $0.status.rawValue] as [String: Any] },
            "cast": trace.cast.map { ["id": $0.id, "name": $0.name] },
            "forks": trace.forks.map { ["title": $0.title, "chose": $0.chose, "over": $0.over, "why": $0.why, "step": $0.step] as [String: Any] },
            "tellings": tellings,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("stage → \(path)\n".utf8))
        }
    }

    /// Checks the stage's layout at a few widths and in each telling: every step's words inside the stage and clear
    /// of each other. Prints what it finds.
    private static func lint(_ trace: Trace, ref: PRRef) {
        var problems = 0
        for width in [1020.0, 1180, 1420] {
            for mode in FlowMode.allCases {
                let plan = StagePlan(trace: trace, mode: mode, width: width)
                let box = plan.box
                // The tag for what went wrong clears every step's words.
                if let pain = plan.pain, let at = plan.painAt {
                    let w = StagePlan.painWidth((mode == .diff ? "before: " : "") + pain.text)
                    let r = CGRect(x: at.x - w / 2, y: at.y - 10, width: w, height: 20)
                    for l in plan.labels where box(l).intersects(r) {
                        problems += 1
                        FileHandle.standardError.write(Data("lint \(ref.id) \(Int(width)) \(mode.rawValue): the tag for what broke sits on step \(l.id + 1)'s words\n".utf8))
                    }
                }
                for (i, a) in plan.labels.enumerated() {
                    let ra = box(a)
                    if ra.minX < plan.headerW || ra.maxX > width + 1 || ra.minY < 0 || ra.maxY > plan.height {
                        problems += 1
                        FileHandle.standardError.write(Data("lint \(ref.id) \(Int(width)) \(mode.rawValue): step \(a.id + 1) words out of bounds \(ra.integral)\n".utf8))
                    }
                    for b in plan.labels[(i + 1)...] where ra.intersects(box(b)) {
                        problems += 1
                        FileHandle.standardError.write(Data("lint \(ref.id) \(Int(width)) \(mode.rawValue): steps \(a.id + 1) and \(b.id + 1) overlap\n".utf8))
                    }
                }
                // Every step of the telling has a column, a piece of line, and words.
                let shown = trace.flow.filter { mode == .before ? $0.inBefore : mode == .after ? $0.inAfter : true }
                for s in shown where plan.curves[s.id] == nil || !plan.labels.contains(where: { $0.id == s.id }) {
                    problems += 1
                    FileHandle.standardError.write(Data("lint \(ref.id) \(Int(width)) \(mode.rawValue): step \(s.id + 1) isn't drawn\n".utf8))
                }
            }
        }
        FileHandle.standardError.write(Data("lint \(ref.id): \(problems) problem\(problems == 1 ? "" : "s") across 3 widths x 3 tellings (\(trace.cast.count) parts, \(trace.flow.count) steps, \(trace.forks.count) forks)\n".utf8))
    }

    private static func wait(_ work: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in
            await work()
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private static func quit(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
