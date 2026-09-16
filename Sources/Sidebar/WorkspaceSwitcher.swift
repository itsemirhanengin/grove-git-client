import SwiftUI

/// The workspace switcher: the pill at the top of the sidebar, and the dropdown
/// it opens.
///
/// The dropdown **floats over** the sidebar rather than pushing it down. It is
/// an overlay in the same window, not a `.popover`: a popover is a separate
/// window with its own arrow and chrome, and this needs to read as part of the
/// sidebar.
///
/// It no longer morphs. The matched-geometry version was replaced on
/// 2026-09-16 — the owner wanted a dropdown that covers the list and a much
/// quieter animation, and the morph was the reason the panel had to be inline
/// in the first place.
struct WorkspaceSwitcher: View {
    let model: AppModel

    @Binding var isOpen: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much vertical room the pill needs, including its padding. The
    /// sidebar list insets by exactly this, and the dropdown starts here.
    static var barHeight: CGFloat { Metrics.switcherPill + Space.md * 2 }

    private var others: [URL] {
        model.recentWorkspaces.filter { $0.path() != model.workspace?.root.path() }
    }

    var body: some View {
        pill
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .overlay(alignment: .top) {
                if isOpen {
                    panel
                        .padding(.horizontal, Space.md)
                        .offset(y: Self.barHeight)
                        // Opacity and a slight settle from the top edge. Enough
                        // to say where it came from, not enough to watch.
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        )
                }
            }
            .animation(Motion.standard(reduceMotion: reduceMotion), value: isOpen)
    }

    // MARK: Pill

    private var pill: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.workspace?.name ?? "No Workspace")
                        .font(Typography.repoName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.secondaryDetail.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Space.sm)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.lg)
            .frame(height: Metrics.switcherPill)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .appGlass(in: .capsule)
        .accessibilityLabel("Workspace")
        .accessibilityValue(model.workspace?.name ?? "None")
        .accessibilityHint(isOpen ? "Closes the workspace list" : "Opens the workspace list")
        .help(model.workspace?.root.path() ?? "Choose a folder of repositories")
    }

    private var subtitle: String? {
        guard let workspace = model.workspace else { return nil }
        let repos = workspace.repos.count
        guard repos > 0 else { return nil }
        let changes = workspace.totalDirtyCount
        let repoLabel = repos == 1 ? "1 repository" : "\(repos) repositories"
        return changes == 0 ? repoLabel : "\(repoLabel) · \(changes) changes"
    }

    // MARK: Dropdown

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if others.isEmpty {
                Text("No other workspaces yet")
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.lg)
                    .frame(height: Metrics.fileRow)
            } else {
                // Not a `List`: this is a bounded set — eight at most, by
                // `AppStateStore.recentLimit` — and a scroll view floating over
                // the sidebar's own scroll view is a worse thing to use.
                ForEach(others, id: \.self) { url in
                    WorkspaceRow(
                        url: url,
                        onOpen: {
                            isOpen = false
                            Task { await model.open(url) }
                        },
                        onForget: { model.forgetWorkspace(url) }
                    )
                }
            }

            Divider()
                .padding(.vertical, Space.xs)

            Button {
                isOpen = false
                Task { await model.chooseWorkspace() }
            } label: {
                Label("Open Workspace…", systemImage: "folder.badge.plus")
                    .font(Typography.fileName)
                    .padding(.horizontal, Space.lg)
                    .frame(height: Metrics.fileRow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            // No ⌘O here: the toolbar already owns it, and two views claiming
            // one shortcut is undefined rather than redundant.
            .buttonStyle(.plain)
        }
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlass(in: .rect(cornerRadius: Radius.lg))
    }
}

/// One recent workspace.
private struct WorkspaceRow: View {
    let url: URL
    let onOpen: () -> Void
    let onForget: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Space.sm) {
                Text(url.lastPathComponent)
                    .font(Typography.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Space.sm)

                if isHovering {
                    Button(action: onForget) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from this list")
                    .accessibilityLabel("Remove \(url.lastPathComponent) from recent workspaces")
                }
            }
            .padding(.horizontal, Space.lg)
            .frame(height: Metrics.fileRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .onHover { isHovering = $0 }
        .help(url.path(percentEncoded: false))
    }
}
