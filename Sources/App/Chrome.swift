import SwiftUI

/// The header band over the file list, when the sidebar points at a repository.
///
/// It is a *caption*, not a control panel: which branch, tracking what, how far
/// apart they have drifted. Fetch, pull and push used to live here as five
/// bordered controls crammed into a 380pt column — they are now in the window
/// toolbar, which is where a repository-wide action belongs and where there is
/// room for it to be one clear icon instead of a button with a label and a
/// disclosure arrow.
struct RepoBreadcrumbBar: View {
    let repo: RepoViewModel

    var body: some View {
        PaneHeader {
            BranchPill(label: repo.branchLabel, isDetached: repo.isDetached)

            if let upstream = repo.status.upstream {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(upstream)
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            AheadBehindBadge(ahead: repo.status.ahead, behind: repo.status.behind)

            Spacer(minLength: Space.md)

            if repo.isBusy {
                ProgressView().controlSize(.mini)
            }
        }
        .help(repo.repository.root.path())
    }
}

/// The header band over the Overview: what the all-repositories list is scoped
/// to, and how much of the workspace that scope is hiding.
struct RepoScopeBar: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        PaneHeader {
            Picker("Scope", selection: $workspace.scope) {
                ForEach(RepoScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            Spacer(minLength: Space.md)

            if workspace.isFiltering, workspace.hiddenRepoCount > 0 {
                Text("\(workspace.hiddenRepoCount) hidden")
                    .font(Typography.secondaryDetail.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            if workspace.failedRepoCount > 0 {
                // Reported here rather than as an alert: a background fetch that
                // fails across ten repositories must not produce ten modal
                // interruptions.
                Label(
                    "\(workspace.failedRepoCount) failed",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Typography.secondaryDetail)
                .foregroundStyle(Palette.attention.color)
            }
        }
    }
}

/// Fetch, pull and push for the repository the window is pointed at.
///
/// In the window toolbar rather than over the file list. The objection to that
/// used to be that a toolbar button whose target changes silently is how a
/// client pushes the wrong branch — which is answered by the window title,
/// which now names the repository and the branch these three act on, and by
/// their absence entirely when the sidebar is on the Overview.
struct RepoNetworkActions: View {
    let repo: RepoViewModel

    var body: some View {
        Button("Fetch", systemImage: "arrow.trianglehead.2.clockwise") { repo.fetch() }
            .help("Fetch all remotes")
            .disabled(repo.isBusy)

        // A menu with a primary action: clicking pulls fast-forward only,
        // holding offers the two ways of reconciling a branch that has moved on
        // both sides. Neither happens by accident.
        Menu {
            Button(RepoEngine.PullStrategy.merge.title) { repo.pull(.merge) }
            Button(RepoEngine.PullStrategy.rebase.title) { repo.pull(.rebase) }
        } label: {
            Label(pullHelp, systemImage: "arrow.down")
        } primaryAction: {
            repo.pull(.fastForwardOnly)
        }
        .menuIndicator(.hidden)
        .help(pullHelp)

        Button(pushHelp, systemImage: "arrow.up") { repo.push() }
            .disabled(!repo.canPush)
            .help(pushHelp)
    }

    private var pullHelp: String {
        repo.status.behind > 0
            ? "Pull \(repo.status.behind) from the upstream branch"
            : "Pull from the upstream branch"
    }

    /// "Publish" rather than "Push" when there is no upstream, because that is
    /// a different act: it decides where a branch lives, once.
    private var pushHelp: String {
        if repo.needsUpstream { return "Publish and set the upstream branch" }
        return repo.status.ahead > 0 ? "Push \(repo.status.ahead) to upstream" : "Push to upstream"
    }
}
