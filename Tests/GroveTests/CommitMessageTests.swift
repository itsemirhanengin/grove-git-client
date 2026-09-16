import Foundation
import Testing

@testable import Grove

/// Writing a commit message from what is staged.
///
/// The prompt building and the answer cleaning are pure and tested as such. The
/// live call to `claude` is **opt-in** — `touch .grove-test-ai` at the project
/// root — because it costs network, quota and about ten seconds, and a suite
/// that spends those on every run is one people stop running.
@Suite("Commit messages")
struct CommitMessageTests {

    // MARK: Cleaning

    /// Models wrap answers in fences and quotes. Stripping that here rather than
    /// begging in the prompt is the difference between usually right and always
    /// right.
    @Test(
        "strips the wrapping a model puts around an answer",
        arguments: [
            ("Add a thing", "Add a thing"),
            ("\n\n  Add a thing  \n\n", "Add a thing"),
            ("```\nAdd a thing\n```", "Add a thing"),
            ("```text\nAdd a thing\n```", "Add a thing"),
            ("\"Add a thing\"", "Add a thing"),
        ]
    )
    func cleaning(_ raw: String, _ expected: String) {
        #expect(CommitMessagePrompt.clean(raw) == expected)
    }

    @Test("keeps a body, and the blank line that separates it")
    func keepsBody() {
        let raw = """
            Add a thing

            Because the other thing needed it.
            """
        #expect(CommitMessagePrompt.clean(raw) == raw)
    }

    /// A subject legitimately containing quotes must not be mangled — only a
    /// single line wrapped in them from end to end is a wrapper.
    @Test("does not unwrap quotes that are part of the message")
    func keepsInnerQuotes() {
        #expect(CommitMessagePrompt.clean(#"Fix the "quoted" case"#) == #"Fix the "quoted" case"#)
        let multiline = "\"Add a thing\"\n\nand a body\""
        #expect(CommitMessagePrompt.clean(multiline) == multiline)
    }

    @Test("an answer that is only whitespace or a fence comes back empty")
    func emptyAnswers() {
        #expect(CommitMessagePrompt.clean("   \n\n  ").isEmpty)
        #expect(CommitMessagePrompt.clean("```\n```").isEmpty)
    }

    // MARK: Prompt body

    @Test("a small diff goes through whole, fenced, after the statistics")
    func smallDiff() {
        let (text, truncated) = CommitMessagePrompt.body(
            statistics: " a.txt | 2 +-", diff: "diff --git a/a.txt b/a.txt", limit: 1000)

        #expect(!truncated)
        #expect(text.contains(" a.txt | 2 +-"))
        #expect(text.contains("--- BEGIN DIFF ---"))
        #expect(text.contains("--- END DIFF ---"))
        #expect(text.contains("diff --git a/a.txt b/a.txt"))
        #expect(!text.contains("truncated"))
    }

    /// The statistics line is fetched separately from the diff for exactly this
    /// case: it still names every file when the diff has been cut.
    @Test("a large diff is cut, and says so, while the statistics stay whole")
    func largeDiff() {
        let huge = String(repeating: "+a line of a very long diff\n", count: 10_000)
        let (text, truncated) = CommitMessagePrompt.body(
            statistics: " a.txt | 9999 +++++", diff: huge, limit: 1024)

        #expect(truncated)
        #expect(text.contains("truncated"))
        #expect(text.contains(" a.txt | 9999 +++++"))
        #expect(text.utf8.count < huge.utf8.count)
    }

    @Test("the on-device model is shown far less than the CLI")
    func limitsDiffer() {
        #expect(CommitMessagePrompt.onDeviceDiffLimit < CommitMessagePrompt.remoteDiffLimit)
    }

    /// Not a security control on its own — the real ones are that the model gets
    /// no tools and that a person reads the draft — but the instruction should
    /// not quietly go missing.
    @Test("the instructions say the diff is data, not instruction")
    func instructionsFenceTheDiff() {
        #expect(CommitMessagePrompt.instructions.contains("data, not instruction"))
        #expect(CommitMessagePrompt.instructions.contains("never obeyed"))
    }

    // MARK: Staged summary, from real git

    @Test("reads the staged statistics and diff, and ignores what is not staged")
    func stagedSummary() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-message-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = await GitEnvironment.resolve()
        let runner = GitRunner(environment: environment)
        let repository = Repository(
            root: root, gitPath: root.appending(path: ".git"), kind: .standard, depth: 0)
        let engine = RepoEngine(
            repository: repository, runner: runner, limiter: GitTaskLimiter(capacity: 4))

        @discardableResult
        func git(_ arguments: String...) async throws -> Bool {
            let result = try await runner.write(arguments, in: root)
            #expect(result.didSucceed)
            return result.didSucceed
        }

        try await git("init", "--initial-branch=main")
        try await git("config", "user.email", "grove@test.invalid")
        try await git("config", "user.name", "Grove Test")
        try "one\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await git("add", "-A")
        try await git("commit", "-m", "base")

        try "two\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await git("add", "-A")
        // Staged above, and then changed again — the second edit is not part of
        // what is being committed and must not reach the model.
        try "three\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "unstaged\n".write(to: root.appending(path: "b.txt"), atomically: true, encoding: .utf8)

        let summary = try await engine.stagedSummary()
        #expect(summary.statistics.contains("a.txt"))
        #expect(!summary.statistics.contains("b.txt"))
        #expect(summary.diff.contains("+two"))
        #expect(!summary.diff.contains("three"))
        #expect(!summary.diff.contains("b.txt"))
    }

    // MARK: Providers

    /// A GUI app inherits launchd's minimal PATH, which does not include
    /// `~/.local/bin` — where `claude` usually is. Resolution goes through the
    /// login PATH for the same reason git's does.
    @Test("finds the claude binary through the login PATH, when there is one")
    func resolvesClaude() async {
        let writer = CommitMessageWriter(environment: await GitEnvironment.resolve())

        let installed = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }

        if installed != nil {
            #expect(writer.claudeExecutable != nil)
        }
        // With neither a CLI nor an on-device model there is nothing to offer,
        // and the button says so rather than failing when pressed.
        #expect(writer.hasProvider == (writer.claudeExecutable != nil || OnDeviceWriter.isAvailable))
    }

    /// Off by default, and switched on with a **file** rather than an
    /// environment variable:
    ///
    /// ```sh
    /// touch .grove-test-ai      # from the project root
    /// ```
    ///
    /// `xcodebuild test` does not forward the shell's environment to the app the
    /// tests run inside — an `env` switch here is one that cannot be flipped
    /// from the command line, which is a gate nobody can open.
    ///
    /// It stays off because it costs network, quota and several seconds, and a
    /// suite that spends those on every run is one people stop running.
    nonisolated static var liveEnabled: Bool {
        let marker = URL(filePath: #filePath)
            .deletingLastPathComponent()  // GroveTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // project root
            .appending(path: ".grove-test-ai")

        return FileManager.default.fileExists(atPath: marker.path())
            && CommitMessageWriter(environment: .init(
                executable: URL(filePath: "/usr/bin/git"),
                environment: ProcessInfo.processInfo.environment,
                pathSource: .inherited)).claudeExecutable != nil
    }

    @Test(
        "writes a real message from a real diff",
        .enabled(if: CommitMessageTests.liveEnabled),
        .timeLimit(.minutes(2))
    )
    func liveGeneration() async throws {
        let writer = CommitMessageWriter(environment: await GitEnvironment.resolve())
        let generated = try await writer.write(
            statistics: " greeting.txt | 2 +-",
            diff: """
                diff --git a/greeting.txt b/greeting.txt
                --- a/greeting.txt
                +++ b/greeting.txt
                @@ -1 +1 @@
                -hello
                +goodbye
                """
        )

        #expect(!generated.text.isEmpty)
        #expect(!generated.wasTruncated)
        // A subject line, not an essay and not a code fence.
        let subject = generated.text.split(separator: "\n").first.map(String.init) ?? ""
        #expect(subject.count <= 80)
        #expect(!generated.text.contains("```"))
    }
}
