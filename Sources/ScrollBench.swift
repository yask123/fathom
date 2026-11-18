// A scroll benchmark for the Code tab. FATHOM_SCROLLBENCH=2400,7000 scrolls the diff by itself at each of those
// speeds (points per second), down and back, and reports how late the frames were, then quits. A frame is late when
// the main thread was still busy laying out rows when the display asked for it: that is the hitch you feel.

import AppKit
import QuartzCore

@MainActor
final class ScrollBench: NSObject {
    static let shared = ScrollBench()

    private var link: CADisplayLink?
    private weak var scroll: NSScrollView?
    private var speeds: [CGFloat] = []
    private var pass = 0
    private var direction: CGFloat = 1
    private var last: CFTimeInterval = 0
    private var passStart: CFTimeInterval = 0
    private var period = 1.0 / 60
    private var deltas: [Double] = []
    /// What had been built by the end of each frame, to see what a late frame was busy with.
    private var marks: [(made: Int, lines: Int, rows: [String: Int])] = []
    private var travelled: CGFloat = 0
    private var results: [String] = []
    private let seconds = 5.0
    /// Set when the window was covered or the app hidden: nothing draws then, so that stretch isn't counted.
    private var interrupted = false
    private var interruptions = 0
    private var footprintAtStart = 0
    private var canvasesAtStart = ""

    /// The scroll view with the most to scroll: the diff.
    static func diffScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, !s.isHiddenOrHasHiddenAncestor { found.append(s) }
            v.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    func run(_ spec: String) {
        speeds = spec.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
        if speeds.isEmpty { speeds = [2400] }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let scroll = Self.diffScrollView(in: window), let host = window.contentView else {
            report("{\"error\":\"no scroll view\"}")
            return
        }
        self.scroll = scroll
        footprintAtStart = Self.footprint()
        canvasesAtStart = "\(ChunkCanvas.alive)/\(ChunkCanvas.draws)/\(ChunkCanvas.linesDrawn)"
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if !window.occlusionState.contains(.visible) { self?.interrupted = true } }
        }
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted = true }
        }
        let link = host.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        begin()
    }

    private func begin() {
        direction = 1
        last = 0
        deltas = []
        marks = []
        travelled = 0
        passStart = CACurrentMediaTime()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scroll, let doc = scroll.documentView else { return }
        let now = CACurrentMediaTime()
        period = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        if interrupted || scroll.window?.occlusionState.contains(.visible) != true {
            // Covered or hidden: start the clock again from here.
            if !interrupted || last > 0 { interruptions += 1 }
            interrupted = false
            if last > 0 { passStart += now - last }
            last = scroll.window?.occlusionState.contains(.visible) == true ? now : 0
            if last == 0 { passStart = now - min(now - passStart, seconds) }
            return
        }
        if last > 0 {
            deltas.append(now - last)
            marks.append((ChunkCanvas.made, ChunkCanvas.linesDrawn, RowCount.built))
        }
        // Move by the time that really passed, as a finger on a trackpad would.
        let dt = last > 0 ? min(now - last, 0.1) : period
        last = now
        let clip = scroll.contentView
        let maxY = max(doc.frame.height - clip.bounds.height, 0)
        var y = clip.bounds.origin.y + direction * speeds[pass] * CGFloat(dt)
        if y >= maxY { y = maxY; direction = -1 }
        if y <= 0 { y = 0; direction = 1 }
        travelled += abs(y - clip.bounds.origin.y)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)

        if now - passStart >= seconds {
            results.append(summary(speed: speeds[pass], height: doc.frame.height))
            pass += 1
            if pass >= speeds.count {
                link.invalidate()
                self.link = nil
                report("{\"passes\":[" + results.joined(separator: ",") + "],\"interruptions\":\(interruptions),\"footprint_start_mb\":\(footprintAtStart),\"footprint_mb\":\(Self.footprint()),\"canvases_alive_draws_lines_start\":\"\(canvasesAtStart)\",\"canvases_alive_draws_lines_end\":\"\(ChunkCanvas.alive)/\(ChunkCanvas.draws)/\(ChunkCanvas.linesDrawn)\"}")
            } else {
                begin()
            }
        }
    }

    private func summary(speed: CGFloat, height: CGFloat) -> String {
        let sorted = deltas.sorted()
        let total = deltas.reduce(0, +)
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] * 1000 }
        // Late by more than half a frame, and by more than a frame and a half.
        let late = deltas.filter { $0 > period * 1.5 }.count
        let dropped = deltas.filter { $0 > period * 2.5 }.count
        let hitch = deltas.reduce(0) { $0 + max($1 - period, 0) }
        // The worst frames, and what was built during each.
        let worst = deltas.indices.filter { $0 > 0 && deltas[$0] > period * 1.5 }.sorted { deltas[$0] > deltas[$1] }.prefix(8).map { i -> String in
            let a = marks[i - 1], b = marks[i]
            let rows = b.rows.compactMap { k, v -> String? in
                let d = v - (a.rows[k] ?? 0)
                return d > 0 ? "\(k)+\(d)" : nil
            }.sorted().joined(separator: " ")
            return String(format: "\"%.0fms: canvases+%d lines+%d %@\"", deltas[i] * 1000, b.made - a.made, b.lines - a.lines, rows)
        }.joined(separator: ",")
        return String(format: "{\"speed\":%.0f,\"frames\":%d,\"hz\":%.0f,\"late\":%d,\"dropped\":%d,\"hitch_ms_per_s\":%.1f,\"p50_ms\":%.1f,\"p95_ms\":%.1f,\"p99_ms\":%.1f,\"max_ms\":%.1f,\"travelled\":%.0f,\"doc_height\":%.0f,\"worst\":[%@]}",
                      Double(speed), deltas.count, 1 / period, late, dropped, total > 0 ? hitch / total * 1000 : 0,
                      pct(0.5), pct(0.95), pct(0.99), (sorted.last ?? 0) * 1000, Double(travelled), Double(height), worst)
    }

    /// The app's memory, in megabytes, as Activity Monitor counts it.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return ok == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private func report(_ json: String) {
        if let path = ProcessInfo.processInfo.environment["FATHOM_BENCH_OUT"] {
            try? json.write(toFile: path, atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(Data((json + "\n").utf8))
        NSApp.terminate(nil)
    }
}
