import Foundation

/// Runs `git` in a repository.
///
/// Everything above this layer states *what* it wants; this type owns the flags
/// that must be on every single invocation so a user's own git config can never
/// change what Grove parses.
nonisolated struct GitRunner: Sendable {

    let environment: GitEnvironment

    init(environment: GitEnvironment) {
        self.environment = environment
    }

    /// Config overrides applied to every command.
    ///
    /// Without these, a user with `diff.noprefix=true`, `diff.external=…` or
    /// `core.quotePath=true` would silently break both diff parsing and
    /// `git apply`, in ways that look like Grove bugs rather than config.
    private static let configOverrides = [
        "-c", "core.quotePath=false",
        "-c", "color.ui=false",
        "-c", "diff.noprefix=false",
        "-c", "diff.mnemonicPrefix=false",
        "-c", "diff.external=",
        "-c", "advice.detachedHead=false",
    ]

    /// Run a git command that only reads.
    ///
    /// `--no-optional-locks` keeps background refreshes from taking
    /// `.git/index.lock` and fighting the user's terminal — which matters a lot
    /// in a client that polls ten repositories.
    func read(
        _ arguments: [String],
        in repository: URL,
        timeout: Duration = .seconds(30),
        outputByteLimit: Int = 64 << 20
    ) async throws -> ProcessResult {
        try await run(
            ["--no-optional-locks"] + arguments,
            in: repository,
            timeout: timeout,
            outputByteLimit: outputByteLimit
        )
    }

    /// Run a git command that mutates the repository.
    ///
    /// Deliberately does *not* pass `--no-optional-locks`: a write needs the
    /// index lock.
    func write(
        _ arguments: [String],
        in repository: URL,
        stdin: [UInt8]? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> ProcessResult {
        try await run(arguments, in: repository, stdin: stdin, timeout: timeout)
    }

    private func run(
        _ arguments: [String],
        in repository: URL,
        stdin: [UInt8]? = nil,
        timeout: Duration = .seconds(30),
        outputByteLimit: Int = 64 << 20
    ) async throws -> ProcessResult {
        var invocation = ProcessInvocation(
            executable: environment.executable,
            arguments: ["--no-pager"] + Self.configOverrides + arguments,
            workingDirectory: repository,
            environment: environment.environment
        )
        invocation.stdin = stdin
        invocation.timeout = timeout
        invocation.outputByteLimit = outputByteLimit
        return try await ProcessRunner.run(invocation)
    }
}

// MARK: - NUL-delimited output

extension ProcessResult {
    /// Splits stdout on NUL.
    ///
    /// Git's `-z` output is the only safe thing to parse: paths can contain
    /// spaces, newlines and bytes that are not valid UTF-8, so records are kept
    /// as raw byte slices and decoded only where they are displayed.
    var nulSeparatedRecords: [ArraySlice<UInt8>] {
        var records: [ArraySlice<UInt8>] = []
        var start = stdout.startIndex
        for index in stdout.indices where stdout[index] == 0 {
            records.append(stdout[start..<index])
            start = stdout.index(after: index)
        }
        if start < stdout.endIndex { records.append(stdout[start...]) }
        return records
    }
}
