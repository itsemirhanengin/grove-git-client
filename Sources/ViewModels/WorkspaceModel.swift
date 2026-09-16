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
    /// Driven by **selection**, never by repository data. An earlier version
    /// expanded whichever repositories had changes, which meant the sidebar's
    /// row count changed as each async status refresh landed — mid-update, which
    /// trips AppKit's reentrant NSTableView delegate check. Selection only
    /// changes when the user acts, so it can never collide with a refresh.
    ///
    /// It is also the better behaviour: what a section contains is a fixed list
    /// of four navigation items, so how dirty the repository is says nothing
    /// about whether it is worth opening.
    func isExpanded(_ repo: RepoViewModel, selectedRepo: RepoID?) -> Bool {
        repo.expansionOverride ?? (repo.id == selectedRepo)
    }
}
