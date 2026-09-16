import SwiftUI

/// The workspace switcher: the pill at the top of the sidebar that opens into
/// the list of recent workspaces.
///
/// It is **anchored in the sidebar**, not shown in a `.popover`. A popover is a
/// separate window, and glass cannot matched-geometry across one — the morph
/// this control exists for would degrade into a cross-fade. The cost is that
/// the panel pushes the list down rather than floating over the whole window,
/// which is the right trade: this is the one moment in Grove that animates.
struct WorkspaceSwitcher: View {
    let model: AppModel

    @State private var isOpen = false
    @Namespace private var morph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var others: [URL] {
        model.recentWorkspaces.filter { $0.path() != model.workspace?.root.path() }
    }

    var body: some View {
        GlassEffectContainer(spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                pill
                if isOpen { panel }
            }
        }
        .glassEffectTransition(.matchedGeometry)
        .animation(Motion.morph(reduceMotion: reduceMotion), value: isOpen)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
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
        .appGlassMorph(id: MorphID.pill, in: morph, shape: .capsule)
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

    // MARK: Panel

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
                // `AppStateStore.recentLimit` — and a scroll view inside the
                // sidebar's own scroll view is a worse thing to use than a stack.
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
        .appGlassMorph(id: MorphID.panel, in: morph, shape: .rect(cornerRadius: Radius.lg))
    }

    /// The two ends of the morph. An enum rather than strings, so a typo cannot
    /// silently produce two unrelated identities and a cross-fade.
    /// `nonisolated`, or its `Hashable` conformance is main-actor-isolated and
    /// cannot satisfy `appGlassMorph`'s `Sendable` requirement.
    private nonisolated enum MorphID: Hashable, Sendable {
        case pill
        case panel
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
