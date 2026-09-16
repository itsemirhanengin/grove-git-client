import Foundation

/// Generates a commit message from what is staged.
///
/// Two providers, tried in order: the `claude` CLI if the user has one, and
/// macOS's on-device model if not. The CLI is first because it is the better
/// writer and needs no cap worth worrying about; the on-device model is the
/// fallback that works on a plane, with no login and nothing leaving the
/// machine.
///
/// Nothing here ever commits. The result lands in the draft field and waits for
/// a person — which is also what makes the untrusted diff going into it
/// acceptable. See ``CommitMessagePrompt``.
nonisolated struct CommitMessageWriter: Sendable {

    let environment: GitEnvironment

    /// Where `claude` lives, or `nil` when the user has none.
    ///
    /// Resolved against the **login** PATH, for exactly the reason git is: a GUI
    /// app inherits launchd's minimal PATH, and `~/.local/bin` is not on it.
    let claudeExecutable: URL?

    init(environment: GitEnvironment) {
        self.environment = environment
        self.claudeExecutable = Self.resolveClaude(environment: environment)
    }

    private static let claudeCandidates = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    private static func resolveClaude(environment: GitEnvironment) -> URL? {
        let fm = FileManager.default
        for candidate in claudeCandidates where fm.isExecutableFile(atPath: candidate) {
            return URL(filePath: candidate)
        }
        for directory in (environment.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/claude"
            if fm.isExecutableFile(atPath: candidate) { return URL(filePath: candidate) }
        }
        return nil
    }

    var hasProvider: Bool { claudeExecutable != nil || OnDeviceWriter.isAvailable }

    // MARK: Writing

    func write(statistics: String, diff: String) async throws -> GeneratedCommitMessage {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommitMessageError.nothingStaged
        }

        if let claudeExecutable {
            do {
                return try await writeWithClaude(
                    executable: claudeExecutable, statistics: statistics, diff: diff)
            } catch {
                // Fall through to the on-device model rather than failing: no
                // network, an expired login and a rate limit all land here, and
                // all three are exactly when the offline one earns its place.
                guard OnDeviceWriter.isAvailable else { throw error }
            }
        }

        guard OnDeviceWriter.isAvailable else { throw CommitMessageError.noProvider }
        return try await OnDeviceWriter.write(statistics: statistics, diff: diff)
    }

    private func writeWithClaude(
        executable: URL, statistics: String, diff: String
    ) async throws
        -> GeneratedCommitMessage
    {
        let (body, truncated) = CommitMessagePrompt.body(
            statistics: statistics, diff: diff, limit: CommitMessagePrompt.remoteDiffLimit)

        var invocation = ProcessInvocation(
            executable: executable,
            arguments: [
                "--print",
                // Cheap and fast. A commit message is not a reasoning problem,
                // and this runs on every commit.
                "--model", "haiku",
                // The load-bearing flag: anything that would ask for permission
                // is denied outright, so the model has no tools and cannot touch
                // the repository it is describing. Naming tools to deny instead
                // would need this list to stay correct forever.
                "--permission-prompts", "none",
                "--append-system-prompt", CommitMessagePrompt.instructions,
                "Write the commit message for the staged change on stdin.",
            ],
            environment: environment.environment
        )
        // On stdin, never in argv: a real diff is far past `ARG_MAX`.
        invocation.stdin = Array(body.utf8)
        invocation.timeout = .seconds(120)
        invocation.outputByteLimit = 1 << 20

        let result = try await ProcessRunner.run(invocation)
        guard result.didSucceed else {
            throw CommitMessageError.providerFailed(
                result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let text = CommitMessagePrompt.clean(result.stdoutText)
        guard !text.isEmpty else { throw CommitMessageError.emptyResponse }
        return GeneratedCommitMessage(text: text, source: .claudeCode, wasTruncated: truncated)
    }
}
