// Sending the review: your line comments, a summary, and a verdict — posted to GitHub through `gh`.

import SwiftUI

struct ReviewSheet: View {
    @Bindable var session: PRSession
    @Environment(\.dismiss) private var dismiss
    @State private var verdict: GitHub.Verdict = .comment
    @FocusState private var summaryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your review")
                        .font(.serif(26))
                        .foregroundStyle(Color.text1)
                    Text("\(session.ref.id) · \(session.detail?.title ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.text3)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            if let url = session.submittedURL {
                sent(url)
            } else {
                comments
                summary
                verdicts
                if let error = session.submitError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.removed)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack {
                    Text(needsSummary ? "Say what needs to change in the summary" : "Posts to GitHub as @\(session.store?.viewer?.login ?? "you")")
                        .font(.system(size: 11))
                        .foregroundStyle(needsSummary ? Color.changed : Color.text3)
                    Spacer()
                    Button("Not yet") { dismiss() }
                        .buttonStyle(.glass)
                    Button {
                        session.submit(verdict, body: session.reviewBody)
                    } label: {
                        HStack(spacing: 6) {
                            if session.submitting { ProgressView().controlSize(.small) }
                            Text(sendTitle)
                        }
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(verdictTint)
                    .disabled(session.submitting || needsSummary || !session.canSend(verdict, body: session.reviewBody))
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(26)
        .frame(width: 640)
        .defaultFocus($summaryFocused, true)
        .onAppear {
            // The summary, not the first comment, is where the cursor belongs.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                summaryFocused = true
            }
        }
        .background(Color(hex: 0x0B0F16))
        .preferredColorScheme(.dark)
    }

    /// GitHub won't take a request for changes without words.
    private var needsSummary: Bool {
        session.reviewPosted == nil && verdict == .requestChanges && session.reviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendTitle: String {
        if session.reviewPosted != nil { return "Send the replies left" }
        switch verdict {
        case .comment: return "Send comments"
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        }
    }

    private var verdictTint: Color {
        switch verdict {
        case .comment: Color(hex: 0x1F6F6B)
        case .approve: Color(hex: 0x2E7D4F)
        case .requestChanges: Color(hex: 0x8A5A1C)
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("On the code")
                Text("\(session.pending.count)").font(.mono(10, .semibold)).foregroundStyle(Color.text3)
                let left = session.pending.count - session.sendableComments.count
                if left > 0 {
                    Spacer()
                    Text("\(left) left out — empty, or the line is gone in the latest commit")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.changed)
                }
            }
            if session.pending.isEmpty {
                Text("None yet. In Changes, click a line number (or the + beside it) to comment on that line, or Reply under someone's comment.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(session.pending) { c in
                            PendingRow(session: session, comment: c)
                        }
                    }
                }
                .frame(maxHeight: 250)
                .scrollIndicators(.never)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Summary")
            ZStack(alignment: .topLeading) {
                if session.reviewBody.isEmpty {
                    Text("Optional. What you think overall, and anything for the author.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.text3)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $session.reviewBody)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .focused($summaryFocused)
            }
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
        }
    }

    private var verdicts: some View {
        HStack(spacing: 8) {
            option(.comment, "Comment", "text.bubble", "Feedback without a verdict")
            option(.approve, "Approve", "checkmark.seal", "Good to merge")
            option(.requestChanges, "Request changes", "exclamationmark.bubble", "Needs work first")
        }
    }

    private func option(_ v: GitHub.Verdict, _ title: String, _ icon: String, _ detail: String) -> some View {
        let on = verdict == v
        let tint: Color = v == .approve ? .added : v == .requestChanges ? .changed : .sonar
        return Button {
            withAnimation(Motion.snappy) { verdict = v }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(on ? tint : Color.text2)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? tint.opacity(0.1) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? tint.opacity(0.5) : Color.white.opacity(0.07), lineWidth: 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sent(_ url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.added)
                .symbolEffect(.bounce, value: url)
            Text("Review sent")
                .font(.serif(22))
                .foregroundStyle(Color.text1)
            HStack(spacing: 10) {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.glass)
                Button("Done") {
                    session.submittedURL = nil
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .tint(Color(hex: 0x1F6F6B))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct PendingRow: View {
    @Bindable var session: PRSession
    let comment: PendingComment
    @State private var text = ""
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: comment.replyTo == nil ? "text.bubble" : "arrowshape.turn.up.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.sonar)
                Text("\((comment.path as NSString).lastPathComponent):\(comment.line)")
                    .font(.mono(11, .medium))
                    .foregroundStyle(Color.text2)
                if let who = repliedTo {
                    Text("reply to \(who)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                } else if comment.side == "LEFT" {
                    Text("removed line")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.text3)
                }
                Spacer()
                Button {
                    session.removeComment(comment.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Color.text3)
                }
                .buttonStyle(.plain)
                .opacity(hover ? 1 : 0.5)
                .help("Remove this comment")
            }
            if let code = codeLine {
                Text(code.trimmingCharacters(in: .whitespaces))
                    .font(.mono(11))
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.25)))
            }
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.text1)
                .lineLimit(1...6)
                .onChange(of: text) { session.updateComment(comment.id, body: text) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        .onHover { hover = QA.hover($0) }
        .onAppear { text = comment.body }
    }

    /// The line the comment is on, as it reads in this commit.
    private var codeLine: String? {
        session.diff?.hunk(comment.hunk)?.lines.first { l in
            comment.side == "LEFT" ? (l.kind == .del && l.old == comment.line) : (l.kind != .del && l.new == comment.line)
        }?.text
    }

    private var repliedTo: String? {
        guard let to = comment.replyTo else { return nil }
        return session.detail?.threads.first { $0.replyTo == to }?.comments.first.map { "@\($0.displayName)" } ?? "a thread"
    }
}
