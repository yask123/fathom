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
                    .disabled(session.submitting || needsSummary
                              || (verdict == .comment && session.pending.isEmpty && session.reviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(26)
        .frame(width: 640)
        .defaultFocus($summaryFocused, true)
        .background(Color(hex: 0x0B0F16))
        .preferredColorScheme(.dark)
    }

    /// GitHub won't take a request for changes without words.
    private var needsSummary: Bool {
        verdict == .requestChanges && session.reviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendTitle: String {
        switch verdict {
        case .comment: "Send comments"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
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
                Eyebrow("Line comments")
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
                Text("None yet. In Changes, hover a line and press +, or use Comment on anything under Worth knowing.")
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
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
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
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? tint.opacity(0.1) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? tint.opacity(0.5) : Color.white.opacity(0.07), lineWidth: 0.75))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\((comment.path as NSString).lastPathComponent):\(comment.line)")
                    .font(.mono(11, .medium))
                    .foregroundStyle(Color.sonar)
                Text(comment.side == "LEFT" ? "removed line" : "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.text3)
                Spacer()
                Button {
                    session.removeComment(comment.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Color.text3)
                }
                .buttonStyle(.plain)
            }
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.text1)
                .lineLimit(1...6)
                .onChange(of: text) { session.updateComment(comment.id, body: text) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        .onAppear { text = comment.body }
    }
}
