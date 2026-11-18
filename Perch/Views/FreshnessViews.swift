import SwiftUI
import UIKit

// MARK: - Status capsule

/// The trailing toolbar capsule on 额度, Agent, 路由组 and 账号详情:
/// [glyph] computer name · freshness. Tapping it opens 「换一台电脑」.
struct StatusCapsule: View {
    let computer: String
    /// nil: just the name (no data read yet anywhere).
    var freshness: Freshness?

    @Environment(ConnectionStore.self) private var connection
    @Environment(\.addComputer) private var addComputer

    private var offline: Bool { freshness?.isUnreachable == true }

    /// Screen width − 2 × 16 − 80.
    private var maxWidth: CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
        return max(160, screen - 32 - 80)
    }

    var body: some View {
        Menu {
            Section("换一台电脑") {
                ForEach(connection.computers) { c in
                    Button {
                        connection.select(c.id)
                    } label: {
                        if c.id == connection.currentID {
                            Label(c.name, systemImage: "checkmark")
                        } else {
                            Text(verbatim: c.name)
                        }
                        Text(verbatim: ComputerStatusText.menu(connection.status(of: c), current: c.id == connection.currentID, offline: offline))
                    }
                    .accessibilityIdentifier("computer-menu-\(c.name)")
                }
            }
            Divider()
            Button {
                addComputer()
            } label: {
                Label("添加电脑…", systemImage: "plus")
            }
            .accessibilityIdentifier("add-computer-menu")
        } label: {
            // Relative times re-render every 30 s.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                label(now: context.date)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: freshness.map { FreshnessText.spoken(computer: computer, $0) } ?? computer))
        .accessibilityHint(Text("轻点换一台电脑"))
        .accessibilityIdentifier("status-capsule")
    }

    private func label(now: Date) -> some View {
        let status = freshness.flatMap { FreshnessText.status($0, now: now) }
        return HStack(spacing: 6) {
            CapsuleGlyph(state: glyph)
                .frame(width: 9, height: 9)
            HStack(spacing: 4) {
                HStack(spacing: 0) {
                    Text(verbatim: computer)
                        .fontWeight(.medium)
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let status {
                        Text(verbatim: " · " + status)
                            .foregroundStyle(.ink2)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.25), value: status)
                    }
                }
                .font(.footnote.monospacedDigit())
                // ⌄ in every state, never cut. No
                // ink3 token in Theme: ink2 at 60 %.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.ink2.opacity(0.6))
                    .fixedSize()
                    .layoutPriority(2)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(maxWidth: maxWidth)
        .background(Color.card, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
        .contentShape(.capsule)
    }

    private var glyph: CapsuleGlyph.State {
        guard let freshness else { return .connected }
        if freshness.isUnreachable { return .unreachable }
        if freshness.refreshing { return .refreshing }
        return .connected
    }
}

/// The capsule's 9 pt glyph slot: good dot, accent ring spinner, warn
/// hollow dot.
struct CapsuleGlyph: View {
    enum State { case connected, refreshing, unreachable }
    let state: State

    var body: some View {
        switch state {
        case .connected:
            Circle().fill(Color.good).frame(width: 7, height: 7)
        case .unreachable:
            Circle().strokeBorder(Color.warn, lineWidth: 1.5).frame(width: 7, height: 7)
        case .refreshing:
            Spinner()
        }
    }

    /// 270° arc, 1.5 pt, one turn per 0.9 s; static under Reduce Motion.
    private struct Spinner: View {
        @Environment(\.accessibilityReduceMotion) private var reduce
        @SwiftUI.State private var turned = false

        var body: some View {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees(turned ? 360 : 0))
                .onAppear {
                    guard !reduce else { return }
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turned = true }
                }
                .accessibilityIdentifier("capsule-spinner")
        }
    }
}

extension View {
    /// The capsule in the toolbar; at AX sizes on its own row under the
    /// large title, left-aligned.
    func statusCapsule(computer: String, freshness: Freshness?) -> some View {
        modifier(StatusCapsulePlacement(computer: computer, freshness: freshness))
    }
}

private struct StatusCapsulePlacement: ViewModifier {
    let computer: String
    let freshness: Freshness?
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.safeAreaInset(edge: .top, spacing: 0) {
                StatusCapsule(computer: computer, freshness: freshness)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StatusCapsule(computer: computer, freshness: freshness)
                }
                .plainBackground()
            }
        }
    }
}

// MARK: - Whole page failed

/// 「没读到最新的，下面是 10:42 的数据。」 重试 — below the title, above
/// the first card. The data below stays at 100 %.
struct StaleBanner: View {
    let since: Date
    let now: Date
    var retry: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.warn)
                .accessibilityHidden(true)
            Text(verbatim: FreshnessText.banner(since, now: now))
                .font(.subheadline)
                .foregroundStyle(.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: retry) {
                Text("重试").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(.accentColor)
            .accessibilityIdentifier("stale-retry")
        }
        .padding(12)
        .background(Color.warn.opacity(scheme == .dark ? 0.16 : 0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stale-banner")
    }
}

// MARK: - One block failed

/// The footer row of a card whose own read failed: hairline, warn 6 pt
/// dot, 「这张没读到最新的，还是 10:42 的数据。」. Tap retries the block.
struct StaleFooter: View {
    let since: Date
    let now: Date
    /// False in a List row (the list draws the separator).
    var hairline = true
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if hairline { Rectangle().fill(Color.hairline).frame(height: 0.5) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Color.warn).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(verbatim: FreshnessText.cardFooter(since, now: now))
                    .font(.caption)
                    .foregroundStyle(.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(.rect)
        .onTapGesture { retry?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(retry == nil ? [] : .isButton)
        .accessibilityHint(retry == nil ? Text(verbatim: "") : Text("轻点重试"))
        .accessibilityIdentifier("card-stale-footer")
    }
}

// MARK: - Manual refresh feedback

/// One pull to refresh's end: soft impact + 「已更新」, or `.warning` +
/// 「没读到最新的」. Never for automatic loads.
struct PullOutcome: Equatable {
    var count = 0
    var ok = true

    mutating func record(_ ok: Bool) {
        count += 1
        self.ok = ok
    }
}

extension View {
    func pullFeedback(_ outcome: PullOutcome) -> some View {
        self
            .sensoryFeedback(trigger: outcome) { _, new in
                new.count == 0 ? nil : (new.ok ? Haptic.refreshed : Haptic.refreshFailed)
            }
            .onChange(of: outcome) { _, new in
                guard new.count > 0 else { return }
                AccessibilityNotification.Announcement(new.ok ? String(localized: "已更新") : String(localized: "没读到最新的")).post()
            }
    }
}

// MARK: - Collapsing the offline card and the banner

/// Reports `fraction` of its content's height and pins the content to the
/// top, so the views below move up exactly as the content shrinks.
struct CollapseLayout: Layout {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * max(0, min(1, fraction)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Height and opacity on one curve; the part below the shrinking frame is
/// masked off so nothing below ever slides under a fading card. Only at rest
/// does the mask leave room below for the card's shadow: once collapsing it
/// cuts exactly at the frame, so the card never overlaps what moves up.
struct Collapse: ViewModifier {
    var fraction: Double

    func body(content: Content) -> some View {
        CollapseLayout(fraction: fraction) { content }
            .opacity(fraction)
            .mask {
                Rectangle()
                    .padding(.horizontal, -32)
                    .padding(.top, -32)
                    .padding(.bottom, fraction >= 1 ? -32 : 0)
            }
    }
}

extension AnyTransition {
    /// Removal: collapse. Insertion as given.
    static func collapsing(insertion: AnyTransition) -> AnyTransition {
        .asymmetric(insertion: insertion,
                    removal: .modifier(active: Collapse(fraction: 0), identity: Collapse(fraction: 1)))
    }

    /// The page banner: in with opacity + move(top), out collapsing.
    static var staleBanner: AnyTransition { .collapsing(insertion: .opacity.combined(with: .move(edge: .top))) }
    /// The offline card: in with a fade, out collapsing.
    static var offlineCard: AnyTransition { .collapsing(insertion: .opacity) }
}
