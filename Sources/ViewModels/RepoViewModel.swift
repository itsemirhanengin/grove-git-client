import Foundation
import Observation

/// Where a repository is in its load cycle.
///
/// `failed` is a first-class state rather than an alert: one repository that
/// cannot be read must not take the workspace down with it, and a modal for a
/// background refresh failure would be intolerable across ten repositories.
enum RepoLoadState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case failed(GitError)
    /// The folder is gone from disk — distinct from an error, and its fix is
    /// "remove from workspace", not "retry".
    case missing
}

/// One repository's live state.
///
/// `@Observable` rather than `ObservableObject` for one decisive reason: change
/// tracking is per-property, so updating `repos[3].status` invalidates only the
/// view that actually read it. With `ObservableObject`, a single
/// `objectWillChange` would re-render every repository section in the sidebar —
/// which is exactly the "ten repos update independently" requirement.
@Observable
final class RepoViewModel: Identifiable {

    let repository: Repository
    private let engine: RepoEngine

    var status: RepoStatus = .empty
    var branches: [BranchInfo] = []
    var loadState: RepoLoadState = .idle

    /// The user's explicit expand/collapse choice, or `nil` while it is still
    /// whatever the workspace decided by default.
    ///
    /// Expansion is **derived** rather than assigned in a pass after discovery.
    /// Writing it afterwards changes the sidebar's row count while AppKit is
    /// still applying the previous update, which trips its reentrant
    /// NSTableView delegate check — a warning today, an assert in a future
    /// macOS. Deriving it means there is no second mutation to be reentrant.
    var expansionOverride: Bool?

    /// Draft commit message, kept per repository so switching between them does
    /// not lose typing.
    var draftMessage: String = ""

    private var refreshTask: Task<Void, Never>?

    var id: RepoID { repository.id }
    var name: String { repository.name }

    init(repository: Repository, engine: RepoEngine) {
        self.repository = repository
        self.engine = engine
    }

    // MARK: Derived display state

    var branchLabel: String {
        if let branch = status.branch { return branch }
        if let oid = status.headOID { return String(oid.prefix(7)) }
        return "no commits"
    }

    var isDetached: Bool { status.branch == nil && status.headOID != nil }

    var dirtyCount: Int { status.dirtyCount }

    // MARK: Display caps

    /// Most rows one repository may contribute to a list.
    ///
    /// An accidental `node_modules` commit, or a branch switch that rewrites a
    /// generated directory, can leave tens of thousands of changed files. Laying
    /// all of them out would freeze the window for something nobody wants to
    /// read. The full count stays visible in the badge, and an overflow row
    /// offers the rest explicitly.
    static let displayRowCap = 300

    var displayedConflicted: [FileChange] { Array(status.conflicted.prefix(Self.displayRowCap)) }
    var displayedStaged: [FileChange] { Array(status.staged.prefix(Self.displayRowCap)) }

    var displayedUnstaged: [FileChange] {
        Array((status.unstaged + status.untracked).prefix(Self.displayRowCap))
    }

    /// Whether any group was truncated for display.
    var hasMoreThanDisplayed: Bool {
        status.conflicted.count > Self.displayRowCap
            || status.staged.count > Self.displayRowCap
            || (status.unstaged.count + status.untracked.count) > Self.displayRowCap
    }

    /// How many rows the cap is holding back, across all groups.
    var hiddenRowCount: Int {
        let unstagedTotal = status.unstaged.count + status.untracked.count
        return max(0, status.conflicted.count - Self.displayRowCap)
            + max(0, status.staged.count - Self.displayRowCap)
            + max(0, unstagedTotal - Self.displayRowCap)
    }

    var errorMessage: String? {
        guard case .failed(let error) = loadState else { return nil }
        switch error {
        case .notARepository: return "Not a git repository"
        case .authenticationRequired: return "Authentication required"
        case .networkUnreachable: return "Network unreachable"
        case .unbornBranch: return "No commits yet"
        case .timedOut: return "git timed out"
        case .cancelled: return "Cancelled"
        case .commandFailed(_, _, let stderr):
            return stderr.split(separator: "\n").first.map(String.init) ?? "git failed"
        }
    }

    // MARK: Refresh

    /// Replaces any in-flight refresh.
    ///
    /// Cancelling the previous task propagates all the way down to
    /// `ProcessRunner`, which SIGTERMs the running git — so a repository being
    /// hammered by a build cannot pile up refreshes.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
    }

    func refreshAndWait() async {
        refreshTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        guard FileManager.default.fileExists(atPath: repository.root.path()) else {
            loadState = .missing
            return
        }

        if loadState != .ready { loadState = .loading }

        do {
            let status = try await engine.status()
            guard !Task.isCancelled else { return }
            self.status = status
            self.loadState = .ready
        } catch let error as GitError {
            guard !Task.isCancelled, error != .cancelled else { return }
            self.loadState = .failed(error)
        } catch {
            guard !Task.isCancelled else { return }
            self.loadState = .failed(
                .commandFailed(command: "status", exitCode: -1, stderr: "\(error)")
            )
        }
    }

    /// Branches are fetched lazily — the sidebar only needs the current branch
    /// name, which `status` already provides for free.
    func loadBranchesIfNeeded() async {
        guard branches.isEmpty else { return }
        branches = (try? await engine.branches()) ?? []
    }
}
