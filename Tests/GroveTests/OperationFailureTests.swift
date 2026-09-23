import Foundation
import Testing

@testable import Grove

/// What a failure looks like once it reaches a window: no terminal escapes, a
/// short summary, and hooks named as hooks.
@Suite("Operation failures")
struct OperationFailureTests {

    // MARK: Terminal escapes

    @Test(
        "removes colours, cursor movement and hyperlinks",
        arguments: [
            ("\u{1B}[38;2;52;52;52m─\u{1B}[m", "─"),
            ("\u{1B}[1mpre-commit\u{1B}[0m", "pre-commit"),
            ("\u{1B}[2K\u{1B}[1Gdone", "done"),
            ("\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07}", "link"),
            ("\u{1B}]0;title\u{1B}\\text", "text"),
        ]
    )
    func stripsEscapes(_ raw: String, _ expected: String) {
        #expect(TerminalText.clean(raw) == expected)
    }

    @Test("keeps only the last drawing of a line a spinner redrew")
    func carriageReturns() {
        #expect(TerminalText.clean("⠋ lint\r⠙ lint\r✔ lint\nnext") == "✔ lint\nnext")
    }

    // MARK: Summary

    @Test("a short failure is shown whole")
    func shortExcerpt() {
        #expect(TerminalText.excerpt(of: "fatal: bad thing\nhint: try again") == "fatal: bad thing\nhint: try again")
    }

    /// Shaped like the lefthook + commitlint run that prompted this: pages of
    /// passing steps, a linter's clean-ish summary, then the real failure.
    @Test("a long failure is summed up by its last error lines")
    func longExcerpt() {
        let passing = (1...60).map { "apps/api/file\($0).ts 3ms (unchanged)" }
        let output = (passing + [
            "@repo/domain:lint:   0 errors and 1 warning potentially fixable",
            "✖ 1 problem (0 errors, 1 warning)",
            "Tasks:    14 successful, 14 total",
            "────────────────────",
            "⧗   input: Add AI assistant",
            "✖   subject may not be empty [subject-empty]",
            "✖   type may not be empty [type-empty]",
            "✖   found 2 problems, 0 warnings",
            "exit status 1",
            "summary: (done in 0.81 seconds)",
        ]).joined(separator: "\n")

        #expect(TerminalText.excerpt(of: output) == """
            ✖   subject may not be empty [subject-empty]
            ✖   type may not be empty [type-empty]
            ✖   found 2 problems, 0 warnings
            """)
    }

    @Test("with nothing that reads as an error, the last lines stand in")
    func excerptWithoutErrors() {
        let output = (1...20).map { "line \($0)" }.joined(separator: "\n")
        #expect(TerminalText.excerpt(of: output) == "line 18\nline 19\nline 20")
    }

    // MARK: Hooks, from real git

    @Test("a commit refused by a commit-msg hook is reported as the hook, without escapes")
    func hookRejection() async throws {
        let (engine, root, runner) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let hooks = root.appending(path: ".git/hooks")
        let hook = hooks.appending(path: "commit-msg")
        try """
            #!/bin/sh
            printf '\\033[31m✖   type may not be empty [type-empty]\\033[0m\\n'
            exit 1
            """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path())

        try "two\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.write(["add", "-A"], in: root)

        await #expect(throws: GitError.hookRejected("✖   type may not be empty [type-empty]")) {
            try await engine.commit(message: "Add a thing")
        }
    }

    @Test("without hooks, a failed commit stays an ordinary failure")
    func noHookNoHookError() async throws {
        let (engine, root, _) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // Nothing staged: git's own refusal, which is classified as such.
        await #expect(throws: GitError.nothingToCommit) {
            try await engine.commit(message: "Add a thing")
        }
    }

    // MARK: Helpers

    private func makeRepository() async throws -> (RepoEngine, URL, GitRunner) {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let runner = GitRunner(environment: await GitEnvironment.resolve())
        let repository = Repository(
            root: root, gitPath: root.appending(path: ".git"), kind: .standard, depth: 0)
        let engine = RepoEngine(
            repository: repository, runner: runner, limiter: GitTaskLimiter(capacity: 4))

        for arguments in [
            ["init", "--initial-branch=main"],
            ["config", "user.email", "grove@test.invalid"],
            ["config", "user.name", "Grove Test"],
            // A global `core.hooksPath` on the machine running the tests must
            // not decide which hooks this repository has.
            ["config", "core.hooksPath", ".git/hooks"],
        ] {
            _ = try await runner.write(arguments, in: root)
        }
        try FileManager.default.createDirectory(
            at: root.appending(path: ".git/hooks"), withIntermediateDirectories: true)
        try "one\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.write(["add", "-A"], in: root)
        _ = try await runner.write(["commit", "-m", "base"], in: root)
        return (engine, root, runner)
    }
}
