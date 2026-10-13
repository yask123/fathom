// The window: a floating glass inbox on the left, and the stage — home, or one pull request.

import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarShown {
                Sidebar()
                    .frame(width: 286)
                    .padding(.leading, 10)
                    .padding(.vertical, 10)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                if let session = store.session {
                    PRView(session: session)
                        .id(session.ref.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                } else {
                    HomeView()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .containerBackground(for: .window) { DepthBackdrop() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { store.windowWidth = $0 }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38)

            HStack(spacing: 9) {
                FathomGlyph()
                    .frame(width: 22, height: 22)
                Text("Fathom")
                    .font(.serif(23, .medium))
                    .tracking(-0.2)
                    .foregroundStyle(Color.text1)
                Spacer()
                Button {
                    Task { await store.refreshInbox() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.text3)
                        .rotationEffect(.degrees(store.inboxLoading ? 360 : 0))
                        .animation(store.inboxLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                                   value: store.inboxLoading)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh (⌘R)")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            if store.session != nil {
                // On the home screen the big field does this.
                LinkField(compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = store.inboxError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.changed)
                            .padding(.horizontal, 8)
                    }
                    InboxSection(title: "Waiting for you", items: store.forYou,
                                 empty: store.viewer == nil ? nil : "Nothing waiting on you.")
                    InboxSection(title: "Yours", items: store.yours, empty: nil)
                    InboxSection(title: "Reviewed, still open", items: store.reviewed, empty: nil)
                    InboxSection(title: "Recent", items: recents, empty: nil)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                       .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }

            SidebarFooter()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(24, tint: .sidebarTint)
    }

    private var recents: [PRSummary] {
        let shown = Set((store.forYou + store.yours + store.reviewed).map(\.id))
        return store.recents.filter { !shown.contains($0.id) }
    }
}

struct InboxSection: View {
    @Environment(AppStore.self) private var store
    let title: String
    let items: [PRSummary]
    let empty: String?

    var body: some View {
        if !items.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Eyebrow(title)
                    if !items.isEmpty {
                        Text("\(items.count)")
                            .font(.mono(10, .semibold))
                            .foregroundStyle(Color.text3)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                if items.isEmpty, let empty {
                    Text(empty)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.text3)
                        .padding(.horizontal, 10)
                }
                ForEach(items) { pr in
                    InboxRow(pr: pr, selected: store.session?.ref == pr.ref, sounded: store.isSounded(pr),
                             reading: store.readingAhead == pr.ref)
                        .onTapGesture { store.open(pr.ref) }
                        .contextMenu {
                            Button("Open on GitHub") { NSWorkspace.shared.open(pr.ref.web) }
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(pr.ref.web.absoluteString, forType: .string)
                            }
                            if title == "Recent" {
                                Divider()
                                Button("Remove from Recent") { store.forget(pr.ref) }
                            }
                        }
                }
            }
        }
    }
}

struct InboxRow: View {
    let pr: PRSummary
    let selected: Bool
    let sounded: Bool
    var reading = false
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: pr.authorAvatar, name: pr.author, size: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(pr.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.text1.opacity(selected ? 1 : 0.9))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    if let checks = pr.checks { ChecksDot(state: checks) }
                    Text(verbatim: "\(pr.ref.repo) #\(pr.ref.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                    if pr.isDraft {
                        Text("Draft").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.text3)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(Color.text3.opacity(0.5), lineWidth: 0.5))
                    }
                    Spacer(minLength: 4)
                    DiffStat(additions: pr.additions, deletions: pr.deletions, bar: false, size: 10)
                        .opacity(0.85)
                    Text(Fmt.ago(pr.updatedAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.075 : hover ? 0.035 : 0))
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.sonar.opacity(0.28), lineWidth: 0.75)
            }
        }
        .overlay(alignment: .topTrailing) {
            if reading {
                SonarPip()
                    .frame(width: 12, height: 12)
                    .padding(5)
                    .help("Fathom is reading this now")
            } else if sounded {
                Circle().fill(Color.sonar.opacity(0.8)).frame(width: 5, height: 5)
                    .padding(8)
                    .help("Fathom has read this commit")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
    }
}

/// Failing checks, quietly; passing and pending ones only when asked for (`always`).
struct ChecksDot: View {
    let state: String
    var always = false
    var body: some View {
        if always || state == "FAILURE" || state == "ERROR" {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .help("Checks: \(state.lowercased())")
        }
    }

    private var color: Color {
        switch state {
        case "SUCCESS": .added
        case "FAILURE", "ERROR": .removed
        case "PENDING", "EXPECTED": .changed
        default: .text3
        }
    }
}

struct SidebarFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 9) {
            if let v = store.viewer {
                Avatar(url: v.avatar, name: v.login, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.name.isEmpty ? v.login : v.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.text1)
                        .lineLimit(1)
                    Text("@\(v.login)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                }
            } else if store.setup.checked && !store.hasGH {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.text3)
                Text("GitHub not connected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.text3)
                SettingsLink {
                    Text("Set Up")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.sonar)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.text3)
                Text("Connecting to GitHub…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.text3)
            }
            Spacer()
            Menu {
                Picker("Model", selection: $store.model) {
                    Text("Claude Opus — deepest").tag("opus")
                    Text("Claude Sonnet — quicker").tag("sonnet")
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Sonar ping when a reading is done", isOn: $store.ping)
                Toggle("Read new review requests in the background", isOn: $store.autoRead)
                    .help("Fathom reads PRs waiting for you before you open them. Uses your Claude plan.")
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.sonar)
                    Text(store.model == "opus" ? "Opus" : "Sonnet")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.text2)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Which Claude reads your PRs (through Claude Code)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(Color.hair).frame(height: 0.5).padding(.horizontal, 14) }
    }
}

/// Paste a PR link; Enter opens it.
struct LinkField: View {
    @Environment(AppStore.self) private var store
    var compact = false
    @State private var text = ""
    @State private var bad = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: compact ? 11 : 14, weight: .semibold))
                .foregroundStyle(focused ? Color.sonar : Color.text3)
            TextField(compact ? "Paste a pull request link" : "Paste a pull request link — or owner/repo#123", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 12.5 : 16))
                .foregroundStyle(Color.text1)
                .focused($focused)
                .textContentType(nil)
                .onSubmit(open)
            if !text.isEmpty {
                Button(action: open) {
                    Image(systemName: "return")
                        .font(.system(size: compact ? 10 : 12, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: compact ? 20 : 26, height: compact ? 20 : 26)
                        .background(Circle().fill(Color.sonar))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, compact ? 11 : 18)
        .frame(height: compact ? 34 : 54)
        .background {
            Capsule().fill(Color.black.opacity(focused ? 0.32 : 0.2))
        }
        .overlay {
            Capsule().strokeBorder(bad ? Color.removed.opacity(0.7) : focused ? Color.sonar.opacity(0.45) : Color.white.opacity(0.08),
                                   lineWidth: focused || bad ? 1 : 0.5)
        }
        .offset(x: bad ? -4 : 0)
        .animation(Motion.snappy, value: focused)
        .animation(Motion.snappy, value: text.isEmpty)
        .onChange(of: store.linkFocusTick) { if compact { focused = true } }
    }

    private func open() {
        guard let ref = PRRef.parse(text) else {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.3)) { bad = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(Motion.snappy) { bad = false }
            }
            return
        }
        text = ""
        focused = false
        store.open(ref)
    }
}

/// The mark: three strata and a sounding line ending in a ping.
struct FathomGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            for i in 0..<3 {
                let y = h * (0.42 + CGFloat(i) * 0.2)
                var p = Path()
                p.move(to: CGPoint(x: w * 0.06, y: y))
                p.addCurve(to: CGPoint(x: w * 0.94, y: y),
                           control1: CGPoint(x: w * 0.36, y: y - h * 0.09),
                           control2: CGPoint(x: w * 0.64, y: y + h * 0.09))
                ctx.stroke(p, with: .color(Color.depth(i + 1).opacity(0.9 - Double(i) * 0.18)), style: StrokeStyle(lineWidth: max(1.2, w * 0.075), lineCap: .round))
            }
            var line = Path()
            line.move(to: CGPoint(x: w * 0.5, y: h * 0.04))
            line.addLine(to: CGPoint(x: w * 0.5, y: h * 0.7))
            ctx.stroke(line, with: .color(Color.sonar.opacity(0.85)), style: StrokeStyle(lineWidth: max(1, w * 0.06), lineCap: .round))
            let r = w * 0.11
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.5 - r, y: h * 0.72 - r, width: r * 2, height: r * 2)), with: .color(Color.sonar))
        }
    }
}
