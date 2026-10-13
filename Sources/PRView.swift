// One pull request: a single quiet bar, then the Map (the system, with code on demand) or the Changes.

import SwiftUI

struct PRView: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: PRSession

    var body: some View {
        VStack(spacing: 0) {
            TopBar(session: session, inset: store.sidebarShown ? 22 : 82)
            ZStack {
                if let error = session.loadError {
                    LoadFailure(message: error) { session.start() }
                } else if session.diff == nil {
                    LoadingPR()
                } else {
                    // Both stay mounted so each keeps its place; the tab cross-fades between them.
                    let map = session.tab == .brief
                    MapView(session: session)
                        .opacity(map ? 1 : 0)
                        .allowsHitTesting(map)
                        .accessibilityHidden(!map)
                    ChangesView(session: session)
                        .opacity(map ? 0 : 1)
                        .allowsHitTesting(!map)
                        .accessibilityHidden(map)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if session.askOpen && session.diff != nil {
                AskPanel(session: session)
                    .padding(.bottom, 18)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.98, anchor: .bottom)),
                                            removal: .opacity.combined(with: .offset(y: 12))))
            }
        }
        .animation(Motion.spring, value: session.askOpen)
        .background {
            // Esc closes the newest thing first: the question box, then the side panel.
            Button("") {
                if session.askOpen {
                    withAnimation(Motion.spring) { session.askOpen = false }
                } else if session.tab == .changes {
                    if session.fileFilter != nil { session.clearFilter() }
                } else if session.panel != nil || session.playingFlow != nil {
                    session.closePanel()
                }
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .sheet(isPresented: $session.reviewOpen) {
            ReviewSheet(session: session)
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "fathom-ref" {
                session.go(toReference: url)
                return .handled
            }
            return .systemAction
        })
    }
}

// MARK: - The bar

struct TopBar: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: PRSession
    let inset: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            if !store.sidebarShown {
                Button {
                    withAnimation(Motion.spring) { store.sidebarShown = true }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.text3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the inbox (⌃⌘S)")
                .transition(.opacity)
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(session.detail?.title ?? session.ref.id)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: "\(session.ref.repo) #\(session.ref.number)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
            .layoutPriority(-1)
            InfoButton(session: session)
            Spacer(minLength: 12)
            ViewSwitch(session: session)
                .fixedSize()
            AskButton(session: session)
            ReviewButton(session: session)
                .fixedSize()
        }
        .padding(.leading, inset)
        .padding(.trailing, 18)
        .padding(.top, 10)
        .frame(height: 58)
        .animation(Motion.spring, value: inset)
    }
}

/// Map | Changes, a glass capsule with a sliding pill.
struct ViewSwitch: View {
    @Bindable var session: PRSession
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PRTab.allCases) { tab in
                let on = session.tab == tab
                Button {
                    withAnimation(Motion.spring) { session.tab = tab }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.text1 : Color.text3)
                        .padding(.horizontal, 15)
                        .frame(height: 28)
                        .background {
                            if on {
                                Capsule().fill(Color.white.opacity(0.11))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "pill", in: space)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab == .brief ? "Map (⌘1)" : "Changes (⌘2)")
            }
        }
        .padding(3)
        .glassEffect(.regular.tint(Color.cardTint), in: .capsule)
    }
}

struct AskButton: View {
    @Bindable var session: PRSession
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(Motion.spring) { session.askOpen.toggle() }
            if session.askOpen { session.askFocusTick += 1 }
        } label: {
            Image(systemName: "sparkle")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(session.askOpen || hover ? Color.sonar : Color.text2)
                .symbolEffect(.pulse, isActive: session.askRunning)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if !session.askMessages.isEmpty && !session.askOpen {
                        Circle().fill(Color.sonar).frame(width: 6, height: 6).offset(x: -6, y: 6)
                    }
                }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.cardTint).interactive(), in: .circle)
        .onHover { hover = QA.hover($0) }
        .help("Ask Claude about this PR (⌘K)")
    }
}

struct ReviewButton: View {
    @Bindable var session: PRSession

    var body: some View {
        let pending = session.pending.count
        Button {
            session.reviewOpen = true
        } label: {
            HStack(spacing: 6) {
                Text("Review")
                if pending > 0 {
                    Text("\(pending)")
                        .font(.mono(10.5, .bold))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.sonar))
                        .contentTransition(.numericText())
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(Color(hex: pending > 0 ? 0x1F6F6B : 0x1A2230))
        .help("Write and send your review (⌘↩)")
    }
}

// MARK: - Details, on demand

/// Everything about the PR that isn't the change itself: who, where, its state, its description.
struct InfoButton: View {
    @Bindable var session: PRSession
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(open || hover ? Color.text1 : Color.text3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .help("About this pull request")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PRInfo(session: session) { open = false }
        }
    }
}

struct PRInfo: View {
    @Bindable var session: PRSession
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let d = session.detail {
                HStack(spacing: 10) {
                    Avatar(url: d.authorAvatar, name: d.author, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.author)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.text1)
                        Text("Updated \(Fmt.ago(d.updatedAt)) · \(d.commitCount) commit\(d.commitCount == 1 ? "" : "s")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.text3)
                    }
                    Spacer()
                    StateTag(detail: d)
                }
                HStack(spacing: 6) {
                    Text(d.headRef).foregroundStyle(Color.text2)
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.text3)
                    Text(d.baseRef).foregroundStyle(Color.text3)
                    Spacer()
                    if let checks = d.checks {
                        HStack(spacing: 5) {
                            ChecksDot(state: checks, always: true)
                            Text("Checks \(checks.lowercased())").font(.system(size: 11)).foregroundStyle(Color.text3)
                        }
                    }
                }
                .font(.mono(11))
                .lineLimit(1)

                let body = AuthorNote.clean(d.body)
                if !body.isEmpty {
                    ScrollView {
                        MarkdownText(text: body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
                }
            }
            HStack(spacing: 10) {
                if let at = session.soundedAt {
                    Text("Read by \((session.soundedModel ?? "opus").capitalized) · \(Fmt.ago(at))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.text3)
                }
                Spacer()
                Button("Read again") {
                    dismiss()
                    session.sound()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(session.isSounding)
                .help("Have Claude read this PR again (⇧⌘R)")
                Button {
                    NSWorkspace.shared.open(session.ref.web)
                } label: {
                    Label("GitHub", systemImage: "arrow.up.right")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Open on GitHub (⇧⌘O)")
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

struct StateTag: View {
    let detail: PRDetail

    var body: some View {
        let (word, color): (String, Color) = detail.isDraft ? ("Draft", .text3)
            : detail.state == "MERGED" ? ("Merged", Color(hex: 0xB49CFF))
            : detail.state == "CLOSED" ? ("Closed", .removed)
            : ("Open", .added)
        Text(word)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// A tiny sonar ping, for "working".
struct SonarPip: View {
    var body: some View {
        PingView(rings: 2, period: 1.4, dot: 4)
    }
}

struct LoadingPR: View {
    var body: some View {
        VStack(spacing: 14) {
            SonarPip().frame(width: 34, height: 34)
            Text("Fetching the pull request…")
                .font(.system(size: 13))
                .foregroundStyle(Color.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.changed)
            Text("Couldn't open this pull request")
                .font(.serif(22))
                .foregroundStyle(Color.text1)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
            Button("Try again", action: retry)
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
