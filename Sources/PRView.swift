// One pull request: a thin bar of text, then the Trace (what it does, drawn) or the Code (the diff, in reading
// order). In focus, the bar goes too and only the page is left.

import SwiftUI

struct PRView: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: PRSession

    var body: some View {
        VStack(spacing: 0) {
            if !store.focus {
                TopBar(session: session, inset: store.sidebarShown ? 20 : 84)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
            ZStack {
                if let error = session.loadError {
                    LoadFailure(message: error) { session.start() }
                } else if session.diff == nil {
                    LoadingPR()
                } else {
                    // Both stay mounted so each keeps its place; the tab cross-fades between them.
                    let trace = session.tab == .brief
                    TraceView(session: session)
                        .opacity(trace ? 1 : 0)
                        .allowsHitTesting(trace)
                        .accessibilityHidden(!trace)
                    ChangesView(session: session)
                        .opacity(trace ? 0 : 1)
                        .allowsHitTesting(!trace)
                        .accessibilityHidden(trace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            if store.focus {
                FocusHint(tab: session.tab)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.opacity)
            }
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
            // Esc closes the newest thing first: a comment box, the question box, a selection in the code, a filter
            // on the code, then focus.
            Button("") {
                if session.compose != nil {
                    session.cancelCompose(discard: false)
                } else if session.askOpen {
                    withAnimation(Motion.spring) { session.askOpen = false }
                } else if session.tab == .changes, !session.selection.isEmpty {
                    session.selection.clear()
                } else if session.tab == .changes, session.fileFilter != nil {
                    session.clearFilter()
                } else if store.focus {
                    store.toggleFocus()
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
        HStack(spacing: 12) {
            if !store.sidebarShown {
                BarIcon(symbol: "sidebar.left", help: "Show the pull requests (⌃⌘S)") {
                    withAnimation(Motion.spring) { store.sidebarShown = true }
                }
                .transition(.opacity)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "\(session.ref.repo) #\(session.ref.number)")
                    .font(.mono(11.5, .medium))
                    .foregroundStyle(Color.text2)
                    .lineLimit(1)
                    .fixedSize()
                Text(session.detail?.title ?? "")
                    .font(.sans(12.5))
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            InfoButton(session: session)
            Spacer(minLength: 12)
            TabSwitch(session: session)
                .fixedSize()
            Rectangle().fill(Color.wash(0.1)).frame(width: 0.5, height: 16)
            AskButton(session: session)
            BarIcon(symbol: "viewfinder", help: "Focus: only the page (⇧⌘F)") { store.toggleFocus() }
            ReviewButton(session: session)
                .fixedSize()
        }
        .padding(.leading, inset)
        .padding(.trailing, 16)
        .padding(.top, 6)
        .frame(height: 46)
        .overlay(alignment: .bottom) { Rule(opacity: 0.07) }
        .animation(Motion.spring, value: inset)
    }
}

/// A small glyph in the bar that lights when pointed at.
struct BarIcon: View {
    let symbol: String
    let help: String
    var on = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(on ? Color.signal : hover ? Color.text1 : Color.text3)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .help(help)
    }
}

/// trace · code: two words, the current one underlined in the signal colour.
struct TabSwitch: View {
    @Bindable var session: PRSession
    @Namespace private var space

    var body: some View {
        HStack(spacing: 18) {
            ForEach(PRTab.allCases) { tab in
                let on = session.tab == tab
                Button {
                    withAnimation(Motion.spring) { session.tab = tab }
                } label: {
                    VStack(spacing: 5) {
                        Text(tab.title.lowercased())
                            .font(.mono(12, on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.text1 : Color.text3)
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 1.5)
                            if on {
                                Capsule().fill(Color.signal).frame(height: 1.5)
                                    .neon(.signal, radius: 4, strength: 0.9)
                                    .matchedGeometryEffect(id: "tab", in: space)
                            }
                        }
                    }
                    .fixedSize()
                    .padding(.top, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab == .brief ? "Trace (⌘1)" : "Code (⌘2)")
            }
        }
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
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .symbolEffect(.pulse, isActive: session.askRunning)
                Text("ask")
                    .font(.mono(12))
                Text("⌘K")
                    .font(.mono(9.5, .medium))
                    .foregroundStyle(Color.text3)
            }
            .foregroundStyle(session.askOpen || hover ? Color.signal : Color.text2)
            .frame(height: 26)
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if !session.askMessages.isEmpty && !session.askOpen {
                    Circle().fill(Color.signal).frame(width: 5, height: 5).offset(x: 6, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .help("Ask Claude about this pull request (⌘K)")
    }
}

struct ReviewButton: View {
    @Bindable var session: PRSession
    @State private var hover = false

    var body: some View {
        let pending = session.pending.count
        let lit = pending > 0 || hover
        Button {
            session.reviewOpen = true
        } label: {
            HStack(spacing: 6) {
                Text("review")
                    .font(.mono(12, .semibold))
                if pending > 0 {
                    Text("\(pending)")
                        .font(.mono(10.5, .bold))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(pending > 0 ? Color.ink : hover ? Color.signal : Color.text1)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(pending > 0 ? Color.signal : Color.signal.opacity(hover ? 0.12 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(lit ? Color.signal.opacity(0.7) : Color.wash(0.2), lineWidth: 0.9))
            .neon(.signal, radius: 8, strength: pending > 0 ? 0.45 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
        .help("Write and send your review (⌘↩)")
    }
}

/// In focus the bar is gone; this says where you are and how to get back, and fades to almost nothing.
struct FocusHint: View {
    let tab: PRTab
    @State private var fresh = true

    var body: some View {
        HStack(spacing: 10) {
            Text(tab.title.lowercased())
                .foregroundStyle(Color.text2)
            KeyHint(key: "esc", does: "leave focus")
        }
        .font(.mono(10.5))
        .opacity(fresh ? 1 : 0.28)
        .task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(Motion.slow) { fresh = false }
        }
    }
}

// MARK: - Details, on demand

/// Everything about the PR that isn't the change itself: who, where, its state, its description, and what people
/// have said about it.
struct InfoButton: View {
    @Bindable var session: PRSession
    @State private var open = false
    @State private var hover = false

    var body: some View {
        let talk = session.detail?.conversation.count ?? 0
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                if talk > 0 {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(talk)")
                        .font(.mono(10.5, .medium))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(open || hover ? Color.text1 : Color.text3)
            .frame(height: 24)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
        .help(talk > 0 ? "About this pull request, and \(talk) comment\(talk == 1 ? "" : "s")" : "About this pull request")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PRInfo(session: session) { open = false }
        }
        .task {
            // FATHOM_INFO=1 opens this on launch, for screenshots.
            if session.store?.env["FATHOM_INFO"] == "1" {
                try? await Task.sleep(for: .seconds(2.5))
                open = true
            }
        }
    }
}

struct PRInfo: View {
    @Bindable var session: PRSession
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let d = session.detail {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Avatar(url: d.authorAvatar, name: d.author, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.author)
                                .font(.sans(13, .semibold))
                                .foregroundStyle(Color.text1)
                            Text("Opened \(Fmt.since(d.createdAt)) · updated \(Fmt.since(d.updatedAt)) · \(d.commitCount) commit\(d.commitCount == 1 ? "" : "s")")
                                .font(.sans(11.5))
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
                                Text("Checks \(checks.lowercased())").font(.sans(11)).foregroundStyle(Color.text3)
                            }
                        }
                    }
                    .font(.mono(11))
                    .lineLimit(1)
                }
                .padding(18)

                let body = AuthorNote.clean(d.body)
                if !body.isEmpty || !d.conversation.isEmpty {
                    Rectangle().fill(Color.hair).frame(height: 0.5)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !body.isEmpty {
                                MarkdownText(text: body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !d.conversation.isEmpty {
                                Eyebrow("Conversation · \(d.conversation.count)")
                                    .padding(.top, body.isEmpty ? 0 : 6)
                                ForEach(d.conversation) { c in
                                    CommentBubble(author: c.displayName, avatar: c.avatar, date: c.createdAt, text: c.body,
                                                  tag: tag(c), tagTint: tint(c), link: c.url)
                                }
                            }
                        }
                        .padding(18)
                    }
                    .frame(maxHeight: 440)
                }
            }
            Rectangle().fill(Color.hair).frame(height: 0.5)
            HStack(spacing: 10) {
                if let at = session.soundedAt {
                    Text("traced by \(session.soundedModel ?? "sonnet") \(Fmt.since(at))")
                        .font(.mono(10.5))
                        .foregroundStyle(Color.text3)
                }
                Spacer()
                Button("Trace again") {
                    dismiss()
                    session.sound()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(session.isSounding)
                .help("Have Claude read this pull request again (⇧⌘R)")
                Button {
                    NSWorkspace.shared.open(session.ref.web)
                } label: {
                    Label("GitHub", systemImage: "arrow.up.right")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Open on GitHub (⇧⌘O)")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
    }

    private func tag(_ c: GHComment) -> String? {
        switch c.verdict {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "COMMENTED": c.isBot ? "Bot review" : "Review"
        case "DISMISSED": "Dismissed"
        default: c.isBot ? "Bot" : nil
        }
    }

    private func tint(_ c: GHComment) -> Color {
        switch c.verdict {
        case "APPROVED": .added
        case "CHANGES_REQUESTED": .changed
        default: .calm
        }
    }
}

struct StateTag: View {
    let detail: PRDetail

    var body: some View {
        let (word, color): (String, Color) = detail.isDraft ? ("draft", .text3)
            : detail.state == "MERGED" ? ("merged", Color.merged)
            : detail.state == "CLOSED" ? ("closed", .removed)
            : ("open", .added)
        Text(word)
            .font(.mono(10.5, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.12)))
    }
}

struct LoadingPR: View {
    var body: some View {
        VStack(spacing: 14) {
            ScanBar().frame(width: 160, height: 2)
            Text("fetching the pull request")
                .font(.mono(11))
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
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.changed)
            Text("Couldn't open this pull request")
                .font(.display(20))
                .foregroundStyle(Color.text1)
            Text(message)
                .font(.sans(12.5))
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
