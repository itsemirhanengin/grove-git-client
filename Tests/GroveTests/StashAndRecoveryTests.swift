import Foundation
import Testing

@testable import Grove

/// Stashes, and the snapshots Grove takes before it can lose work.
@Suite("Stashes and recovery")
struct StashAndRecoveryTests {

    private struct Lab {
        var engine: RepoEngine
        var root: URL
        var runner: GitRunner

        @discardableResult
        func git(_ arguments: String...) async throws -> String {
            let result = try await runner.write(arguments, in: root)
            #expect(result.didSucceed, "git \(arguments.joined(separator: " ")) failed")
            return String(decoding: result.stdout, as: UTF8.self)
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }

        func read(_ name: String) throws -> String {
            try String(contentsOf: root.appending(path: name), encoding: .utf8)
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appending(path: name).path())
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeLab() async throws -> Lab {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-stash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let environment = await GitEnvironment.resolve()
        let runner = GitRunner(environment: environment)
        let repository = Repository(
            root: root, gitPath: root.appending(path: ".git"), kind: .standard, depth: 0)
        let lab = Lab(
            engine: RepoEngine(
                repository: repository, runner: runner, limiter: GitTaskLimiter(capacity: 4)),
            root: root,
            runner: runner
        )

        try await lab.git("init", "--initial-branch=main")
        try await lab.git("config", "user.email", "grove@test.invalid")
        try await lab.git("config", "user.name", "Grove Test")
        try lab.write("tracked.txt", "one\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "base")
        return lab
    }

    // MARK: Stashing

    @Test("stashes the working copy, keeps the message, and reads it back")
    func createAndList() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("tracked.txt", "two\n")
        try await lab.engine.createStash(
            message: "half a thought", includeUntracked: false, keepIndex: false)

        #expect(try lab.read("tracked.txt") == "one\n", "the working copy went back to HEAD")

        let stashes = try await lab.engine.stashes()
        #expect(stashes.count == 1)
        #expect(stashes[0].message == "half a thought")
        #expect(stashes[0].branch == "main", "the branch comes out of git's own subject prefix")
        #expect(stashes[0].selector == "stash@{0}")
        #expect(stashes[0].date != nil)
    }

    /// An automatic stash has no message of its own; git writes
    /// `WIP on main: 1a2b3c Subject`, and showing that raw is showing plumbing.
    @Test("an unnamed stash still reports a branch and a readable message")
    func unnamedStash() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("tracked.txt", "two\n")
        try await lab.engine.createStash(
            message: nil, includeUntracked: false, keepIndex: false)

        let stash = try #require(try await lab.engine.stashes().first)
        #expect(stash.branch == "main")
        #expect(!stash.message.hasPrefix("WIP on"))
        #expect(stash.message.contains("base"), "git falls back to the commit subject")
    }

    /// The trap: `git stash` leaves untracked files behind by default, and a
    /// later `git clean` eats them.
    @Test("untracked files are left alone unless asked for")
    func untrackedFiles() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("tracked.txt", "two\n")
        try lab.write("fresh.txt", "new\n")

        try await lab.engine.createStash(
            message: "without", includeUntracked: false, keepIndex: false)
        #expect(lab.exists("fresh.txt"), "still on disk, and still untracked")

        try await lab.engine.createStash(
            message: "with", includeUntracked: true, keepIndex: false)
        #expect(!lab.exists("fresh.txt"), "taken along this time")
    }

    @Test("keeping the index stashes only what was not staged")
    func keepIndex() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("tracked.txt", "staged\n")
        try await lab.git("add", "-A")
        try lab.write("other.txt", "unstaged\n")

        try await lab.engine.createStash(message: nil, includeUntracked: true, keepIndex: true)

        #expect(try lab.read("tracked.txt") == "staged\n", "the staged half stayed")
        #expect(!lab.exists("other.txt"), "the rest went into the stash")
    }

    // MARK: Applying

    @Test("apply keeps the stash, pop removes it")
    func applyAndPop() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("tracked.txt", "two\n")
        try await lab.engine.createStash(message: "one", includeUntracked: false, keepIndex: false)

        var stash = try #require(try await lab.engine.stashes().first)
        try await lab.engine.applyStash(stash)
        #expect(try lab.read("tracked.txt") == "two\n")
        #expect(try await lab.engine.stashes().count == 1, "apply leaves it in the list")

        // Reset the worktree so the pop has somewhere to land.
        try await lab.git("checkout", "--", "tracked.txt")
        stash = try #require(try await lab.engine.stashes().first)
        try await lab.engine.popStash(stash)
        #expect(try lab.read("tracked.txt") == "two\n")
        #expect(try await lab.engine.stashes().isEmpty, "pop takes it out")
    }

    /// The selector is positional and renumbers, so the row that was
    /// `stash@{1}` becomes `stash@{0}` the moment something below it is dropped.
    @Test("dropping one stash renumbers the others")
    func droppingRenumbers() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        for index in 0..<3 {
            try lab.write("tracked.txt", "v\(index)\n")
            try await lab.engine.createStash(
                message: "stash \(index)", includeUntracked: false, keepIndex: false)
        }

        var stashes = try await lab.engine.stashes()
        #expect(stashes.count == 3)
        #expect(stashes[0].message == "stash 2", "newest first")

        let middle = stashes[1]
        try await lab.engine.dropStash(middle)

        stashes = try await lab.engine.stashes()
        #expect(stashes.count == 2)
        #expect(!stashes.contains { $0.oid == middle.oid })
        #expect(stashes.map(\.selector) == ["stash@{0}", "stash@{1}"])
    }

    // MARK: What a stash holds

    @Test("reads a stash's files and their diffs against the commit it was taken from")
    func stashContents() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("tracked.txt", "two\n")
        try lab.write("second.txt", "brand new\n")
        try await lab.git("add", "second.txt")
        try await lab.engine.createStash(message: "both", includeUntracked: false, keepIndex: false)

        let stash = try #require(try await lab.engine.stashes().first)
        let changes = try await lab.engine.stashChanges(stash)

        #expect(changes.count == 2)
        #expect(changes.contains { $0.displayPath == "tracked.txt" })
        #expect(changes.contains { $0.displayPath == "second.txt" })

        let tracked = try #require(changes.first { $0.displayPath == "tracked.txt" })
        let patch = try await lab.engine.stashFileDiff(for: tracked, in: stash)
        #expect(patch.contains("-one"))
        #expect(patch.contains("+two"))
        #expect(!patch.contains("second.txt"))
    }

    // MARK: Recovery

    @Test("a discard leaves a snapshot that can be listed and put back")
    func backupRoundTrip() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        #expect(try await lab.engine.backups().isEmpty)

        try lab.write("tracked.txt", "work worth keeping\n")
        let status = try await lab.engine.status()
        let change = try #require(status.changes.first { $0.displayPath == "tracked.txt" })

        let outcome = try await lab.engine.discard([change])
        #expect(try lab.read("tracked.txt") == "one\n", "the discard really happened")

        let ref = try #require(outcome.backupRef)
        let backups = try await lab.engine.backups()
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(backup.refName == ref)
        #expect(backup.reason == "discard", "the reason is readable from the ref name")
        #expect(backup.date != nil)
        #expect(backup.recoveryCommand == "git stash apply \(ref)")

        try await lab.engine.restore(backup)
        #expect(try lab.read("tracked.txt") == "work worth keeping\n", "and it came back")
    }

    /// The snapshot has to be invisible to the two lists a user reads every day,
    /// or the safety net becomes noise they learn to ignore.
    @Test("snapshots stay out of the branch and stash lists")
    func backupsAreHidden() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("tracked.txt", "gone in a moment\n")
        let change = try #require(
            try await lab.engine.status().changes.first { $0.displayPath == "tracked.txt" })
        _ = try await lab.engine.discard([change])

        #expect(try await lab.engine.backups().count == 1)
        #expect(try await lab.engine.stashes().isEmpty)
        let branchNames = try await lab.engine.branches().map(\.name)
        #expect(!branchNames.contains { $0.contains("grove") })
    }

    @Test("forgetting a snapshot removes it from the list")
    func forgetBackup() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("tracked.txt", "temporary\n")
        let change = try #require(
            try await lab.engine.status().changes.first { $0.displayPath == "tracked.txt" })
        _ = try await lab.engine.discard([change])

        let backup = try #require(try await lab.engine.backups().first)
        try await lab.engine.forgetBackup(backup)
        #expect(try await lab.engine.backups().isEmpty)
    }

    @Test("a ref name carries its reason back out again")
    func refNaming() {
        let name = BackupRef.name(epoch: 1_758_000_000, reason: "discard lines")
        #expect(name == "refs/grove/backup/1758000000-discard-lines")

        let parsed = BackupRef.parse(Array("\(name)\0abc123\n".utf8))
        #expect(parsed.count == 1)
        #expect(parsed[0].reason == "discard-lines")
        #expect(parsed[0].oid == "abc123")
        #expect(parsed[0].date == Date(timeIntervalSince1970: 1_758_000_000))
    }
}
