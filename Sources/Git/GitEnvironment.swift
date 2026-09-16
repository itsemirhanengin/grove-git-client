import Foundation

/// Where the `git` binary is and what environment it runs in.
///
/// Resolved once at launch and then treated as immutable. Two things here are
/// load-bearing and easy to get wrong:
///
/// 1. **PATH.** A GUI app inherits launchd's minimal PATH, which does not
///    include Homebrew. Credential helpers live out there (`gh
///    auth git-credential`, `git-credential-osxkeychain`, `git-lfs`), so without
///    the real login PATH, pushing to a private remote fails in a way that looks
///    like a Grove bug. It is recovered by asking a login shell.
/// 2. **`GIT_TERMINAL_PROMPT=0`.** Without it, a git that wants a password blocks
///    on a terminal read that will never be answered, and Grove just hangs.
nonisolated struct GitEnvironment: Sendable {

    /// The `git` to run.
    let executable: URL

    /// Environment applied to every invocation.
    let environment: [String: String]

    /// Where the login PATH came from, for the diagnostics panel.
    let pathSource: PathSource

    nonisolated enum PathSource: Sendable, Equatable {
        case loginShell
        case inherited
        case fallback
    }

    /// Directories checked for `git`, in order, before falling back to PATH.
    ///
    /// `/usr/bin/git` is deliberately last: it is the Xcode shim, and if the
    /// active developer directory is wrong it pops a "install command line
    /// developer tools" dialog instead of running.
    private static let gitCandidates = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git",
    ]

    private static let fallbackPath =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    // MARK: Resolution

    static func resolve() async -> GitEnvironment {
        let (path, source) = await resolveLoginPath()
        let executable = resolveGitExecutable(searchPath: path)
        return GitEnvironment(
            executable: executable,
            environment: makeEnvironment(path: path),
            pathSource: source
        )
    }

    /// Asks a login shell for the user's real PATH.
    private static func resolveLoginPath() async -> (String, PathSource) {
        var invocation = ProcessInvocation(
            executable: URL(filePath: "/bin/zsh"),
            arguments: ["-lc", "printf %s \"$PATH\""]
        )
        invocation.timeout = .seconds(3)
        invocation.outputByteLimit = 64 << 10

        if let result = try? await ProcessRunner.run(invocation), result.didSucceed {
            let path = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return (path, .loginShell) }
        }

        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            return (inherited, .inherited)
        }
        return (fallbackPath, .fallback)
    }

    private static func resolveGitExecutable(searchPath: String) -> URL {
        let fm = FileManager.default
        for candidate in gitCandidates where fm.isExecutableFile(atPath: candidate) {
            return URL(filePath: candidate)
        }
        for directory in searchPath.split(separator: ":") {
            let candidate = "\(directory)/git"
            if fm.isExecutableFile(atPath: candidate) { return URL(filePath: candidate) }
        }
        return URL(filePath: "/usr/bin/git")
    }

    private static func makeEnvironment(path: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        env["PATH"] = path
        env["HOME"] = NSHomeDirectory()

        // Never block on input nobody will type.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"

        // Deterministic, English stderr so error classification can match on it.
        // Safe because everything parsed is `-z` or raw bytes, never localised.
        env["LC_ALL"] = "C"
        env["LANG"] = "C"

        // NOT set: GIT_CONFIG_NOSYSTEM. The user's system and global config,
        // credential helpers and hooks must all apply — that is the entire
        // reason Grove shells out to git instead of linking libgit2.
        env.removeValue(forKey: "GIT_CONFIG_NOSYSTEM")
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        env.removeValue(forKey: "GIT_INDEX_FILE")

        return env
    }
}
