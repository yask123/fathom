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
            case .edge(let id):
                if let edge = session.map.edge(id) {
                    ConnectionPanel(session: session, edge: edge)
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

/// What a part is, what it holds, how it connects, and the interfaces it owns.
struct ComponentFacts: View {
    @Bindable var session: PRSession
    let comp: Component

    var body: some View {
        let edges = session.map.edges.filter { $0.from == comp.id } + session.map.edges.filter { $0.to == comp.id }
        let contracts = session.brief.contracts.filter { session.owner(of: $0)?.id == comp.id }
        VStack(alignment: .leading, spacing: 14) {
            if !comp.summary.isEmpty {
                Text(comp.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.text2)
            }
            if !comp.holds.isEmpty {
                FactLine(title: "Holds") {
                    Text(comp.holds)
                        .font(.mono(11.5))
                        .foregroundStyle(Color.text1.opacity(0.9))
                }
            }
            if !edges.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Connections")
                    VStack(spacing: 2) {
                        ForEach(edges) { e in
                            ConnectionRow(session: session, edge: e, from: comp.id)
                        }
                    }
                }
            }
            ForEach(contracts) { c in
                InterfaceCard(session: session, contract: c, fill: true)
            }
        }
    }
}

/// A small titled line: "HOLDS  route, places".
struct FactLine<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Eyebrow(title)
                .frame(width: 92, alignment: .leading)
            content
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// One connection of a part: which way, to whom, the call, and what travels. Click to open it.
struct ConnectionRow: View {
    @Bindable var session: PRSession
    let edge: Edge
    let from: String
    @State private var hover = false

    var body: some View {
        let outgoing = edge.from == from
        let other = session.map.component(outgoing ? edge.to : edge.from)
        let tint = edge.change == .unchanged ? Color.text3 : edge.change.color
        Button {
            session.selectEdge(edge.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: outgoing ? "arrow.right" : "arrow.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(other?.name ?? (outgoing ? edge.to : edge.from))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.text1)
                        if let token = edge.how.token(via: edge.via) {
                            Text(token)
                                .font(.mono(8.5, .bold))
                                .foregroundStyle(Color.calm)
                        }
                        Spacer(minLength: 0)
                        if !edge.payload.isEmpty {
                            Text(edge.payload)
                                .font(.mono(10.5))
                                .foregroundStyle(edge.change == .unchanged ? Color.text2 : tint)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if !edge.via.isEmpty {
                        Text(edge.via)
                            .font(.mono(10.5))
                            .foregroundStyle(Color.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.06 : 0.025)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            hover = QA.hover(h)
            guard !QA.noHover else { return }
            session.hoveredEdge = h ? edge.id : (session.hoveredEdge == edge.id ? nil : session.hoveredEdge)
        }
    }
}

// MARK: - One connection

/// How one part reaches another: the call as written, what goes and what comes back, the interfaces that travel
/// with it, and the code where it happens.
struct ConnectionPanel: View {
    @Bindable var session: PRSession
    let edge: Edge

    var body: some View {
        let a = session.map.component(edge.from), b = session.map.component(edge.to)
        let tint = edge.change == .unchanged ? Color.calm : edge.change.color
        let rows = session.edgeRows(edge)
        let contracts = session.contracts(on: edge)
        VStack(spacing: 0) {
            PanelHeader(icon: edge.how.icon, tint: tint, title: "\(a?.name ?? edge.from) → \(b?.name ?? edge.to)",
                        subtitle: [edge.how.word.prefix(1).uppercased() + edge.how.word.dropFirst(), edge.change == .unchanged ? "" : edge.change.word, edge.label]
                            .filter { !$0.isEmpty }.joined(separator: " · "),
                        close: { session.closePanel() }) {
                PanelIconButton(icon: "sparkle", help: "Ask Claude about this connection", tint: .sonar) {
                    session.ask("How does \(a?.name ?? edge.from) reach \(b?.name ?? edge.to) in this PR (\(edge.via.isEmpty ? edge.label : edge.via))? What travels each way, and what changed?")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        ExchangeDiagram(session: session, edge: edge)
                        if !edge.via.isEmpty {
                            FactLine(title: "Called as") {
                                Text(edge.via)
                                    .font(.mono(12, .medium))
                                    .foregroundStyle(Color.text1)
                                    .textSelection(.enabled)
                            }
                        }
                        ForEach(contracts) { c in
                            InterfaceCard(session: session, contract: c, fill: true)
                        }
                        if !rows.isEmpty { Eyebrow("Where it happens") }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                    if rows.isEmpty {
                        Text("No changed lines point at this connection; it's on the map for the flow.")
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

struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Two parts and the exchange between them, drawn like a one-step sequence diagram:
/// what's sent along the top, what comes back underneath.
struct ExchangeDiagram: View {
    @Bindable var session: PRSession
    let edge: Edge

    var body: some View {
        let tint = edge.change == .unchanged ? Color.text2 : edge.change.color
        HStack(spacing: 0) {
            end(edge.from)
            VStack(spacing: 8) {
                arrow(text: edge.sends.isEmpty ? edge.label : edge.sends, token: edge.how.token(via: edge.via), forward: true, tint: tint)
                if !edge.returns.isEmpty {
                    arrow(text: edge.returns, token: nil, forward: false, tint: Color.text2)
                }
            }
            .frame(maxWidth: .infinity)
            end(edge.to)
        }
        .padding(14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.22))
                BlueprintGrid().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .hairline(12)
    }

    private func end(_ id: String) -> some View {
        let c = session.map.component(id)
        let change = c?.change ?? .unchanged
        return Button {
            session.select(id)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: Glyph.component(c?.kind ?? ""))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(change == .unchanged ? Color.text2 : change.color)
                Text(c?.name ?? id)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.text1)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 104)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x0C1220)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(change == .unchanged ? Color.white.opacity(0.14) : change.color.opacity(0.7), lineWidth: 0.9))
        }
        .buttonStyle(.plain)
        .help("Open \(c?.name ?? id)")
    }

    private func arrow(text: String, token: String?, forward: Bool, tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                if let token {
                    Text(token).font(.mono(8, .bold)).foregroundStyle(Color.calm)
                }
                Text(text)
                    .font(.mono(10.5, .medium))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 6)
            HStack(spacing: 0) {
                if !forward { Image(systemName: "arrowtriangle.left.fill").font(.system(size: 6)).foregroundStyle(tint.opacity(0.8)) }
                HLine()
                    .stroke(tint.opacity(0.65), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: forward ? edge.how.dash : []))
                    .frame(height: 2)
                if forward { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 6)).foregroundStyle(tint.opacity(0.8)) }
            }
        }
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
                if !step.data.isEmpty {
                    Text(step.data)
                        .font(.mono(11))
                        .foregroundStyle(Color.sonar.opacity(active ? 1 : 0.75))
                        .lineLimit(1)
                }
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
