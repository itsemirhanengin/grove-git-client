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
    private let messageWriter: CommitMessageWriter?

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

    init(
        repository: Repository, engine: RepoEngine, messageWriter: CommitMessageWriter? = nil
    ) {
        self.repository = repository
        self.engine = engine
        self.messageWriter = messageWriter
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
        case .detachedHead: return "HEAD is detached — switch to a branch first"
        case .noUpstream: return "This branch has never been pushed"
        case .binaryConflict:
            return "This file is not text — take one side of it whole"
        case .notFastForward:
            return "The branch has moved on both sides — merge or rebase to reconcile"
        case .localChangesWouldBeOverwritten:
            return "Uncommitted changes are in the way — commit or discard them first"
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
            self.reconcileSelection(with: status)
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

    /// Keeps ``selectedChange`` pointing at the **current** version of its file.
    ///
    /// It holds a snapshot, and a snapshot goes stale the moment anything is
    /// staged, resolved or discarded. A conflicted file that has just been
    /// resolved still reports `isConflicted` forever, which leaves the conflict
    /// resolver on screen over a file that no longer has one.
    private func reconcileSelection(with status: RepoStatus) {
        guard let selection = selectedChange else { return }

        guard
            let fresh = status.changes.first(where: { $0.pathBytes == selection.change.pathBytes })
        else {
            // The file is clean now — committed, discarded, or resolved into
            // exactly what HEAD already had.
            selectedChange = nil
            return
        }

        // Keep the side that was being looked at where it still exists, and
        // fall to the other one where it does not.
        var staged = selection.staged
        if staged && !fresh.isStaged { staged = false }
        if !staged && !fresh.isUnstaged { staged = true }

        let updated = SelectedChange(change: fresh, staged: staged)
        if updated != selection { selectedChange = updated }
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

    // MARK: Remotes and branches

    /// Whether pushing would have to publish the branch rather than update it.
    var needsUpstream: Bool { status.upstream == nil && !status.isUnborn }

    var canPush: Bool { !isBusy && (status.ahead > 0 || needsUpstream) }
    var canPull: Bool { !isBusy && status.behind > 0 }

    func fetch() {
        perform { try await $0.fetch() }
    }

    /// Defaults to fast-forward only. When that is refused the error says so,
    /// and the UI offers merge or rebase as a separate, named choice — rather
    /// than quietly producing a merge commit nobody asked for.
    func pull(_ strategy: RepoEngine.PullStrategy = .fastForwardOnly) {
        perform { try await $0.pull(strategy) }
    }

    func push() {
        let publish = needsUpstream
        perform { try await $0.push(setUpstream: publish) }
    }

    func switchTo(_ branch: BranchInfo) {
        perform { engine in
            try await engine.switchTo(branch)
        } onSuccess: { [weak self] in
            // The branch list's ahead/behind and current marker are all stale
            // the moment HEAD moves.
            self?.branches = []
        }
    }

    func createBranch(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { engine in
            try await engine.createBranch(named: trimmed)
        } onSuccess: { [weak self] in
            self?.branches = []
        }
    }

    /// The result of the last merge, so the UI can say what happened instead of
    /// leaving the user to infer it from the file list.
    struct MergeReceipt: Identifiable {
        let id = UUID()
        let branch: String
        let outcome: RepoEngine.MergeOutcome
    }

    var lastMerge: MergeReceipt?

    func merge(_ branch: BranchInfo) {
        currentOperation = Task { [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            do {
                let outcome = try await self.engine.merge(branch)
                self.lastMerge = MergeReceipt(branch: branch.name, outcome: outcome)
                self.branches = []
            } catch let error as GitError {
                self.operationError = error
            } catch {
                self.operationError = .commandFailed(
                    command: "merge", exitCode: -1, stderr: "\(error)")
            }
            await self.performRefresh()
        }
    }

    func abortInProgress() {
        guard let operation = status.inProgress else { return }
        perform { try await $0.abort(operation) }
    }

    /// Reloads the branch list, which `loadBranchesIfNeeded` will not do once it
    /// has one.
    func reloadBranches() async {
        branches = (try? await engine.branches()) ?? []
    }

    // MARK: Commit messages

    private(set) var isGeneratingMessage = false

    /// The last generated message, so the composer can say where it came from
    /// and whether the diff had to be cut short.
    var lastGeneratedMessage: GeneratedCommitMessage?

    /// Whether there is anything to generate *with*.
    var canGenerateMessage: Bool {
        !isBusy && !isGeneratingMessage && !status.staged.isEmpty
            && (messageWriter?.hasProvider ?? false)
    }

    /// Writes a commit message from what is staged, into the draft field.
    ///
    /// Into the **draft**, never into a commit: a person reads every generated
    /// message before it becomes one, which is also what makes feeding an
    /// untrusted diff to a model acceptable. See ``CommitMessagePrompt``.
    func generateCommitMessage() {
        guard let messageWriter, !isGeneratingMessage else { return }

        currentOperation = Task { [weak self] in
            guard let self else { return }
            self.isGeneratingMessage = true
            defer { self.isGeneratingMessage = false }

            do {
                let summary = try await self.engine.stagedSummary()
                let generated = try await messageWriter.write(
                    statistics: summary.statistics, diff: summary.diff)
                self.draftMessage = generated.text
                self.lastGeneratedMessage = generated
            } catch let error as CommitMessageError {
                self.operationError = .commandFailed(
                    command: "generate message", exitCode: -1,
                    stderr: Self.message(for: error))
            } catch let error as GitError {
                self.operationError = error
            } catch {
                self.operationError = .commandFailed(
                    command: "generate message", exitCode: -1, stderr: "\(error)")
            }
        }
    }

    nonisolated static func message(for error: CommitMessageError) -> String {
        switch error {
        case .nothingStaged: "Stage something first"
        case .noProvider:
            OnDeviceWriter.unavailableReason
                ?? "No `claude` command was found, and the on-device model is unavailable"
        case .emptyResponse: "The model returned nothing"
        case .providerFailed(let detail):
            detail.isEmpty ? "The model could not be reached" : detail
        }
    }

    // MARK: History

    /// How many commits one page holds.
    ///
    /// A repository can have a hundred thousand of them. The list pages instead
    /// of asking git for all of it, because the graph layout and the row views
    /// are both linear in what has been loaded.
    static let historyPageSize = 200

    private(set) var commits: [CommitInfo] = []
    private(set) var graphRows: [CommitGraphRow] = []
    private(set) var isLoadingHistory = false

    /// False once a page comes back short, which is the only reliable end of
    /// history — `git log` will happily return nothing past the last commit.
    private(set) var hasMoreHistory = true

    /// The commit whose detail is showing, and the file within it.
    var selectedCommit: CommitInfo?
    var selectedCommitChange: FileChange?
    private(set) var selectedCommitMessage = ""
    private(set) var selectedCommitChanges: [FileChange] = []

    func loadHistory() async {
        guard commits.isEmpty, !isLoadingHistory else { return }
        await fetchHistoryPage(reset: true)
    }

    /// Reloads from the top. Called when HEAD moves under the list.
    func reloadHistory() async {
        await fetchHistoryPage(reset: true)
    }

    func loadMoreHistory() async {
        guard hasMoreHistory, !isLoadingHistory else { return }
        await fetchHistoryPage(reset: false)
    }

    private func fetchHistoryPage(reset: Bool) async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let skip = reset ? 0 : commits.count
        guard let page = try? await engine.log(limit: Self.historyPageSize, skip: skip) else {
            if reset { commits = []; graphRows = [] }
            hasMoreHistory = false
            return
        }

        if reset { commits = page } else { commits += page }
        hasMoreHistory = page.count == Self.historyPageSize

        // Laid out over everything loaded, not just the new page: a branch that
        // opened on page one and closes on page three is one shape, and laying
        // out a page in isolation would draw it as two.
        graphRows = CommitGraph.layout(
            commits.map { CommitGraphNode(id: $0.oid, parents: $0.parents) })
    }

    func selectCommit(_ commit: CommitInfo) async {
        selectedCommit = commit
        selectedCommitChange = nil
        selectedCommitMessage = ""
        selectedCommitChanges = []

        async let message = try? engine.commitMessage(commit.oid)
        async let changes = try? engine.commitChanges(commit.oid)

        let (loadedMessage, loadedChanges) = await (message, changes)
        // The user may have moved on while git was working.
        guard selectedCommit?.oid == commit.oid else { return }

        selectedCommitMessage = loadedMessage ?? ""
        selectedCommitChanges = loadedChanges ?? []
        selectedCommitChange = selectedCommitChanges.first
    }

    func commitDiff(
        for change: FileChange, in oid: String, contextLines: Int = 3
    ) async throws
        -> String
    {
        try await engine.commitDiff(for: change, in: oid, contextLines: contextLines)
    }

    // MARK: Conflicts

    /// Whether the repository is mid-merge with nothing left to resolve, so the
    /// only thing missing is the commit.
    var canContinueMerge: Bool {
        !isBusy && status.inProgress != nil && !status.hasConflicts && !status.staged.isEmpty
    }

    func conflictedContents(for change: FileChange) async throws -> String {
        try await engine.conflictedContents(for: change)
    }

    /// Writes back what the resolver produced. The page decides what the file
    /// should say; this is the only thing that puts it on disk.
    func applyResolution(_ contents: String, to change: FileChange) {
        perform { try await $0.applyResolution(contents, to: change) }
    }

    func resolve(_ change: FileChange, using side: RepoEngine.ConflictSide) {
        perform { try await $0.resolve(change, using: side) }
    }

    /// Marks a conflict settled without changing the file — the user edited it
    /// elsewhere, or is happy with the merge git already produced.
    func markResolved(_ change: FileChange) {
        stage([change])
    }

    func continueMerge() {
        perform { try await $0.continueMerge() }
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
