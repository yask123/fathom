// Before any PR is open: the name, a paste field, and what's waiting for you.

import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            StrataArt()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 60)
                VStack(spacing: 14) {
                    FathomGlyph()
                        .frame(width: 46, height: 46)
                        .padding(.bottom, 6)
                    Text("Fathom")
                        .font(.serif(62, .regular))
                        .tracking(-1.2)
                        .foregroundStyle(Color.text1)
                    Text("Understand a pull request before you read it.")
                        .font(.system(size: 16.5))
                        .foregroundStyle(Color.text2)
                }
                LinkField()
                    .frame(maxWidth: 560)
                    .padding(.top, 34)

                if store.setup.needsAttention {
                    SetupCard()
                        .padding(.top, 38)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                } else if !store.forYou.isEmpty || !store.yours.isEmpty {
                    waiting
                        .padding(.top, 38)
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 40)
            .animation(Motion.spring, value: store.setup.needsAttention)
        }
    }

    private var waiting: some View {
        let items = Array((store.forYou.isEmpty ? store.yours : store.forYou).prefix(3))
        return VStack(spacing: 12) {
            Eyebrow(store.forYou.isEmpty ? "Your open pull requests" : "Waiting for your review")
            HStack(spacing: 12) {
                ForEach(items) { pr in
                    WaitingCard(pr: pr, sounded: store.isSounded(pr))
                        .onTapGesture { store.open(pr.ref) }
                }
            }
        }
        .frame(maxWidth: 900)
    }

}

struct WaitingCard: View {
    let pr: PRSummary
    let sounded: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Avatar(url: pr.ownerAvatar, name: pr.ref.owner, size: 16)
                Text(pr.ref.slug).font(.system(size: 11)).foregroundStyle(Color.text3).lineLimit(1)
                Spacer(minLength: 0)
                if sounded {
                    Circle().fill(Color.sonar).frame(width: 5, height: 5)
                }
            }
            Text(pr.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.text1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            HStack(spacing: 7) {
                Avatar(url: pr.authorAvatar, name: pr.author, size: 16)
                Text(pr.author).font(.system(size: 11)).foregroundStyle(Color.text2)
                Spacer(minLength: 0)
                DiffStat(additions: pr.additions, deletions: pr.deletions, bar: true, size: 10.5)
            }
        }
        .padding(16)
        .frame(width: 280)
        .card(20, interactive: true)
        .scaleEffect(hover ? 1.015 : 1)
        .onHover { hover = QA.hover($0) }
        .animation(Motion.snappy, value: hover)
    }
}

/// Still strata across the bottom of the home screen; only the sonar ping at depth moves.
struct StrataArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let top = h * 0.6
            let depth = CGPoint(x: w * 0.5, y: top + 2.5 * (h - top) / 5)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for i in 0..<5 {
                        let y0 = top + CGFloat(i) * (h - top) / 5
                        func y(_ x: CGFloat) -> CGFloat {
                            y0 + CGFloat(sin(Double(x) / (260 + Double(i) * 40) + Double(i) * 1.7)) * (6 + CGFloat(i) * 1.5)
                        }
                        var edge = Path()
                        for s in 0...48 {
                            let x = size.width * CGFloat(s) / 48
                            if s == 0 { edge.move(to: CGPoint(x: x, y: y(x))) } else { edge.addLine(to: CGPoint(x: x, y: y(x))) }
                        }
                        var fill = edge
                        fill.addLine(to: CGPoint(x: size.width, y: size.height))
                        fill.addLine(to: CGPoint(x: 0, y: size.height))
                        fill.closeSubpath()
                        let c = Color.depth(i)
                        ctx.fill(fill, with: .linearGradient(Gradient(colors: [c.opacity(0.07), c.opacity(0.015)]),
                                                             startPoint: CGPoint(x: 0, y: y0), endPoint: CGPoint(x: 0, y: size.height)))
                        ctx.stroke(edge, with: .color(c.opacity(0.16)), lineWidth: 1)
                    }
                    var line = Path()
                    line.move(to: CGPoint(x: depth.x, y: top - 40))
                    line.addLine(to: depth)
                    ctx.stroke(line, with: .linearGradient(Gradient(colors: [Color.sonar.opacity(0), Color.sonar.opacity(0.5)]),
                                                           startPoint: CGPoint(x: depth.x, y: top - 40), endPoint: depth),
                               lineWidth: 1)
                }
                DepthPing()
                    .frame(width: 160, height: 72)
                    .position(depth)
            }
        }
    }
}

/// The ping at the bottom of the sounding line.
struct DepthPing: View {
    var body: some View {
        PingView(rings: 2, period: 3.2, squash: 0.42, dot: 6, ringAlpha: 0.35)
    }
}
