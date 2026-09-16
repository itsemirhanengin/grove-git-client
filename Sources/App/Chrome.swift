import SwiftUI

/// The second toolbar row: what the workspace is scoped to.
///
/// Lives in `ToolbarItemPlacement.accessoryBar`, which is a real second row in
/// the window's title bar, so it sits *inside* the system's shared background
/// rather than floating over content. That is why it is deliberately **not**
/// glass — stacking our own material on the title bar's would just look muddy.
struct RepoScopeBar: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: Space.lg) {
            Picker("Scope", selection: $workspace.scope) {
                ForEach(RepoScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if workspace.isFiltering, workspace.hiddenRepoCount > 0 {
                Text("\(workspace.hiddenRepoCount) hidden")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(height: Metrics.accessoryBar)
    }
}

/// The bar pinned to the bottom of the detail column.
///
/// Attached with `safeAreaBar(edge:)` rather than a `VStack` + `overlay`, and
/// deliberately not `.toolbar` — macOS has no `bottomBar` placement, that is
/// iOS/watchOS only. `safeAreaBar` also insets the scroll content above it, so
/// the last row stays reachable instead of hiding under the glass, and it
/// participates in the scroll edge effect.
struct GlobalActionBar: View {
    let workspace: WorkspaceModel?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Space.lg) {
            HStack(spacing: Space.lg) {
                statusLabel

                Spacer(minLength: Space.xl)

                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .symbolEffect(.rotate, isActive: isRefreshing)
                }
                .buttonStyle(.plain)
                .help("Refresh all repositories (⌘R)")
                .disabled(workspace == nil)
            }
            .padding(.horizontal, Space.xl)
            .frame(height: Metrics.bar)
            .appGlass(in: .capsule)
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.md)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let workspace {
            HStack(spacing: Space.sm) {
                // Failures are reported here rather than as an alert: a
                // background fetch that fails across ten repositories must not
                // produce ten modal interruptions.
                if workspace.failedRepoCount > 0 {
                    Label(
                        "\(workspace.failedRepoCount) failed",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Palette.attention.color)
                }

                Text(summary(for: workspace))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        } else {
            Text("No workspace")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(for workspace: WorkspaceModel) -> String {
        switch workspace.discoveryState {
        case .scanning: "Scanning…"
        case .failed(let message): message
        case .idle: ""
        case .ready(let count):
            {
                let repos = count == 1 ? "1 repo" : "\(count) repos"
                let dirty = workspace.totalDirtyCount
                return dirty == 0 ? "\(repos) · clean" : "\(repos) · \(dirty) changes"
            }()
        }
    }
}

/// Fetch, pull and push for the repository the list column is showing.
///
/// These live in a bar over the file list rather than in the window toolbar:
/// the toolbar is workspace-scoped — open a folder, refresh everything — and a
/// button whose target silently changes with the sidebar selection is how a
/// client pushes the wrong branch.
struct RepoActionBar: View {
    let repo: RepoViewModel

    var body: some View {
        HStack(spacing: Space.md) {
            BranchPill(label: repo.branchLabel, isDetached: repo.isDetached)
            AheadBehindBadge(ahead: repo.status.ahead, behind: repo.status.behind)

            if let operation = repo.status.inProgress {
                Text(operation.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Palette.attention.color)

                Button("Abort") { repo.abortInProgress() }
                    .font(Typography.secondaryDetail)
                    .disabled(repo.isBusy)

                // Only once nothing is conflicted any more. A merge commit with
                // an unresolved file in it is not something to offer a shortcut
                // to.
                Button("Continue") { repo.continueMerge() }
                    .font(Typography.secondaryDetail)
                    .disabled(!repo.canContinueMerge)
                    .help("Commit the \(operation.label.lowercased()) with git's own message")
            }

            Spacer(minLength: Space.md)

            if repo.isBusy {
                ProgressView().controlSize(.mini)
            }

            Button("Fetch", systemImage: "arrow.down.circle") { repo.fetch() }
                .labelStyle(.iconOnly)
                .help("Fetch all remotes")
                .disabled(repo.isBusy)

            // A menu with a primary action: clicking pulls fast-forward only,
            // holding offers the two ways of reconciling a branch that has
            // moved on both sides. Neither happens by accident.
            Menu {
                Button(RepoEngine.PullStrategy.merge.title) { repo.pull(.merge) }
                Button(RepoEngine.PullStrategy.rebase.title) { repo.pull(.rebase) }
            } label: {
                Label(pullTitle, systemImage: "arrow.down")
            } primaryAction: {
                repo.pull(.fastForwardOnly)
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(!repo.canPull && repo.status.behind == 0 && repo.isBusy)
            .help("Pull from the upstream branch")

            Button(pushTitle, systemImage: "arrow.up") { repo.push() }
                .fixedSize()
                .disabled(!repo.canPush)
                .help(repo.needsUpstream ? "Push and set the upstream branch" : "Push to upstream")
        }
        .font(Typography.secondaryDetail)
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.accessoryBar)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var pullTitle: String {
        repo.status.behind > 0 ? "Pull \(repo.status.behind)" : "Pull"
    }

    /// "Publish" rather than "Push" when there is no upstream, because that is
    /// a different act: it decides where a branch lives, once.
    private var pushTitle: String {
        if repo.needsUpstream { return "Publish" }
        return repo.status.ahead > 0 ? "Push \(repo.status.ahead)" : "Push"
    }
}
