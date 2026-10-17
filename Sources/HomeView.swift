// Before any PR is open: the name, a paste field, and what's waiting for you.

import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)
            VStack(spacing: 12) {
                FathomGlyph()
                    .frame(width: 40, height: 40)
                    .padding(.bottom, 4)
                Text("Fathom")
                    .font(.serif(44))
                    .tracking(-0.3)
                    .foregroundStyle(Color.text1)
                Text("Pick a pull request on the left to read its story, or paste a link.")
                    .font(.serifItalic(17))
                    .foregroundStyle(Color.text3)
            }
            LinkField()
                .frame(maxWidth: 560)
                .padding(.top, 30)

            if store.setup.needsAttention {
                SetupCard()
                    .padding(.top, 38)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else if !store.forYou.isEmpty {
                WaitingList()
                    .frame(maxWidth: 560)
                    .padding(.top, 40)
            }
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.spring, value: store.setup.needsAttention)
    }
}

/// Everything waiting for your review, in any repository: the one list the sidebar can't show.
struct WaitingList: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Waiting for your review")
                .padding(.leading, 12)
                .padding(.bottom, 4)
            ForEach(store.forYou.prefix(6)) { pr in
                WaitingRow(pr: pr) { store.open(pr.ref) }
            }
        }
    }
}

struct WaitingRow: View {
    let pr: PRSummary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(Color.sonar).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.text1)
                        .lineLimit(1)
                    Text(verbatim: "\(pr.ref.slug) #\(pr.ref.number) · \(pr.author) · \(Fmt.ago(pr.updatedAt))")
                        .font(.mono(10.5))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.text3.opacity(hover ? 1 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.wash(hover ? 0.04 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
    }
}
