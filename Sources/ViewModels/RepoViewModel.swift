import DiffCore
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

    /// The change whose diff the detail column is showing.
    ///
    /// Held on the repository rather than threaded through the column views as
    /// a binding: the detail column, the change list and the diff pane all need
    /// it, and `@Observable` invalidates only the views that actually read it.
    var selectedChange: SelectedChange?

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
        return Self.message(for: error)
    }

    /// One place that turns a `GitError` into something a person can act on,
    /// used by both the per-repository failure state and the alert a failed
    /// mutation raises.
    nonisolated static func message(for error: GitError) -> String {
        switch error {
        case .notARepository: return "Not a git repository"
        case .authenticationRequired: return "Authentication required"
        case .networkUnreachable: return "Network unreachable"
        case .unbornBranch: return "No commits yet"
        case .emptyCommitMessage: return "Write a commit message first"
        case .nothingToCommit: return "Nothing staged to commit"
        case .timedOut: return "git timed out"
        case .cancelled: return "Cancelled"
        case .patchDoesNotApply:
            return "The file changed since this diff — reload it and try again"
        case .cannotSplitPatch(let reason):
            switch reason {
            case .nothingSelected: return "Nothing selected"
            case .binaryFile: return "A binary file has no lines to stage"
            case .combinedDiff: return "Resolve the conflict before staging lines"
            case .noNewlineNotSplittable:
                return "This chunk ends without a newline — take all of it at once"
            case .wholeFileOnly: return "This file is added or removed as a whole"
            }
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

    /// Awaits whatever mutation is in flight. Used by tests.
    func waitForOperation() async {
        await currentOperation?.value
    }

    /// Branches are fetched lazily — the sidebar only needs the current branch
    /// name, which `status` already provides for free.
    func loadBranchesIfNeeded() async {
        guard branches.isEmpty else { return }
        branches = (try? await engine.branches()) ?? []
    }

    // MARK: - Mutations

    /// A discard waiting for the user to confirm it.
    ///
    /// Held as state rather than run immediately, because a confirmation sheet
    /// that just says "Are you sure?" is worthless — the user needs to see the
    /// exact files that are about to lose their changes.
    struct PendingDiscard: Identifiable {
        let id = UUID()
        let changes: [FileChange]

        /// Set when only part of one file goes, rather than all of it — a
        /// chunk or a hand-picked set of lines from the diff on screen.
        var partial: Partial?

        /// The diff the selection was made in travels with it. A selection is
        /// line numbers, and line numbers mean something only against the diff
        /// they came from.
        struct Partial {
            var diff: String
            var selection: PatchSelection
        }

        var trackedCount: Int { changes.count { $0.kind != .untracked } }
        var untrackedCount: Int { changes.count { $0.kind == .untracked } }

        var lineCount: Int { partial?.selection.count ?? 0 }
    }

    /// The result of the last discard, so the UI can say where the work went
    /// instead of silently succeeding.
    struct DiscardReceipt: Identifiable {
        let id = UUID()
        let outcome: RepoEngine.DiscardOutcome
    }

    /// The mutation currently running, exposed so tests can await the work a
    /// button kicks off instead of polling for it.
    private(set) var currentOperation: Task<Void, Never>?

    var pendingDiscard: PendingDiscard?
    var lastDiscard: DiscardReceipt?
    var operationError: GitError?
    var isBusy = false

    var canCommit: Bool {
        !isBusy
            && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !status.staged.isEmpty
    }

    func stage(_ changes: [FileChange]) {
        perform { try await $0.stage(changes) }
    }

    func unstage(_ changes: [FileChange]) {
        perform { try await $0.unstage(changes) }
    }

    func stageAll() {
        stage(status.unstaged + status.untracked + status.conflicted)
    }

    func unstageAll() {
        unstage(status.staged)
    }

    /// Asks before discarding. Always — this is the only operation that can
    /// destroy work the user has not committed.
    func requestDiscard(_ changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        pendingDiscard = PendingDiscard(changes: changes)
    }

    func confirmPendingDiscard() {
        guard let pending = pendingDiscard else { return }
        pendingDiscard = nil

        currentOperation = Task { [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            do {
                let outcome = try await self.runDiscard(pending)
                self.lastDiscard = DiscardReceipt(outcome: outcome)
            } catch let error as GitError {
                self.operationError = error
            } catch {
                self.operationError = .commandFailed(
                    command: "discard", exitCode: -1, stderr: "\(error)")
            }
            await self.performRefresh()
        }
    }

    /// The two shapes a discard comes in, behind one confirmation and one
    /// receipt — the user should not have to learn that "discard lines" is a
    /// different mechanism from "discard file".
    private func runDiscard(_ pending: PendingDiscard) async throws -> RepoEngine.DiscardOutcome {
        guard let partial = pending.partial else {
            return try await engine.discard(pending.changes)
        }

        let backup = try await engine.applyPartial(
            diff: partial.diff, selection: partial.selection, operation: .discard)

        return RepoEngine.DiscardOutcome(
            backupRef: backup,
            restoredPaths: pending.changes.map(\.displayPath)
        )
    }

    func cancelPendingDiscard() {
        pendingDiscard = nil
    }

    // MARK: Partial staging

    /// Stages, unstages or discards part of one file — a chunk, or picked lines.
    ///
    /// A discard goes through the same confirmation sheet as a whole-file one.
    /// There is no threshold below which destroying uncommitted work stops
    /// needing to be asked about.
    func applyPartial(
        to change: FileChange,
        diff: String,
        selection: PatchSelection,
        operation: RepoEngine.PartialOperation
    ) {
        guard !selection.isEmpty else { return }

        guard !operation.isDestructive else {
            pendingDiscard = PendingDiscard(
                changes: [change],
                partial: .init(diff: diff, selection: selection)
            )
            return
        }

        perform { engine in
            try await engine.applyPartial(
                diff: diff, selection: selection, operation: operation)
        }
    }

    func commit(amend: Bool = false) {
        let message = draftMessage
        perform { engine in
            try await engine.commit(message: message, amend: amend)
        } onSuccess: { [weak self] in
            // Only clear the draft once git has actually accepted it. Clearing
            // optimistically would lose the message whenever a commit hook
            // rejects the commit.
            self?.draftMessage = ""
        }
    }

    /// Runs a mutation, then refreshes. Errors land in `operationError` rather
    /// than an alert, so a failure in one repository never interrupts the others.
    private func perform(
        _ body: @escaping @Sendable (RepoEngine) async throws -> Void,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        currentOperation = Task { [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            do {
                try await body(self.engine)
                onSuccess?()
            } catch let error as GitError {
                self.operationError = error
            } catch {
                self.operationError = .commandFailed(
                    command: "operation", exitCode: -1, stderr: "\(error)")
            }
            await self.performRefresh()
        }
    }

    // MARK: Diff

    /// One file's diff, as git's own output. See ``RepoEngine/diff(for:staged:contextLines:)``.
    func diff(for change: FileChange, staged: Bool, contextLines: Int = 3) async throws -> String {
        try await engine.diff(for: change, staged: staged, contextLines: contextLines)
    }
}

/// A file plus which side of it is being shown.
///
/// A file can be staged *and* modified again, and those are two different
/// diffs, so the side is part of the selection rather than a display toggle.
nonisolated struct SelectedChange: Sendable, Equatable {
    var change: FileChange
    var staged: Bool
}
