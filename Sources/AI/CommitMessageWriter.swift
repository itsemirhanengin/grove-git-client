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

        do {
            let text = try await ask(executable: executable, body: body, arguments: Self.arguments)
            return GeneratedCommitMessage(text: text, source: .claudeCode, wasTruncated: truncated)
        } catch CommitMessageError.providerFailed(let detail) where Self.isUnknownFlag(detail) {
            // An older `claude` than the flags above were written for. The
            // portable set costs a few seconds and needs
            // `CommitMessagePrompt.clean` to take the attribution off the end,
            // which is exactly why that stripping exists.
            let text = try await ask(
                executable: executable, body: body, arguments: Self.portableArguments)
            return GeneratedCommitMessage(text: text, source: .claudeCode, wasTruncated: truncated)
        }
    }

    /// Runs `claude` once and returns the cleaned message.
    private func ask(executable: URL, body: String, arguments: [String]) async throws -> String {
        var invocation = ProcessInvocation(
            executable: executable,
            arguments: arguments,
            environment: Self.processEnvironment(from: environment)
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
        return text
    }

    // MARK: How `claude` is asked

    private static let request = "Write the commit message for the staged change on stdin."

    /// Every flag here is load-bearing, and most of them are why this takes
    /// about two seconds rather than about twenty.
    ///
    /// - `--model haiku` — a commit message is not a reasoning problem, and this
    ///   runs on every commit.
    /// - `--system-prompt` **replaces** the CLI's own system prompt instead of
    ///   appending to it. That is what keeps `Co-Authored-By: Claude` out of the
    ///   draft: the default prompt is where that trailer is asked for, and
    ///   asking for the opposite on top of it does not reliably win. It also
    ///   takes the prompt from roughly 36,000 input tokens to 12,000 — after
    ///   which almost all of what is sent is the diff.
    /// - `--tools ""` leaves the model with no tools **at all**, so it cannot
    ///   touch the repository it is describing. `--permission-prompts none` stays
    ///   as the second lock: anything that would ask is denied outright.
    /// - `--safe-mode` ignores the user's `CLAUDE.md`, hooks, plugins, custom
    ///   commands and MCP servers. Grove is asking one question, not running
    ///   someone's agent setup — and a stray `CLAUDE.md` saying "sign your
    ///   commits" would otherwise end up in this draft.
    /// - `--no-session-persistence` keeps a one-shot question out of the
    ///   resumable-session history on disk.
    private static let arguments = [
        "--print",
        "--model", "haiku",
        "--safe-mode",
        "--tools", "",
        "--permission-prompts", "none",
        "--no-session-persistence",
        "--system-prompt", CommitMessagePrompt.instructions,
        request,
    ]

    /// The set that has worked for as long as `claude --print` has existed, for
    /// a CLI too old to know the flags above.
    private static let portableArguments = [
        "--print",
        "--model", "haiku",
        "--permission-prompts", "none",
        "--append-system-prompt", CommitMessagePrompt.instructions,
        request,
    ]

    /// `error: unknown option '--safe-mode'` — the CLI rejected a flag before it
    /// ever reached the model, which is the one failure worth retrying
    /// differently rather than falling through to the on-device model.
    private static func isUnknownFlag(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("unknown option") || lowered.contains("unknown argument")
    }

    /// git's environment, plus the one variable that decides most of how long
    /// this takes.
    ///
    /// `MAX_THINKING_TOKENS=0` turns extended thinking off. Measured on a 38 KB
    /// staged diff: with thinking on, the model spent 500–1,400 tokens reasoning
    /// before writing a word and the call took 8–17 seconds — 40 on a bad run.
    /// With it off, the same diff comes back in 1–3 seconds, and the messages are
    /// no worse: the diff is already in front of the model, and summarising it is
    /// not a problem that rewards deliberation.
    private static func processEnvironment(from git: GitEnvironment) -> [String: String] {
        var environment = git.environment
        environment["MAX_THINKING_TOKENS"] = "0"
        return environment
    }
}
