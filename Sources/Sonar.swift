// While Claude reads: a sonar display. Changed files are returns on the scope; when Claude opens a file it pings,
// and files it reaches for outside the diff appear at the edge as context.

import SwiftUI

struct SonarView: View {
    @Bindable var session: PRSession

    var body: some View {
        let files = (session.diff?.signalFiles ?? []).map { f in
            ScopeFile(path: f.path, name: f.name, weight: min(Double(f.additions + f.deletions), 400) / 400,
                      tint: f.status == .added ? .added : f.status == .deleted ? .removed : .sonar)
        }
        let started: Date = {
            if case .running(let d) = session.storyState { return d }
            return Date()
        }()
        VStack(spacing: 0) {
            SonarScope(files: files, opened: session.activity.compactMap(\.path).uniqued())
                .overlay(alignment: .top) {
                    VStack(spacing: 6) {
                        Text(caption)
                            .font(.serif(18))
                            .foregroundStyle(Color.text1)
                            .contentTransition(.opacity)
                        TimelineView(.periodic(from: .now, by: 1)) { tl in
                            Text(subcaption(elapsed: tl.date.timeIntervalSince(started)))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.text3)
                                .monospacedDigit()
                        }
                    }
                    .padding(.top, 18)
                }
            Ticker(activity: session.activity)
                .frame(height: 92)
                .padding(.bottom, 4)
        }
        .animation(Motion.soft, value: caption)
    }

    private var caption: String {
        if session.checkoutState.isRunning { return "Checking out the code" }
        if session.activity.isEmpty { return "Reading the diff" }
        return "Sounding the codebase"
    }

    private func subcaption(elapsed: Double) -> String {
        let clock = Fmt.clock(elapsed)
        if session.checkoutState.isRunning, let sha = session.detail?.headSha.prefix(7) {
            return "\(session.ref.slug) at \(sha) · \(clock)"
        }
        let n = session.activity.count
        if n == 0 { return "Claude is charting what this PR touches · \(clock)" }
        let files = Set(session.activity.compactMap(\.path)).count
        return "\(n) lookup\(n == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s") opened · \(clock)"
    }
}

/// The last few things Claude looked at.
struct Ticker: View {
    let activity: [Activity]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(activity.suffix(4).enumerated()), id: \.element.id) { i, a in
                let age = activity.suffix(4).count - 1 - i
                HStack(spacing: 7) {
                    Image(systemName: a.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.sonar.opacity(0.8))
                    Text(a.verb)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.text3)
                    Text(a.target)
                        .font(.mono(11))
                        .foregroundStyle(Color.text2)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .opacity(1 - Double(age) * 0.24)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
        }
        .frame(maxWidth: 520)
        .animation(Motion.spring, value: activity.count)
    }
}
