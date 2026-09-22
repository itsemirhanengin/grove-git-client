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
///
/// The redesign's one structural rule lives here: every column opens with a
/// ``PaneHeader`` of exactly ``Metrics/paneHeader``, so the three bottom borders
/// land on the same y and meet the column dividers. Nothing floats over
/// anything; nothing is rounded; nothing is inset from an edge it shares.
struct RootView: View {
    let model: AppModel

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
            ListColumn(
                model: model,
                selection: selection,
                onOpenRepo: { selection = .repo($0, .workingCopy) }
            )
            .paneBackground()
            // The header describes whatever the column below it holds: the
            // scope filter for the all-repositories Overview, the branch and
            // its upstream for a single repository.
            .safeAreaBar(edge: .top, spacing: 0) { listHeader }
            .chromeBackground()
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
                .chromeBackground()
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
        // The title bar draws its own translucent background over the content
        // columns — but not over the sidebar, where macOS runs the sidebar
        // material straight up through it. That is the whole reason the strip
        // above the file list came out several shades lighter than the strip
        // above the sidebar: same colour underneath, one of them seen through an
        // extra pane of glass. Hiding it lets ``chromeBackground()`` show
        // through unaltered, so the band across the top of the window is one
        // colour from edge to edge.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbarTitleDisplayMode(.inline)
        .windowResizeAnchor(.topLeading)
        .toolbar { toolbarContent }
        .task { await model.bootstrap() }
    }

    @ViewBuilder
    private var listHeader: some View {
        if let repo = selectedRepo {
            RepoBreadcrumbBar(repo: repo)
        } else if let workspace = model.workspace {
            RepoScopeBar(workspace: workspace)
        } else {
            PaneHeader { Spacer() }
        }
    }

    /// Fetch / pull / push act on the repository the title names, and disappear
    /// entirely on the Overview — where "push" would have no single answer.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let repo = selectedRepo {
                RepoNetworkActions(repo: repo)
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refreshAll() }
            }
            .symbolEffect(.rotate, isActive: model.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.workspace == nil)
        }
    }

    /// The window says what the toolbar acts on. That is the whole reason
    /// fetch / pull / push were allowed to move up there.
    private var title: String {
        if let repo = selectedRepo { return repo.name }
        return model.workspace?.name ?? "Grove"
    }

    private var subtitle: String {
        if let repo = selectedRepo {
            guard case .repo(_, let section) = selection else { return repo.branchLabel }
            return "\(section.title) · \(repo.branchLabel)"
        }
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

    var body: some View {
        list
            // Above the list rather than over it. The switcher used to float,
            // which left the sidebar with no top edge for the other columns'
            // headers to align to.
            //
            // `spacing` is not 0 here, unlike every other band in the window:
            // the first thing under it is a list section label, and a label
            // sitting directly on a border reads as part of the header rather
            // than as the start of the content.
            .safeAreaInset(edge: .top, spacing: Space.md) {
                WorkspaceSwitcher(model: model)
            }
            // The repository filter, in the strip Tower keeps for workspace
            // chrome. It was a system search field in the header band, which
            // cost the sidebar the one row that has to align across columns.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RepoFilterField(model: model)
            }
    }

    /// The sidebar list.
    ///
    /// **No `selection:` binding**, which is deliberate and is the whole reason
    /// ``SidebarRow`` exists. `List`'s own sidebar selection is a full-row
    /// capsule filled with the accent colour, and over a translucent sidebar
    /// that fill samples the desktop behind the window — so the selected row
    /// arrived as a wide, faintly smeared blue slab rather than a crisp control.
    /// There is no public way to restyle it, so the rows opt out of selection
    /// entirely and draw their own pill, sized to the label it marks.
    ///
    /// What this costs is arrow-key navigation, which `List` provided for free.
    /// The sections, their disclosure triangles and the sidebar's own insets all
    /// still come from `List`.
    private var list: some View {
        List {
            Section("Workspace") {
                SidebarRow(
                    title: "Overview",
                    symbol: "square.grid.2x2",
                    badge: model.workspace?.totalDirtyCount ?? 0,
                    isSelected: selection == .overview,
                    select: { selection = .overview }
                )
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
                                SidebarRow(
                                    title: section.title,
                                    symbol: section.symbol,
                                    isSelected: selection == .repo(repo.id, section),
                                    select: { selection = .repo(repo.id, section) }
                                )
                            }
                        } header: {
                            RepoSectionHeader(repo: repo)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Hidden at the top, not softened. The list already has a hairline above
        // it — the workspace header's — and the scroll edge effect drew a second
        // separator plus its shadow directly underneath, which is why that one
        // border looked several times heavier than every other border in the
        // window. One band, one line.
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollEdgeEffectStyle(.hard, for: .bottom)
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

/// One navigable row in the sidebar.
///
/// The selected state is a pill around the icon and the label and **nothing
/// else** — it marks the item, not the width of the column it happens to be in.
/// The badge stays outside it, at the sidebar's right edge, where it lines up
/// with every other row's count.
///
/// The whole row is still the hit target; only the paint is short.
private struct SidebarRow: View {
    let title: String
    let symbol: String
    var badge: Int?
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(Typography.fileName)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, Space.md)
            .padding(.vertical, 3)
            .background(pill, in: .capsule)
            .fixedSize()

            Spacer(minLength: Space.sm)

            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(Typography.secondaryDetail.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var pill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        if isHovered { return AnyShapeStyle(Color.primary.opacity(0.07)) }
        return AnyShapeStyle(.clear)
    }
}

/// The sidebar's bottom strip: filter the repository list.
private struct RepoFilterField: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            TextField("Filter repositories", text: filterBinding)
                .textFieldStyle(.plain)
                .font(Typography.secondaryDetail)

            if !(model.workspace?.filterText.isEmpty ?? true) {
                Button {
                    model.workspace?.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.statusBar)
        .background(Palette.headerFill.color)
        .hairline(.top)
    }

    /// Bound to the workspace when there is one, and inert otherwise, so the
    /// field can exist before a workspace is open.
    private var filterBinding: Binding<String> {
        Binding(
            get: { model.workspace?.filterText ?? "" },
            set: { model.workspace?.filterText = $0 }
        )
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
        // A list section header runs to the sidebar's edge, so the count sat
        // flush against the column divider with nothing between them.
        .padding(.trailing, Space.sm)
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
                .foregroundStyle(Palette.attention.color)
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
                        .foregroundStyle(Palette.attention.color)
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

    /// Jumps the sidebar to one repository's Working Copy. The Overview is a
    /// reading surface, but "this is the one I need to deal with" is the
    /// conclusion it exists to produce, so it has to lead somewhere.
    let onOpenRepo: (RepoID) -> Void

    var body: some View {
        switch selection {
        case .overview, .none:
            if let workspace = model.workspace, !workspace.repos.isEmpty {
                WorkspaceOverview(workspace: workspace, onOpenRepo: onOpenRepo)
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
                case .stashes:
                    StashesPane(repo: repo)
                case .branches:
                    BranchesPane(repo: repo)
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
///
/// It is a table, and the thing that makes it one is that the repository bands
/// and the file rows share a left edge and a status column: you read straight
/// down the badges to find what is conflicted, and straight down the names to
/// find what changed, without the eye stepping in and out at every group.
private struct WorkspaceOverview: View {
    let workspace: WorkspaceModel
    let onOpenRepo: (RepoID) -> Void

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
        VStack(spacing: 0) {
            ColumnHeader {
                Text(summary)
                Spacer()
                if stagedCount > 0 {
                    Text("\(stagedCount) staged")
                        .foregroundStyle(.tint)
                        .contentTransition(.numericText())
                }
            }

            if workspace.visibleRepos.isEmpty {
                ContentUnavailableView(
                    "Nothing matches",
                    systemImage: "line.3.horizontal.decrease",
                    description: Text("No repository matches this scope and filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(workspace.visibleRepos) { repo in
                    Section {
                        content(for: repo)
                    } header: {
                        RepoBandHeader(repo: repo, onOpen: { onOpenRepo(repo.id) })
                    }
                }
            }
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private var summary: String {
        let count = workspace.visibleRepos.count
        let repos = count == 1 ? "1 repository" : "\(count) repositories"
        let dirty = workspace.totalDirtyCount
        return dirty == 0 ? "\(repos) · clean" : "\(repos) · \(dirty) changes"
    }

    private var stagedCount: Int {
        workspace.repos.reduce(0) { $0 + $1.status.staged.count }
    }

    @ViewBuilder
    private func content(for repo: RepoViewModel) -> some View {
        let changes = repo.displayedChanges

        VStack(alignment: .leading, spacing: 0) {
            if let message = repo.errorMessage {
                note(message, symbol: "exclamationmark.triangle", tint: Palette.attention.color)
            } else if changes.isEmpty {
                note("No changes", symbol: "checkmark", tint: .secondary)
            } else {
                // The Overview is a reading surface: it opens diffs and does not
                // offer stage or discard. Those belong next to the commit
                // composer, where the consequence is visible.
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    ChangeRow(
                        change: change,
                        staged: !change.isUnstaged,
                        isSelected: workspace.focusedRepoID == repo.id
                            && repo.selectedChange?.change.pathBytes == change.pathBytes,
                        onSelect: { workspace.select(change, in: repo) },
                        showsSeparator: index < changes.count - 1
                    )
                }

                if repo.hasMoreThanDisplayed {
                    OverflowRow(hidden: repo.hiddenRowCount)
                }
            }
        }
    }

    /// A repository with nothing to show still gets a row, at the same height
    /// and on the same grid as a file. A collapsed-to-nothing section would make
    /// a clean repository look like a missing one.
    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 16)
            Text(text)
            Spacer()
        }
        .font(Typography.secondaryDetail)
        .foregroundStyle(tint)
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.fileRow)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One repository's band in the Overview.
///
/// Heavier than a ``ColumnHeader`` and lighter than a ``PaneHeader``: it is the
/// only thing separating one repository's files from the next one's, so it needs
/// a rule on both edges — without the top one, a repository with no changes
/// reads as belonging to the section above it.
private struct RepoBandHeader: View {
    let repo: RepoViewModel
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(repo.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            BranchPill(label: repo.branchLabel, isDetached: repo.isDetached)

            if let operation = repo.status.inProgress {
                Text(operation.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Palette.attention.color)
            }

            Spacer(minLength: Space.md)

            AheadBehindBadge(ahead: repo.status.ahead, behind: repo.status.behind)

            if repo.status.staged.count > 0 {
                Text("\(repo.status.staged.count) staged")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tint)
            }

            if repo.dirtyCount > 0 {
                Text("\(repo.dirtyCount)")
                    .font(Typography.secondaryDetail.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.sectionBand)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.headerFill.color)
        .hairline(.top)
        .hairline(.bottom)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .help("Open \(repo.name) — \(repo.repository.root.path())")
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
                    origin: .commit(commit.oid)
                )
            } else {
                EmptyDetail(
                    title: "No Commit Selected",
                    symbol: "clock",
                    message: "Select a commit, then a file within it."
                )
            }
        } else if let repo = focusedRepo, isShowingStashes {
            if let stash = repo.selectedStash, let change = repo.selectedStashChange {
                DiffPane(
                    repo: repo,
                    selection: SelectedChange(change: change, staged: true),
                    origin: .stash(stash)
                )
            } else {
                EmptyDetail(
                    title: "No Stash Selected",
                    symbol: "tray",
                    message: "Select a stash to see what it holds."
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
            EmptyDetail(
                title: "No File Selected",
                symbol: "doc.text",
                message: "Select a changed file to view its diff."
            )
        }
    }

    private var isShowingHistory: Bool {
        if case .repo(_, .history) = selection { return true }
        return false
    }

    private var isShowingStashes: Bool {
        if case .repo(_, .stashes) = selection { return true }
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

/// The detail column with nothing in it.
///
/// Sits on the diff's own canvas rather than the window background, so the
/// column's colour does not change the instant a file is selected — which read,
/// more than anything else in the old layout, as the pane being replaced rather
/// than filled.
private struct EmptyDetail: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .diffBackground()
    }
}

#Preview {
    RootView(model: AppModel())
        .frame(width: 1280, height: 800)
}
