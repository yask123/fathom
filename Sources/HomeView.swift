// Before any pull request is open: the mark, a place to paste a link, and what's waiting for you.

import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)
            VStack(spacing: 14) {
                TraceMark()
                    .frame(width: 64, height: 40)
                    .padding(.bottom, 2)
                Text(Brand.name.lowercased())
                    .font(.mono(30, .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.text1)
                Text("Pick a pull request, or paste a link, and watch what it does.")
                    .font(.sans(14))
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
        VStack(alignment: .leading, spacing: 4) {
            SectionMark(title: "Waiting for you", note: "\(store.forYou.count)")
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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
                Circle().fill(Color.signal).frame(width: 5, height: 5)
                    .neon(.signal, radius: 4, strength: 0.8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(.sans(13.5, .medium))
                        .foregroundStyle(Color.text1)
                        .lineLimit(1)
                    Text(verbatim: "\(pr.ref.slug) #\(pr.ref.number) · \(pr.author) · \(Fmt.ago(pr.updatedAt))")
                        .font(.mono(10.5))
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.signal.opacity(hover ? 1 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.wash(hover ? 0.045 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = QA.hover($0) }
    }
}
