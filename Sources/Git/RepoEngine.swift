import Foundation

nonisolated enum GitError: Error, Sendable, Equatable {
    case notARepository
    case authenticationRequired(String)
    case networkUnreachable(String)
    case unbornBranch
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
