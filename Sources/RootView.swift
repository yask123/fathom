// The window: the pull requests on the left when you want them, and the stage — home, or one pull request.

import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarShown && !store.focus {
                Sidebar()
                    .frame(width: 304)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(Color.wash(0.07)).frame(width: 0.5)
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
        .containerBackground(for: .window) { Backdrop() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { store.windowWidth = $0 }
        .task {
            // FATHOM_SETTINGS=1 opens Settings on launch, for screenshots.
            if store.env["FATHOM_SETTINGS"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                openSettings()
            }
        }
    }
}

/// The window's ground: near-black, with a little violet light falling in from the top edge. Flat on paper.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.canvas
            if scheme == .dark {
                RadialGradient(colors: [Color.signal.opacity(0.12), Color.signal.opacity(0)],
                               center: UnitPoint(x: 0.5, y: -0.18), startRadius: 0, endRadius: 520)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar

/// Like a desktop Git client: one repository at a time, its open pull requests in a plain list.
struct Sidebar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40)
            RepoSwitcher()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            HStack(spacing: 18) {
                ForEach(AppStore.PullFilter.allCases) { f in
                    let on = store.pullFilter == f
                    let n = count(f)
                    Button {
                        withAnimation(Motion.snappy) { store.pullFilter = f }
                    } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 5) {
                                Text(f.title.lowercased())
                                    .font(.mono(11.5, on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.text1 : Color.text3)
                                if n > 0 {
                                    Text("\(n)")
                                        .font(.mono(10, .medium))
                                        .foregroundStyle(f == .forYou ? Color.signal : Color.text3)
                                }
                            }
                            Capsule().fill(on ? Color.signal : .clear).frame(height: 1.5)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)

            Rule(opacity: 0.07)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = store.repoError ?? store.inboxError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.changed)
                            .padding(14)
                    } else if store.viewer == nil && store.setup.checked && !store.hasGH {
                        Text("Pull requests show up here once GitHub is connected.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.text3)
                            .padding(14)
                    }
                    let pulls = store.shownPulls
                    if pulls.isEmpty && store.repo != nil && store.repoError == nil && !store.repoLoading {
                        Text(emptyText)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.text3)
                            .padding(14)
                    }
                    ForEach(pulls) { pr in
                        PullRow(pr: pr, selected: store.session?.ref == pr.ref, requested: store.isRequested(pr),
                                sounded: store.isSounded(pr), reading: store.readingAhead == pr.ref)
                            .onTapGesture { store.open(pr.ref) }
                            .contextMenu {
                                Button("Open on GitHub") { NSWorkspace.shared.open(pr.ref.web) }
                                Button("Copy Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(pr.ref.web.absoluteString, forType: .string)
                                }
                            }
                        Rectangle().fill(Color.wash(0.04)).frame(height: 0.5).padding(.leading, 14)
                    }
                }
            }
            .scrollIndicators(.never)
            .refreshable { await store.refreshRepo() }

            SidebarFooter()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.sidebar)
    }

    private func count(_ f: AppStore.PullFilter) -> Int {
        let mine = store.viewer?.login ?? ""
        switch f {
        case .forYou: return store.repoPulls.filter { store.isRequested($0) }.count
        case .all: return store.repoPulls.count
        case .mine: return store.repoPulls.filter { $0.author == mine }.count
        }
    }

    private var emptyText: String {
        switch store.pullFilter {
        case .forYou: "Nothing here is waiting for your review."
        case .all: "No open pull requests."
        case .mine: "You have no open pull requests here."
        }
    }
}

/// The current repository; click for the others, ones waiting on you first.
struct RepoSwitcher: View {
    @Environment(AppStore.self) private var store
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.repo.map { String($0.split(separator: "/").first ?? "") } ?? "Repository")
                        .font(.mono(10, .medium))
                        .tracking(0.6)
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                    Text(store.repo.map { String($0.split(separator: "/").last ?? "") } ?? "Choose a repository")
                        .font(.mono(13.5, .semibold))
                        .foregroundStyle(Color.text1)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if store.repoLoading {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.text3)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.wash(hover || open ? 0.05 : 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.wash(0.1), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            RepoList { slug in
                store.selectRepo(slug)
                open = false
            }
            .environment(store)
        }
    }
}

struct RepoList: View {
    @Environment(AppStore.self) private var store
    let pick: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let repos = store.repos.filter { query.isEmpty || $0.slug.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter, or type owner/repo", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.wash(0.05)))
                .padding(10)
                .onSubmit {
                    if let first = repos.first { pick(first.slug) }
                    else if query.split(separator: "/").count == 2 { pick(query.trimmingCharacters(in: .whitespaces)) }
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(repos) { r in
                        RepoRow(repo: r, waiting: store.waiting(in: r.slug), current: r.slug == store.repo) { pick(r.slug) }
                    }
                    if repos.isEmpty && query.split(separator: "/").count == 2 {
                        RepoRow(repo: RepoInfo(slug: query, open: 0), waiting: 0, current: false) { pick(query) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 330)
        .onAppear { focused = true }
    }
}

struct RepoRow: View {
    let repo: RepoInfo
    let waiting: Int
    let current: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.name)
                        .font(.system(size: 13, weight: current ? .semibold : .medium))
                        .foregroundStyle(Color.text1)
                    Text(repo.owner)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.text3)
                }
                Spacer()
                if waiting > 0 {
                    Text("\(waiting) for you")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.signal)
                } else if repo.open > 0 {
                    Text("\(repo.open) open")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                }
                if current {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.text2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.wash(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
    }
}

/// One pull request in the list: what it's called, who and when, and whether it waits on you.
struct PullRow: View {
    let pr: PRSummary
    let selected: Bool
    let requested: Bool
    let sounded: Bool
    var reading = false
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(requested ? Color.signal : Color.clear)
                .frame(width: 5, height: 5)
                .neon(.signal, radius: 4, strength: requested ? 0.8 : 0)
                .padding(.top, 6)
                .help(requested ? "Your review is requested" : "")
            VStack(alignment: .leading, spacing: 5) {
                Text(pr.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color.text1.opacity(selected ? 1 : 0.86))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pr.ref.number)")
                        .font(.mono(10.5))
                    Text("·")
                    Avatar(url: pr.authorAvatar, name: pr.author, size: 13)
                    Text(pr.author).lineLimit(1)
                    Text("·")
                    Text(Fmt.ago(pr.updatedAt)).font(.mono(10.5))
                    if pr.isDraft {
                        Text("Draft").font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(Color.text3.opacity(0.5), lineWidth: 0.5))
                    }
                    Spacer(minLength: 0)
                    if let checks = pr.checks { ChecksDot(state: checks) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.text3)
            }
            if reading {
                Pip().frame(width: 12, height: 12).help("\(Brand.name) is reading this now")
            } else if sounded {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.signal.opacity(0.7))
                    .padding(.top, 4)
                    .help("Already traced: it opens at once")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .background(Color.wash(selected ? 0.05 : hover ? 0.025 : 0))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.signal).frame(width: 1.5).neon(.signal, radius: 4, strength: 0.8) }
        }
        .contentShape(Rectangle())
        .onHover { hover = QA.hover($0) }
    }
}

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
                SettingsLink {
                    Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.signal)
                        .lineLimit(1)
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
                    Text("Claude Sonnet — quickest").tag("sonnet")
                    Text("Claude Opus — deeper, slower").tag("opus")
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Appearance", selection: $store.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Play a sound when a trace is ready", isOn: $store.ping)
                Toggle("Trace new review requests in the background", isOn: $store.autoRead)
                    .help("\(Brand.name) reads PRs waiting for you before you open them, so they open at once. Uses your Claude plan.")
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.signal)
                    Text(store.model == "opus" ? "opus" : "sonnet")
                        .font(.mono(11, .medium))
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
            Text("›")
                .font(.mono(compact ? 13 : 16, .bold))
                .foregroundStyle(focused ? Color.signal : Color.text3)
            TextField(compact ? "paste a pull request link" : "paste a pull request link, or owner/repo#123", text: $text)
                .textFieldStyle(.plain)
                .font(.mono(compact ? 12 : 13.5))
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
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.signal))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, compact ? 11 : 16)
        .frame(height: compact ? 34 : 48)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.well(focused ? 0.34 : 0.2))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(bad ? Color.removed.opacity(0.8) : focused ? Color.signal.opacity(0.7) : Color.wash(0.12),
                              lineWidth: focused || bad ? 1 : 0.5)
                .neon(bad ? .removed : .signal, radius: 8, strength: focused || bad ? 0.35 : 0)
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

/// The mark: a trace. It leaves a ring, takes the turn the change takes, and lands lit; the road not taken runs on
/// a little way, dashed, and stops.
struct TraceMark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let lw = max(1.4, h * 0.065)
            let a = CGPoint(x: w * 0.12, y: h * 0.7), b = CGPoint(x: w * 0.38, y: h * 0.7)
            let c = CGPoint(x: w * 0.58, y: h * 0.32), d = CGPoint(x: w * 0.82, y: h * 0.32)
            let e = CGPoint(x: w * 0.68, y: h * 0.7)
            var alt = Path()
            alt.move(to: b)
            alt.addLine(to: e)
            ctx.stroke(alt, with: .color(.wash(0.34)), style: StrokeStyle(lineWidth: lw * 0.75, lineCap: .round, dash: [lw * 1.2, lw * 2]))
            let r = lw * 1.5
            ctx.stroke(Path(ellipseIn: CGRect(x: e.x + lw * 0.6, y: e.y - r, width: r * 2, height: r * 2)), with: .color(.wash(0.4)), lineWidth: lw * 0.7)
            var main = Path()
            main.move(to: a)
            main.addLine(to: b)
            main.addLine(to: c)
            main.addLine(to: d)
            if scheme == .dark {
                ctx.stroke(main, with: .color(Color.signal.opacity(0.1)), style: StrokeStyle(lineWidth: lw * 5, lineCap: .round, lineJoin: .round))
                ctx.stroke(main, with: .color(Color.signal.opacity(0.22)), style: StrokeStyle(lineWidth: lw * 2.6, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(main, with: .color(Color.signal), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            let s = lw * 1.9
            ctx.fill(Path(ellipseIn: CGRect(x: a.x - s, y: a.y - s, width: s * 2, height: s * 2)), with: .color(Color.canvas))
            ctx.stroke(Path(ellipseIn: CGRect(x: a.x - s, y: a.y - s, width: s * 2, height: s * 2)), with: .color(Color.signal), lineWidth: lw)
            let t = lw * 2.1
            if scheme == .dark {
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - t * 1.9, y: d.y - t * 1.9, width: t * 3.8, height: t * 3.8)), with: .color(Color.added.opacity(0.16)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - t, y: d.y - t, width: t * 2, height: t * 2)), with: .color(Color.added))
        }
    }
}
