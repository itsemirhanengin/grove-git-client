import Foundation

nonisolated enum GitError: Error, Sendable, Equatable {
    case notARepository
    case authenticationRequired(String)
    case networkUnreachable(String)
    case unbornBranch
    case emptyCommitMessage
    case nothingToCommit
    case timedOut
    case cancelled
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    /// Classifies a failed invocation from its stderr.
    ///
    /// Matching English text is safe because every invocation runs under
    /// `LC_ALL=C`, which is set for exactly this reason.
    static func classify(_ result: ProcessResult, command: [String]) -> GitError {
        switch result.termination {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default: break
        }

        let stderr = result.stderrText

        if stderr.contains("not a git repository") { return .notARepository }
        if stderr.contains("nothing to commit") || stderr.contains("no changes added to commit") {
            return .nothingToCommit
        }
        if stderr.contains("could not read Username")
            || stderr.contains("Permission denied (publickey)")
            || stderr.contains("Authentication failed")
        {
            return .authenticationRequired(stderr)
        }
        if stderr.contains("Could not resolve host") || stderr.contains("unable to access") {
            return .networkUnreachable(stderr)
        }

        return .commandFailed(
            command: command.joined(separator: " "),
            exitCode: result.exitCode,
            stderr: stderr
        )
    }
}

/// Owns all git work for **one** repository.
///
/// Being an actor gives the property that matters here: operations on a single
/// repository are serialised, so a status refresh cannot interleave with a
/// commit and read a half-written index — while different repositories still run
/// fully in parallel. Concurrency across repositories is bounded separately, by
/// the shared ``GitTaskLimiter``.
actor RepoEngine {

    let repository: Repository

    private let runner: GitRunner
    private let limiter: GitTaskLimiter

    init(repository: Repository, runner: GitRunner, limiter: GitTaskLimiter) {
        self.repository = repository
        self.runner = runner
        self.limiter = limiter
    }

    // MARK: Status

    /// One process, one parse — the hot path for the whole app.
    func status() async throws -> RepoStatus {
        let arguments = [
            "status", "--porcelain=v2", "--branch", "--untracked-files=all",
            "--ignore-submodules=none", "-z",
        ]

        let result = try await limiter.withSlot {
            try await runner.read(arguments, in: repository.root)
        }

        guard result.didSucceed else {
            throw GitError.classify(result, command: arguments)
        }

        var status = StatusParser.parse(result.stdout)
        status.inProgress = inProgressState()
        return status
    }

    // MARK: Branches

    func branches() async throws -> [BranchInfo] {
        let format = [
            "%(refname)", "%(refname:short)", "%(objectname:short)",
            "%(upstream:short)", "%(upstream:track)", "%(committerdate:unix)", "%(HEAD)",
        ].joined(separator: "%00")

        let arguments = [
            "for-each-ref", "--sort=-committerdate", "--format=\(format)",
            "refs/heads", "refs/remotes",
        ]

        let result = try await limiter.withSlot {
            try await runner.read(arguments, in: repository.root)
        }

        guard result.didSucceed else {
            throw GitError.classify(result, command: arguments)
        }

        return BranchInfo.parse(result.stdout)
    }

    // MARK: - Mutations

    /// Stages the given paths.
    ///
    /// Paths go over stdin as raw NUL-separated bytes rather than as argv. That
    /// handles two problems at once: a large selection can exceed `ARG_MAX`, and
    /// a path that is not valid UTF-8 — or contains a space or newline — round
    /// trips exactly as git gave it to us.
    func stage(_ changes: [FileChange]) async throws {
        guard !changes.isEmpty else { return }
        // Staging deliberately does NOT include a rename's original path: after
        // a rename that file no longer exists on disk, and `git add` fails hard
        // with "pathspec did not match any files".
        try await runPathspec(["add"], changes: changes, includeOriginalPaths: false)
    }

    /// Unstages the given paths.
    ///
    /// In a repository with no commits there is no HEAD to restore from, so
    /// `git restore --staged` fails; removing from the index is the equivalent.
    func unstage(_ changes: [FileChange]) async throws {
        guard !changes.isEmpty else { return }

        let hasCommits = await headExists()
        let arguments =
            hasCommits
            ? ["restore", "--staged"]
            : ["rm", "--cached", "-r"]
        try await runPathspec(arguments, changes: changes)
    }

    /// What a discard actually did, so the UI can tell the user where their work
    /// went rather than just claiming success.
    struct DiscardOutcome: Sendable, Equatable {
        /// Ref holding a full snapshot of the worktree and index from just
        /// before the discard. `git stash apply <ref>` brings it all back.
        var backupRef: String?
        /// Untracked files moved to the Trash, recoverable from Finder.
        var trashedPaths: [String] = []
        /// Tracked paths restored from the index or HEAD.
        var restoredPaths: [String] = []
        /// Untracked files that could not be trashed, with the reason.
        var failures: [(path: String, reason: String)] = []

        static func == (a: DiscardOutcome, b: DiscardOutcome) -> Bool {
            a.backupRef == b.backupRef && a.trashedPaths == b.trashedPaths
                && a.restoredPaths == b.restoredPaths
                && a.failures.map(\.path) == b.failures.map(\.path)
        }
    }

    /// Throws away local changes — the one operation that can lose work, so it
    /// is also the one with the most machinery behind it.
    ///
    /// Two separate safety nets, because the two kinds of change need different
    /// ones:
    ///
    /// - **Tracked files** are captured first by `git stash create`, which builds
    ///   a commit holding the full worktree and index *without touching either*,
    ///   then anchored under `refs/grove/backup/` so garbage collection cannot
    ///   reclaim it. Recovery is `git stash apply <ref>`.
    /// - **Untracked files** go to the **Trash**, never through `git clean`. Git
    ///   has no record of them, so a backup ref cannot help; the Trash is the
    ///   only thing that makes the action reversible.
    func discard(_ changes: [FileChange]) async throws -> DiscardOutcome {
        guard !changes.isEmpty else { return DiscardOutcome() }

        var outcome = DiscardOutcome()
        outcome.backupRef = try? await createBackup(reason: "discard")

        let untracked = changes.filter { $0.kind == .untracked }
        let tracked = changes.filter { $0.kind != .untracked }

        for change in untracked {
            let url = repository.root.appending(
                path: change.displayPath, directoryHint: .notDirectory)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                outcome.trashedPaths.append(change.displayPath)
            } catch {
                outcome.failures.append((change.displayPath, error.localizedDescription))
            }
        }

        if !tracked.isEmpty {
            let hasCommits = await headExists()
            // `--staged --worktree` resets both sides. Without HEAD there is
            // nothing to restore a tracked file from, so only the worktree is
            // touched — which for an unborn repo is all that exists anyway.
            let arguments =
                hasCommits
                ? ["restore", "--staged", "--worktree", "--source=HEAD"]
                : ["restore", "--worktree"]
            try await runPathspec(arguments, changes: tracked)
            outcome.restoredPaths = tracked.map(\.displayPath)
        }

        return outcome
    }

    /// Creates a recoverable snapshot of the current worktree and index.
    ///
    /// `git stash create` is the key: unlike `git stash push` it produces a
    /// dangling commit and leaves the working tree completely untouched, so it
    /// can run before *any* destructive operation without side effects. Anchoring
    /// it under `refs/grove/backup/` makes it GC-proof while keeping it out of
    /// `git branch` and `git stash list`.
    ///
    /// Returns `nil` when there was nothing to snapshot.
    @discardableResult
    func createBackup(reason: String) async throws -> String? {
        let created = try await limiter.withSlot {
            try await runner.write(["stash", "create"], in: repository.root)
        }
        guard created.didSucceed else { return nil }

        let sha = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty else { return nil }  // clean tree, nothing to save

        let ref = "refs/grove/backup/\(Int(Date().timeIntervalSince1970))"
        let anchored = try await limiter.withSlot {
            try await runner.write(
                ["update-ref", ref, sha, "-m", "grove: before \(reason)"],
                in: repository.root
            )
        }
        return anchored.didSucceed ? ref : nil
    }

    /// Commits whatever is staged.
    ///
    /// The message goes over stdin — a long body would otherwise risk `ARG_MAX`,
    /// and `-m` mangles trailing whitespace. Hooks are never bypassed: there is
    /// no `--no-verify` here, and there will not be one unless the user asks for
    /// it explicitly and visibly.
    func commit(message: String, amend: Bool = false) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.emptyCommitMessage }

        let arguments =
            ["commit", "-F", "-", "--cleanup=whitespace"] + (amend ? ["--amend"] : [])
        let messageBytes = Array(trimmed.utf8)

        let result = try await limiter.withSlot {
            try await runner.write(
                arguments, in: repository.root, stdin: messageBytes, timeout: .seconds(120))
        }

        guard result.didSucceed else {
            throw GitError.classify(result, command: arguments)
        }
    }

    // MARK: Helpers

    /// Runs a git command whose paths are fed as NUL-separated bytes on stdin.
    /// - Parameter includeOriginalPaths: whether to also send the pre-rename
    ///   path. Required when *undoing* something (unstage, discard), because a
    ///   rename occupies two index entries and clearing only the new one leaves
    ///   a phantom staged deletion of the original. Must be off for `git add`,
    ///   where the old path no longer exists on disk.
    private func runPathspec(
        _ arguments: [String], changes: [FileChange], includeOriginalPaths: Bool = true
    ) async throws {
        let stdin: [UInt8] = changes.reduce(into: []) { bytes, change in
            bytes.append(contentsOf: change.pathBytes)
            bytes.append(0)
            if includeOriginalPaths, let original = change.originalPathBytes {
                bytes.append(contentsOf: original)
                bytes.append(0)
            }
        }

        let full = arguments + ["--pathspec-from-file=-", "--pathspec-file-nul"]
        let result = try await limiter.withSlot {
            try await runner.write(full, in: repository.root, stdin: stdin)
        }

        guard result.didSucceed else {
            throw GitError.classify(result, command: full)
        }
    }

    /// Whether HEAD resolves. False in a repository with no commits, which needs
    /// a different code path almost everywhere.
    private func headExists() async -> Bool {
        let result = try? await limiter.withSlot {
            try await runner.read(["rev-parse", "--verify", "HEAD"], in: repository.root)
        }
        return result?.didSucceed ?? false
    }

    // MARK: In-progress operations

    /// Detects a merge, rebase, cherry-pick or revert in progress.
    ///
    /// Costs **no git process**: these are marker files, and `gitPath` was
    /// already resolved during discovery — which is why it is stored rather than
    /// assumed to be `root/.git`. For a linked worktree those markers live under
    /// `…/worktrees/<name>/`, so deriving the path here would look in the wrong
    /// place and silently report "no merge in progress" during a conflict.
    private func inProgressState() -> InProgressOperation? {
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: repository.gitPath.appending(path: name).path())
        }

        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        if exists("BISECT_LOG") { return .bisect }
        return nil
    }
}
