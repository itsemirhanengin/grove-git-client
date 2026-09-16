import Foundation
import Observation

/// A folder containing several git repositories.
@Observable
final class WorkspaceModel: Identifiable {

    enum DiscoveryState: Sendable, Equatable {
        case idle
        case scanning
        case ready(repoCount: Int)
        case failed(String)
    }

    let root: URL
    private let runner: GitRunner
    private let limiter: GitTaskLimiter

    var repos: [RepoViewModel] = []
    var discoveryState: DiscoveryState = .idle

    /// Scope and filter from the accessory bar.
    var scope: RepoScope = .all
    var filterText: String = ""

    /// Repositories after the scope and filter are applied.
    ///
    /// A repository that failed to load always stays visible: hiding it would
    /// silently shrink the workspace and leave no way to retry.
    var visibleRepos: [RepoViewModel] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return repos.filter { repo in
            if case .failed = repo.loadState { return true }
            guard scope.matches(repo.status) else { return false }
            guard !query.isEmpty else { return true }
            return repo.name.lowercased().contains(query)
        }
    }

    var isFiltering: Bool {
        scope != .all || !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// How many repositories the current scope and filter are hiding.
    var hiddenRepoCount: Int { repos.count - visibleRepos.count }

    var id: String { root.path() }
    var name: String { root.lastPathComponent }

    /// Total uncommitted changes across the workspace, shown next to its name.
    var totalDirtyCount: Int {
        repos.reduce(0) { $0 + $1.dirtyCount }
    }

    var failedRepoCount: Int {
        repos.count { if case .failed = $0.loadState { true } else { false } }
    }

    init(root: URL, runner: GitRunner, limiter: GitTaskLimiter) {
        self.root = root
        self.runner = runner
        self.limiter = limiter
    }

    // MARK: Discovery

    func discover(config: DiscoveryConfig = DiscoveryConfig()) async {
        discoveryState = .scanning

        let found = await RepoDiscovery.scan(root: root, config: config)

        repos = found.map { repository in
            RepoViewModel(
                repository: repository,
                engine: RepoEngine(repository: repository, runner: runner, limiter: limiter)
            )
        }
        discoveryState = .ready(repoCount: repos.count)

        await refreshAll()
    }

    /// Refreshes every repository concurrently.
    ///
    /// Uses `withTaskGroup` with the error handling *inside* each child, rather
    /// than `async let`: with `async let`, one repository throwing cancels its
    /// siblings, so a single broken repo would blank the whole workspace. Here a
    /// failure is captured into that repo's own `loadState` and the rest carry
    /// on. Overall concurrency is still bounded by `GitTaskLimiter`.
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                group.addTask { await repo.refreshAndWait() }
            }
        }
    }

    /// Whether a repository's section should currently be open.
    ///
    /// The default is a **constant**, never repository data. An earlier version
    /// expanded whichever repositories had changes, which meant the sidebar's
    /// row count changed as each async status refresh landed — mid-update, which
    /// trips AppKit's reentrant NSTableView delegate check. A constant cannot
    /// collide with a refresh.
    ///
    /// It defaults to open rather than closed because a closed section has no
    /// affordance to open it here: section headers are not selectable, so
    /// starting collapsed would leave no way to reach Working Copy or History at
    /// all. What a section contains is a fixed list of four navigation items, so
    /// showing them costs little.
    func isExpanded(_ repo: RepoViewModel) -> Bool {
        repo.expansionOverride ?? true
    }
}
