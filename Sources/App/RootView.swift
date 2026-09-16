import AppKit
import Combine
import SwiftUI

/// Grove's three-column shell.
///
/// The layout follows Tower — sidebar, list, detail — with one change that is
/// the reason Grove exists: Tower is one window per repository, whereas here the
/// **repository is the top-level sidebar item**. Selecting one expands it in
/// place to reveal its sections. Pinned above them is `Overview`, the
/// all-repos-at-once view.
struct RootView: View {
    @State private var model = AppModel()
    @State private var selection: SidebarSelection? = .overview
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The repository the sidebar points at, or `nil` in the Overview.
    private var selectedRepo: RepoViewModel? {
        guard case .repo(let id, _) = selection else { return nil }
        return model.workspace?.repos.first { $0.id == id }
    }

    /// Which repository's diff the column shows.
    ///
    /// In a repository section it is whatever the sidebar points at. In the
    /// **Overview** the sidebar points at no repository at all, so it is
    /// whichever one owns the row that was last clicked — without this, clicking
    /// a file in the Overview did nothing at all.
    private var focusedRepo: RepoViewModel? {
        guard let workspace = model.workspace else { return nil }
        if case .repo(let id, _) = selection {
            return workspace.repos.first { $0.id == id }
        }
        guard let focused = workspace.focusedRepoID else { return nil }
        return workspace.repos.first { $0.id == focused }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarColumn(model: model, selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: Metrics.sidebarMinWidth,
                    ideal: Metrics.sidebarIdealWidth,
                    max: Metrics.sidebarMaxWidth
                )
        } content: {
            ListColumn(model: model, selection: selection)
                // The scope bar filters *this* column, so it lives here rather
                // than in `.accessoryBar`. An accessory bar spans the whole
                // window, which meant the detail column carried 32pt of empty
                // strip above the file name for a control it does not own.
                .safeAreaBar(edge: .top, spacing: 0) {
                    // The bar describes whatever the column below it holds: the
                    // scope filter for the all-repositories Overview, and fetch
                    // / pull / push for a single repository. A network button
                    // whose target changes with the sidebar selection is how a
                    // client pushes the wrong branch.
                    if let repo = selectedRepo {
                        RepoActionBar(repo: repo)
                    } else if let workspace = model.workspace {
                        RepoScopeBar(workspace: workspace)
                            .padding(.horizontal, Space.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
                .navigationSplitViewColumnWidth(
                    min: Metrics.listMinWidth,
                    ideal: Metrics.listIdealWidth,
                    max: Metrics.listMaxWidth
                )
        } detail: {
            DetailColumn(model: model, selection: selection)
                // Fill the column, or `safeAreaBar` attaches to the intrinsic
                // height of the empty state and the bar floats mid-pane.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .bottom) {
                    GlobalActionBar(
                        workspace: model.workspace,
                        isRefreshing: model.isRefreshing,
                        onRefresh: { Task { await model.refreshAll() } }
                    )
                }
        }
        // Once, at the root: a discard can be asked for from the file list or
        // from the diff, and those two panes are not both on screen for every
        // sidebar section.
        .repoOperationAlerts(for: focusedRepo)
        .onChange(of: selection) { _, moved in model.recordSelection(moved) }
        // Set only once a workspace has finished discovering, because before
        // that there are no repositories for a restored selection to point at.
        .onChange(of: model.restoredSelection) { _, restored in
            if let restored { selection = restored }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            model.flushState()
        }
        .navigationTitle(model.workspace?.name ?? "Grove")
        .navigationSubtitle(subtitle)
        .toolbarTitleDisplayMode(.inline)
        .windowResizeAnchor(.topLeading)
        .toolbar {
            // `sharedBackgroundVisibility(.hidden)` plus a fixed `ToolbarSpacer`
            // is what produces macOS 26's look of *separated* glass capsules
            // rather than one continuous bar. The groups are split by meaning:
            // what you are looking at, then what you can do to it.
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Workspace…", systemImage: "folder") {
                    Task { await model.chooseWorkspace() }
                }
                .help("Choose a folder of repositories (⌘O)")
                .keyboardShortcut("o", modifiers: .command)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.workspace == nil)
            }

        }
        .searchable(
            text: filterBinding,
            placement: .sidebar,
            prompt: "Filter repositories"
        )
        .task { await model.bootstrap() }
    }

    /// Bound to the workspace when there is one, and inert otherwise, so the
    /// search field can exist before a workspace is open.
    private var filterBinding: Binding<String> {
        Binding(
            get: { model.workspace?.filterText ?? "" },
            set: { model.workspace?.filterText = $0 }
        )
    }

    private var subtitle: String {
        guard let workspace = model.workspace else { return "" }
        switch workspace.discoveryState {
        case .scanning: return "Scanning…"
        case .failed(let message): return message
        case .idle: return ""
        case .ready(let count):
            let repos = count == 1 ? "1 repository" : "\(count) repositories"
            let dirty = workspace.totalDirtyCount
            return dirty == 0 ? "\(repos) · clean" : "\(repos) · \(dirty) changes"
        }
    }
}

// MARK: - Sidebar

private struct SidebarColumn: View {
    let model: AppModel
    @Binding var selection: SidebarSelection?

    @State private var isSwitcherOpen = false

    var body: some View {
        // A `ZStack` so the switcher's dropdown can float over the list instead
        // of pushing it down. The list reserves the pill's height as a safe-area
        // inset; everything below that the dropdown simply covers.
        ZStack(alignment: .top) {
            list

            if isSwitcherOpen {
                // Anywhere else in the sidebar dismisses it, the way a menu does.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { isSwitcherOpen = false }
            }

            WorkspaceSwitcher(model: model, isOpen: $isSwitcherOpen)
        }
        .onExitCommand { isSwitcherOpen = false }
    }

    private var list: some View {
        List(selection: $selection) {
            Section("Workspace") {
                Label("Overview", systemImage: "square.grid.2x2")
                    .badge(model.workspace?.totalDirtyCount ?? 0)
                    .tag(SidebarSelection.overview)
            }

            if let workspace = model.workspace {
                if workspace.repos.isEmpty {
                    Section("Repositories") {
                        Text(emptyMessage(for: workspace))
                            .font(Typography.secondaryDetail)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // `Section(isExpanded:)` rather than `DisclosureGroup`: a
                    // DisclosureGroup nested in a List renders its own chevron
                    // and indentation on top of the sidebar's, and mutating its
                    // binding during a list update triggers AppKit's reentrant
                    // NSTableView delegate warning — which is documented to
                    // become an assert.
                    ForEach(workspace.visibleRepos) { repo in
                        Section(isExpanded: expansion(for: repo, in: workspace)) {
                            ForEach(RepoSection.allCases) { section in
                                Label(section.title, systemImage: section.symbol)
                                    .tag(SidebarSelection.repo(repo.id, section))
                            }
                        } header: {
                            RepoSectionHeader(repo: repo)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // `.hard` on a dense list keeps the row grid legible where it meets the
        // chrome; `.soft` is for continuous content like code.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // Room for the switcher's pill, which is drawn over the list rather than
        // inside it.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: WorkspaceSwitcher.barHeight)
        }
    }

    private func expansion(
        for repo: RepoViewModel, in workspace: WorkspaceModel
    ) -> Binding<Bool> {
        Binding(
            get: { workspace.isExpanded(repo) },
            set: { workspace.setExpanded(repo, $0) }
        )
    }

    private func emptyMessage(for workspace: WorkspaceModel) -> String {
        switch workspace.discoveryState {
        case .scanning: "Scanning…"
        case .failed(let message): message
        default: "No repositories found"
        }
    }
}

/// The repository's name, branch and status, shown as a section header.
private struct RepoSectionHeader: View {
    let repo: RepoViewModel

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(repo.name)
                .font(Typography.repoName)
                .lineLimit(1)
                .truncationMode(.middle)

            BranchPill(label: repo.branchLabel, isDetached: repo.isDetached)

            Spacer(minLength: Space.xs)

            trailingStatus
        }
        .help(repo.repository.root.path())
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch repo.loadState {
        case .loading, .idle:
            ProgressView()
                .controlSize(.mini)

        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(repo.errorMessage ?? "Failed")

        case .missing:
            Image(systemName: "questionmark.folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Folder is missing from disk")

        case .ready:
            HStack(spacing: Space.xs) {
                if let operation = repo.status.inProgress {
                    Text(operation.label)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                AheadBehindBadge(ahead: repo.status.ahead, behind: repo.status.behind)
                if repo.dirtyCount > 0 {
                    Text("\(repo.dirtyCount)")
                        .font(Typography.secondaryDetail.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
    }
}

// MARK: - Content and detail

private struct ListColumn: View {
    let model: AppModel
    let selection: SidebarSelection?

    var body: some View {
        switch selection {
        case .overview, .none:
            if let workspace = model.workspace, !workspace.repos.isEmpty {
                WorkspaceOverview(workspace: workspace)
            } else {
                ContentUnavailableView(
                    "No Workspace",
                    systemImage: "folder.badge.plus",
                    description: Text("Choose a folder containing your git repositories.")
                )
            }

        case .repo(let repoID, let section):
            if let workspace = model.workspace,
                let repo = workspace.repos.first(where: { $0.id == repoID })
            {
                switch section {
                case .workingCopy:
                    WorkingCopyPane(repo: repo, workspace: workspace)
                case .history:
                    HistoryPane(repo: repo)
                case .branches:
                    BranchesPane(repo: repo)
                default:
                    ContentUnavailableView(
                        section.title,
                        systemImage: section.symbol,
                        description: Text("Coming in a later phase.")
                    )
                }
            } else {
                ContentUnavailableView(
                    "Repository unavailable",
                    systemImage: "questionmark.folder",
                    description: Text("It may have been removed from the workspace.")
                )
            }
        }
    }
}

/// Every repository and its changes on one screen — the view the whole
/// multi-repo idea exists for.
private struct WorkspaceOverview: View {
    let workspace: WorkspaceModel

    /// `ScrollView` + `LazyVStack` rather than `List`.
    ///
    /// Each repository's rows appear as its status refresh lands, so this
    /// column's row count changes several times while the view is still
    /// settling. Driving an `NSTableView` that way trips AppKit's reentrant
    /// delegate check — a warning today, an assert in a future macOS. A stack
    /// has no table behind it, so asynchronously growing content is a non-event,
    /// and this column is a reading surface that wants full-bleed rows rather
    /// than list chrome anyway.
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(workspace.visibleRepos) { repo in
                    Section {
                        content(for: repo)
                    } header: {
                        header(for: repo)
                    }
                }
            }
            .padding(.bottom, Space.xl)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    @ViewBuilder
    private func content(for repo: RepoViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = repo.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.orange)
                    .frame(height: Metrics.fileRow)
            } else if repo.status.changes.isEmpty {
                Text("No changes")
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
                    .frame(height: Metrics.fileRow)
            } else {
                // Conflicts come first and are never folded into the other
                // groups: a conflicted path is neither staged nor simply
                // modified, so filtering by those two states makes the one file
                // that actually blocks the user disappear from the list.
                group(
                    "Conflicts", repo.displayedConflicted,
                    total: repo.status.conflicted.count, staged: false, in: repo)
                group(
                    "Staged", repo.displayedStaged,
                    total: repo.status.staged.count, staged: true, in: repo)
                group(
                    "Changes", repo.displayedUnstaged,
                    total: repo.status.unstaged.count + repo.status.untracked.count,
                    staged: false, in: repo)

                if repo.hasMoreThanDisplayed {
                    OverflowRow(hidden: repo.hiddenRowCount)
                }
            }
        }
        .padding(.horizontal, Space.lg)
    }

    /// `total` is the real number of changes, which is not the number of rows
    /// rendered once the display cap kicks in. Showing the rendered count would
    /// quietly under-report how much work is uncommitted.
    @ViewBuilder
    private func group(
        _ title: String, _ changes: [FileChange], total: Int, staged: Bool,
        in repo: RepoViewModel
    ) -> some View {
        if !changes.isEmpty {
            GroupLabelRow(title: title, count: total, shown: changes.count)
            ForEach(changes.map { ChangeRowItem(change: $0, staged: staged) }) { item in
                let change = item.change
                ChangeRow(
                    change: change,
                    staged: staged,
                    // The Overview is a reading surface: it opens diffs and does
                    // not offer stage or discard. Those belong next to the
                    // commit composer, where the consequence is visible.
                    isSelected: workspace.focusedRepoID == repo.id
                        && repo.selectedChange == SelectedChange(change: change, staged: staged),
                    onSelect: { workspace.select(change, staged: staged, in: repo) }
                )
            }
        }
    }

    private func header(for repo: RepoViewModel) -> some View {
        HStack(spacing: Space.sm) {
            Text(repo.name).font(Typography.repoName)
            BranchPill(label: repo.branchLabel, isDetached: repo.isDetached)
            if let operation = repo.status.inProgress {
                Text(operation.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
            Spacer()
            AheadBehindBadge(ahead: repo.status.ahead, behind: repo.status.behind)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.sectionHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct DetailColumn: View {
    let model: AppModel
    let selection: SidebarSelection?

    var body: some View {
        if let repo = focusedRepo, isShowingHistory {
            // History is read-only: the same diff view, pointed at a commit
            // rather than at the working copy.
            if let commit = repo.selectedCommit, let change = repo.selectedCommitChange {
                DiffPane(
                    repo: repo,
                    selection: SelectedChange(change: change, staged: true),
                    commitOID: commit.oid
                )
            } else {
                ContentUnavailableView(
                    "No Commit Selected",
                    systemImage: "clock",
                    description: Text("Select a commit, then a file within it.")
                )
            }
        } else if let repo = focusedRepo, let selected = repo.selectedChange {
            // A conflicted file is not a diff. It has no staged/unstaged side to
            // switch between and no lines to stage — it has three versions and a
            // decision, which is a different pane.
            if selected.change.isConflicted {
                ConflictPane(repo: repo, change: selected.change)
            } else {
                DiffPane(repo: repo, selection: selected)
            }
        } else {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.text",
                description: Text("Select a changed file to view its diff.")
            )
        }
    }

    private var isShowingHistory: Bool {
        if case .repo(_, .history) = selection { return true }
        return false
    }

    /// Which repository's diff the column shows.
    ///
    /// In a repository section it is whatever the sidebar points at. In the
    /// **Overview** the sidebar points at no repository at all, so it is
    /// whichever one owns the row that was last clicked — without this, clicking
    /// a file in the Overview did nothing at all.
    private var focusedRepo: RepoViewModel? {
        guard let workspace = model.workspace else { return nil }
        if case .repo(let id, _) = selection {
            return workspace.repos.first { $0.id == id }
        }
        guard let focused = workspace.focusedRepoID else { return nil }
        return workspace.repos.first { $0.id == focused }
    }
}

#Preview {
    RootView()
        .frame(width: 1280, height: 800)
}
