import AppKit
import Foundation
import Observation

/// Long-lived collaborators, built once at launch.
struct AppServices {
    let environment: GitEnvironment
    let runner: GitRunner
    let limiter: GitTaskLimiter
}

@Observable
@MainActor
final class AppModel {

    var workspace: WorkspaceModel?
    var isBootstrapping = true
    var bootstrapError: String?

    /// Drives the spinning arrow in the bottom bar. A symbol effect rather than
    /// a `ProgressView`, because ten spinners in a sidebar is just noise.
    var isRefreshing = false

    /// Recently opened workspaces, newest first — what the switcher offers.
    private(set) var recentWorkspaces: [URL] = []

    /// Where the sidebar should go once a workspace has finished loading.
    /// `RootView` watches this; it is set only after discovery, because before
    /// that there are no repositories for a selection to point at.
    private(set) var restoredSelection: SidebarSelection?

    private let store: AppStateStore

    private var services: AppServices?

    /// Live refresh. One stream for the whole workspace — see ``RepoWatcher``.
    private var watcher: RepoWatcher?

    /// Resolves the git environment, then opens a workspace.
    ///
    /// Environment resolution asks a login shell for `PATH`, which costs a
    /// process, so it happens once here rather than per command.
    init(store: AppStateStore = AppStateStore()) {
        self.store = store
        self.recentWorkspaces = store.recentWorkspaces()
    }

    func bootstrap() async {
        let environment = await GitEnvironment.resolve()
        services = AppServices(
            environment: environment,
            runner: GitRunner(environment: environment),
            limiter: GitTaskLimiter()
        )
        isBootstrapping = false

        if let workspace = workspaceToOpenAtLaunch {
            await open(workspace)
        }
    }

    /// What to open on launch, in order of who gets to decide.
    ///
    /// `GROVE_WORKSPACE` first, because it exists to override everything. Then
    /// whatever was open last. The `Fixtures/` fallback stays last and stays
    /// Debug-only, so a fresh Debug build still comes up with real data on
    /// screen instead of an empty window.
    private var workspaceToOpenAtLaunch: URL? {
        if let override = ProcessInfo.processInfo.environment["GROVE_WORKSPACE"] {
            return URL(filePath: override)
        }
        return recentWorkspaces.first ?? Self.developmentWorkspace
    }

    /// Writes anything still pending. Called on the way out, where `NSApplication`
    /// gives us one chance and no later.
    func flushState() {
        store.flush()
    }

    func open(_ url: URL) async {
        guard let services else { return }

        // Stop before discovery, not after: the old workspace's repositories are
        // about to stop existing as far as this window is concerned, and a
        // refresh fired at one of them mid-swap has nothing to update.
        watcher?.stop()

        let model = WorkspaceModel(
            root: url,
            runner: services.runner,
            limiter: services.limiter
        )
        // Before `discover()`, never after: the collapsed set has to be in place
        // while the repository view models are built, or restoring it changes
        // the sidebar's row count mid-update.
        model.collapsedRepos = store.workspaceState(for: url).collapsedRepos
        model.onCollapsedReposChange = { [weak self] collapsed in
            self?.store.updateWorkspace(url) { $0.collapsedRepos = collapsed }
        }
        workspace = model

        store.recordOpened(url)
        recentWorkspaces = store.recentWorkspaces()

        await model.discover()
        startWatching()
        restoredSelection = selectionToRestore(in: model)
    }

    /// Drops a workspace from the switcher, along with what it remembered.
    func forgetWorkspace(_ url: URL) {
        store.forget(url)
        recentWorkspaces = store.recentWorkspaces()
    }

    // MARK: Sidebar selection

    private func selectionToRestore(in workspace: WorkspaceModel) -> SidebarSelection {
        let persisted = store.workspaceState(for: workspace.root)
        guard let path = persisted.selectedRepo,
            let section = persisted.selectedSection.flatMap(RepoSection.init(rawValue:)),
            let repo = workspace.repos.first(where: {
                $0.repository.relativePath(from: workspace.root) == path
            })
        else { return .overview }
        return .repo(repo.id, section)
    }

    /// Stores where the sidebar is, by **relative** path — so the selection
    /// survives the workspace folder being moved or re-cloned elsewhere.
    func recordSelection(_ selection: SidebarSelection?) {
        guard let workspace else { return }
        store.updateWorkspace(workspace.root) { state in
            guard case .repo(let id, let section) = selection,
                let repo = workspace.repos.first(where: { $0.id == id })
            else {
                state.selectedRepo = nil
                state.selectedSection = nil
                return
            }
            state.selectedRepo = repo.repository.relativePath(from: workspace.root)
            state.selectedSection = section.rawValue
        }
    }

    /// Points the watcher at whatever discovery found.
    ///
    /// A repository refreshes itself when Grove changes it, so this exists for
    /// everything Grove did *not* do: a commit from the terminal, a branch
    /// switch in another tool, a build touching generated files.
    private func startWatching() {
        guard let workspace else { return }

        if watcher == nil {
            watcher = RepoWatcher { [weak self] changed in
                self?.repositoriesChangedOnDisk(changed)
            }
        }
        watcher?.watch(workspace.repos.map(\.repository))
    }

    private func repositoriesChangedOnDisk(_ changed: Set<RepoID>) {
        guard let workspace else { return }
        for repo in workspace.repos where changed.contains(repo.id) {
            // `refresh()` and not `refreshAndWait()`: these arrive unbidden and
            // must never hold anything up. It also cancels a refresh already in
            // flight, so a burst of events cannot pile up processes.
            repo.refresh()
        }
    }

    func chooseWorkspace() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing your git repositories."
        panel.prompt = "Open Workspace"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        await open(url)
    }

    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await workspace?.refreshAll()
    }

    /// Until workspace persistence lands, a Debug build opens the generated
    /// `Fixtures/` workspace so there is always something real on screen.
    private static var developmentWorkspace: URL? {
        #if DEBUG
        guard let override = ProcessInfo.processInfo.environment["GROVE_WORKSPACE"] else {
            let fixtures = URL(filePath: #filePath)
                .deletingLastPathComponent()  // App
                .deletingLastPathComponent()  // Sources
                .deletingLastPathComponent()  // project root
                .appending(path: "Fixtures")
            return FileManager.default.fileExists(atPath: fixtures.path()) ? fixtures : nil
        }
        return URL(filePath: override)
        #else
        return nil
        #endif
    }
}
