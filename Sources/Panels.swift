// The panel beside the map. Click a part and its code is here; play a flow and its steps are here; or open
// every interface whose shape changes, or the footprint. One at a time, and Esc puts it away.

import SwiftUI

struct SidePanel: View {
    @Bindable var session: PRSession
    let panel: PRSession.Panel

    var body: some View {
        Group {
            switch panel {
            case .component(let id):
                if let comp = session.map.component(id) {
                    ComponentPanel(session: session, comp: comp)
                        .id(id)
                        .transition(.opacity)
                }
            case .flow(let i):
                if session.map.flows.indices.contains(i) {
                    FlowPanel(session: session, flow: session.map.flows[i])
                        .id("flow\(i)")
                        .transition(.opacity)
                }
            case .interfaces:
                InterfacesPanel(session: session)
            case .footprint:
                FootprintPanel(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Surface(radius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(Motion.soft, value: panel)
    }
}

/// The title row the panels share.
struct PanelHeader<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle = ""
    let close: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
            PanelIconButton(icon: "xmark", help: "Close (Esc)", action: close)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 0.5) }
    }
}

struct PanelIconButton: View {
    let icon: String
    var help = ""
    var tint: Color = .text3
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Color.text1 : tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .help(help)
    }
}

// MARK: - A part and its code

struct ComponentPanel: View {
    @Bindable var session: PRSession
    let comp: Component

    var body: some View {
        let layer = session.map.layers.first { $0.id == comp.layer }
        let tint = comp.change == .unchanged ? Color.text2 : comp.change.color
        let rows = session.componentRows(comp.id)
        VStack(spacing: 0) {
            PanelHeader(icon: Glyph.component(comp.kind), tint: tint, title: comp.name,
                        subtitle: [comp.change.word, layer?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                        close: { session.closePanel() }) {
                if !rows.isEmpty {
                    PanelIconButton(icon: "chevron.left.forwardslash.chevron.right", help: "Read it in Changes") {
                        session.filter(toComponent: comp.id)
                    }
                }
                PanelIconButton(icon: "sparkle", help: "Ask Claude about \(comp.name)", tint: .sonar) {
                    session.ask("Tell me about \(comp.name) in this PR: what it does, what changed in it, and how it connects to the rest.")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ComponentFacts(session: session, comp: comp)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, rows.isEmpty ? 10 : 18)
                    if rows.isEmpty {
                        Text(comp.files.isEmpty ? "Outside this repository — on the map to show the flow."
                                                : "Nothing changed in its files — on the map for context.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.text3)
                            .padding(.horizontal, 16)
                    } else {
                        ForEach(rows) { row in
                            DocRowView(session: session, row: row)
                                .id(row.id)
                        }
                        .padding(.horizontal, 12)
                    }
                    Color.clear.frame(height: 28)
                }
            }
            .scrollIndicators(.automatic)
            .environment(\.inPanel, true)
        }
    }
}

/// What a part is, what it talks to, and the interfaces it owns.
struct ComponentFacts: View {
    @Bindable var session: PRSession
    let comp: Component

    var body: some View {
        let outgoing = Self.neighbours(session.map.edges.filter { $0.from == comp.id }, other: \.to)
        let incoming = Self.neighbours(session.map.edges.filter { $0.to == comp.id }, other: \.from)
        let contracts = session.brief.contracts.filter { session.owner(of: $0)?.id == comp.id }
        VStack(alignment: .leading, spacing: 12) {
            if !comp.summary.isEmpty {
                Text(comp.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.text2)
            }
            if !outgoing.isEmpty || !incoming.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(outgoing, id: \.other) { n in link(n.other, outgoing: true, n.change, n.labels) }
                    ForEach(incoming, id: \.other) { n in link(n.other, outgoing: false, n.change, n.labels) }
                }
            }
            ForEach(contracts) { c in
                InterfaceCard(session: session, contract: c, fill: true)
            }
        }
    }

    /// Several wires to the same part (two calls, say) become one chip.
    static func neighbours(_ edges: [Edge], other: KeyPath<Edge, String>) -> [(other: String, change: Change, labels: String)] {
        var order: [String] = []
        var byOther: [String: (Change, [String])] = [:]
        for e in edges {
            let o = e[keyPath: other]
            if byOther[o] == nil { order.append(o); byOther[o] = (e.change, []) }
            if e.change != .unchanged { byOther[o]!.0 = e.change }
            if !e.label.isEmpty { byOther[o]!.1.append(e.label) }
        }
        return order.map { ($0, byOther[$0]!.0, byOther[$0]!.1.joined(separator: " · ")) }
    }

    private func link(_ other: String, outgoing: Bool, _ change: Change, _ labels: String) -> some View {
        let c = session.map.component(other)
        let tint = change == .unchanged ? Color.text3 : change.color
        return Button {
            session.select(other)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: outgoing ? "arrow.right" : "arrow.left")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(tint)
                Text(c?.name ?? other)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.text1.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(tint.opacity(change == .unchanged ? 0.15 : 0.35), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(labels.isEmpty ? (outgoing ? "Calls \(c?.name ?? other)" : "Called by \(c?.name ?? other)") : labels)
    }
}

// MARK: - A flow, step by step

struct FlowPanel: View {
    @Bindable var session: PRSession
    let flow: Flow

    var body: some View {
        let playing = session.playingFlow == flow.id
        let current = playing ? session.flowStep : -1
        VStack(spacing: 0) {
            PanelHeader(icon: "point.topleft.down.to.point.bottomright.curvepath", tint: .sonar, title: flow.title,
                        subtitle: "\(flow.steps.count) step\(flow.steps.count == 1 ? "" : "s")",
                        close: { session.closePanel() }) {
                PanelIconButton(icon: "backward.end.fill", help: "Previous step") { session.step(-1, in: flow.id) }
                PanelIconButton(icon: session.flowPaused || !playing ? "play.fill" : "pause.fill",
                                help: session.flowPaused ? "Play" : "Pause", tint: .sonar) {
                    if !playing || session.flowPaused { session.play(flow.id) } else { session.pauseFlow() }
                }
                PanelIconButton(icon: "forward.end.fill", help: "Next step") { session.step(1, in: flow.id) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SequenceDiagram(session: session, flow: flow, active: playing ? session.flowStep : nil)
                    if flow.steps.indices.contains(current) {
                        StepRow(session: session, number: current + 1, step: flow.steps[current], active: true, done: false)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.never)
        }
    }
}

struct StepRow: View {
    @Bindable var session: PRSession
    let number: Int
    let step: FlowStep
    let active: Bool
    let done: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.mono(10, .bold))
                .foregroundStyle(active ? Color.ink : done ? Color.sonar : Color.text3)
                .frame(width: 18, height: 18)
                .background(Circle().fill(active ? Color.sonar : Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                Text(step.label)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.text1 : Color.text1.opacity(0.85))
                Text("\(session.map.component(step.from)?.name ?? step.from) → \(session.map.component(step.to)?.name ?? step.to)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(active ? Color.sonar.opacity(0.08) : Color.white.opacity(hover ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: active)
    }
}

// MARK: - Every interface

struct InterfacesPanel: View {
    @Bindable var session: PRSession

    var body: some View {
        let contracts = session.brief.contracts
        VStack(spacing: 0) {
            PanelHeader(icon: "curlybraces", tint: .calm, title: "Interfaces",
                        subtitle: "\(contracts.count) whose shape changes", close: { session.closePanel() }) {
                EmptyView()
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(contracts) { c in
                        InterfaceCard(session: session, contract: c, fill: true)
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Footprint

struct FootprintPanel: View {
    @Bindable var session: PRSession

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "square.grid.2x2", tint: .calm, title: "Footprint",
                        subtitle: "\(session.diff?.files.count ?? 0) files · area is lines changed · grey is set aside",
                        close: { session.closePanel() }) {
                EmptyView()
            }
            Footprint(session: session)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
    }
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
