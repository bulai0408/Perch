import SwiftUI

/// 1.4 「连不上 %@。看看电脑开着、手机和它在同一个网络。」 with 「换一台」,
/// when there is another computer to switch to.
struct UnreachableBar: View {
    @Environment(ConnectionStore.self) private var connection

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("连不上 \(connection.computerName ?? "")。看看电脑开着、手机和它在同一个网络。")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Menu {
                ForEach(connection.computers.filter { $0.id != connection.currentID }) { c in
                    Button {
                        connection.select(c.id)
                    } label: {
                        Text(verbatim: c.name)
                        Text(verbatim: ComputerStatusText.menu(connection.status(of: c)))
                    }
                }
            } label: {
                Text("换一台")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("switch-computer")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unreachable-bar")
    }
}

/// Settings → 电脑: one row per computer.
struct ComputerRow: View {
    let computer: Computer
    let current: Bool
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Monogram(text: computer.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: computer.name)
                    .font(.body)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                // No scheme; a long one wraps to a second line before
                // `:port`, never inside the host or the port, never cut.
                Text(MagpieAddress.wrappingText(computer.address))
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: MagpieAddress.shown(computer.address)))
            }
            // The address takes the free width before the Spacer does, so
            // `192.168.1.30:3425` stays on one line when it fits; the status
            // keeps its full width and is never cut.
            .layoutPriority(1)
            Spacer(minLength: 4)
            Text(verbatim: status)
                .font(.footnote)
                .foregroundStyle(status.hasPrefix("●") && status.contains("已连接") ? Color.good : Color.ink2)
                .lineLimit(1)
                .fixedSize()
            if current {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

// MARK: - magpie 版本

/// Pushes the release notes of the newest magpie.
struct ReleaseNotesRoute: Hashable {}

/// 额度 banner: 「office-mac 上的 magpie 有新版本 0.1.4283」, 「看看改了什么」, ✕.
struct VersionBanner: View {
    let computer: String
    let release: MagpieRelease

    @Environment(VersionStore.self) private var versions

    private var version: String { release.version?.description ?? release.tag }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(computer) 上的 magpie 有新版本 \(version)")
                    .font(.system(size: 15))
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink(value: ReleaseNotesRoute()) {
                    Text("看看改了什么")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("version-banner-notes")
            }
            Spacer(minLength: 4)
            Button {
                withAnimation { versions.dismissBanner() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("关闭"))
            .accessibilityIdentifier("version-banner-close")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("version-banner")
    }
}

/// 「magpie %@ 改了什么」: the release's notes, then 「在电脑上的 magpie
/// 里更新。Perch 不会替你更新。」. Perch never triggers an update.
struct ReleaseNotesView: View {
    @Environment(VersionStore.self) private var versions

    private var release: MagpieRelease? { versions.newer ?? versions.latest }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let release {
                    if let published = release.published {
                        Text(verbatim: published.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh-Hans"))))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(Self.blocks(release.notes).enumerated()), id: \.offset) { _, block in
                        block.view
                    }
                }
                Text("在电脑上的 magpie 里更新。Perch 不会替你更新。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                    .accessibilityIdentifier("release-notes-footer")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .perchScreen(sky: false)
        .navigationTitle(Text("magpie \(release?.version?.description ?? release?.tag ?? "") 改了什么"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("release-notes")
    }

    /// One parsed line of release notes.
    enum Block {
        case heading(String)
        case bullet(String)
        case text(String)

        @ViewBuilder var view: some View {
            switch self {
            case .heading(let t):
                Text(Self.inline(t)).font(.headline).padding(.top, 8).accessibilityAddTraits(.isHeader)
            case .bullet(let t):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").accessibilityHidden(true)
                    Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                }
                .font(.body)
            case .text(let t):
                Text(Self.inline(t)).font(.body).fixedSize(horizontal: false, vertical: true)
            }
        }

        /// Inline Markdown (bold, code, links) as an attributed string.
        static func inline(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
    }

    /// GitHub release notes are Markdown: headings, bullets, paragraphs.
    static func blocks(_ notes: String) -> [Block] {
        notes.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmed
            if line.isEmpty { return nil }
            if line.hasPrefix("#") { return .heading(String(line.drop { $0 == "#" }).trimmed) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
            return .text(line)
        }
    }
}
