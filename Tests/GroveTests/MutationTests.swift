import Foundation
import Testing

@testable import Grove

/// Write operations, against throwaway copies of the fixtures.
///
/// Every test works on its own copy: these mutate repositories, and a test that
/// corrupts the shared fixtures would poison every suite that runs after it.
@Suite("Repository mutations")
struct MutationTests {

    nonisolated static var fixturesAvailable: Bool { GitRunnerTests.fixturesAvailable }

    /// Copies a fixture to a temp directory and returns an engine for it.
    private func makeEngine(from fixture: String) async throws -> (RepoEngine, URL) {
        let source = GitRunnerTests.fixtures.appending(path: fixture)
        let destination = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-mut-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: destination)

        let environment = await GitEnvironment.resolve()
        let repository = Repository(
            root: destination,
            gitPath: destination.appending(path: ".git"),
            kind: .standard,
            depth: 0
        )
        let engine = RepoEngine(
            repository: repository,
            runner: GitRunner(environment: environment),
            limiter: GitTaskLimiter(capacity: 4)
        )
        return (engine, destination)
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Staging

    @Test("stages and unstages a tracked file", .enabled(if: MutationTests.fixturesAvailable))
    func stageUnstage() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        var status = try await engine.status()
        let venue = try #require(
            status.changes.first { $0.displayPath.hasSuffix("VenueDetail.js") })
        #expect(venue.isUnstaged && !venue.isStaged)

        try await engine.stage([venue])
        status = try await engine.status()
        let staged = try #require(
            status.changes.first { $0.displayPath.hasSuffix("VenueDetail.js") })
        #expect(staged.isStaged)
        #expect(!staged.isUnstaged)

        try await engine.unstage([staged])
        status = try await engine.status()
        let back = try #require(
            status.changes.first { $0.displayPath.hasSuffix("VenueDetail.js") })
        #expect(back.isUnstaged)
        #expect(!back.isStaged)
    }

    @Test("stages an untracked file", .enabled(if: MutationTests.fixturesAvailable))
    func stageUntracked() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        var status = try await engine.status()
        let config = try #require(status.changes.first { $0.displayPath.hasSuffix("config.js") })
        #expect(config.kind == .untracked)

        try await engine.stage([config])
        status = try await engine.status()
        let staged = try #require(status.changes.first { $0.displayPath.hasSuffix("config.js") })
        #expect(staged.kind == .tracked)
        #expect(staged.indexStatus == .added)
    }

    /// Paths with spaces, newlines and non-ASCII must survive the round trip
    /// through stdin. This is why pathspecs are written as raw bytes.
    @Test("stages a file whose name would break argv", .enabled(if: MutationTests.fixturesAvailable))
    func stageHostileFileName() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        let hostile = "garip dosya\nadı şğü.txt"
        FileManager.default.createFile(
            atPath: root.path() + "/" + hostile, contents: Data("hi".utf8))

        var status = try await engine.status()
        let change = try #require(status.changes.first { $0.displayPath == hostile })
        #expect(change.kind == .untracked)

        try await engine.stage([change])
        status = try await engine.status()

        let staged = try #require(status.changes.first { $0.displayPath == hostile })
        #expect(staged.indexStatus == .added, "the hostile path did not stage")
    }

    /// A rename occupies two paths in the index: the new one added, the old one
    /// deleted. Unstaging by the new path alone leaves the deletion of the
    /// original staged — a phantom the next commit would carry out, silently
    /// deleting a file the user never meant to remove.
    @Test("unstaging a rename clears both of its paths", .enabled(if: MutationTests.fixturesAvailable))
    func unstageRenameClearsBothPaths() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        var status = try await engine.status()
        let rename = try #require(status.changes.first { $0.indexStatus == .renamed })
        #expect(rename.displayPath.hasSuffix("helpers.js"))
        #expect(rename.originalDisplayPath == "src/legacy.js")

        try await engine.unstage([rename])
        status = try await engine.status()

        // Unstaging a rename turns it back into its two unstaged halves: the
        // original shows as deleted in the worktree, the new name as untracked.
        #expect(!status.changes.contains { $0.indexStatus == .renamed })
        #expect(
            !status.changes.contains { $0.displayPath == "src/legacy.js" && $0.isStaged },
            "the original path was left staged as a deletion"
        )
        #expect(status.changes.contains { $0.displayPath == "src/helpers.js" && $0.kind == .untracked })
        // The other staged files are untouched — unstaging one thing unstages
        // only that thing.
        #expect(status.staged.count == 2)
    }

    @Test("staging then unstaging everything is a round trip", .enabled(if: MutationTests.fixturesAvailable))
    func stageAllUnstageAllRoundTrip() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        let before = try await engine.status()

        try await engine.stage(before.changes)
        var status = try await engine.status()
        #expect(status.unstaged.isEmpty)
        #expect(status.untracked.isEmpty)

        try await engine.unstage(status.staged)
        status = try await engine.status()

        #expect(status.staged.isEmpty, "left over: \(status.staged.map(\.displayPath))")

        // The paths are not identical to where we started, and that is correct:
        // git only reports a rename while both halves sit in the index together,
        // so unstaging decomposes it back into a deleted original and an
        // untracked new name. What matters is that no work vanished.
        let paths = Set(status.changes.map(\.displayPath))
        #expect(paths.contains("src/legacy.js"))
        #expect(paths.contains("src/helpers.js"))
        for original in before.changes.map(\.displayPath) where original != "src/helpers.js" {
            #expect(paths.contains(original), "\(original) disappeared during the round trip")
        }
    }

    @Test("unstage works in a repository with no commits", .enabled(if: MutationTests.fixturesAvailable))
    func unstageUnborn() async throws {
        let (engine, root) = try await makeEngine(from: "delta")
        defer { cleanUp(root) }

        var status = try await engine.status()
        #expect(status.isUnborn)
        let readme = try #require(status.changes.first)

        try await engine.stage([readme])
        status = try await engine.status()
        #expect(status.staged.count == 1)

        // `git restore --staged` has no HEAD to work from here; the engine must
        // fall back to removing from the index instead of failing.
        try await engine.unstage([status.staged[0]])
        status = try await engine.status()
        #expect(status.staged.isEmpty)
        #expect(status.untracked.count == 1)
    }

    // MARK: Commit

    @Test("commits staged changes", .enabled(if: MutationTests.fixturesAvailable))
    func commitStaged() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        let before = try await engine.status()
        try await engine.commit(message: "test: commit the staged changes")

        let after = try await engine.status()
        #expect(after.staged.isEmpty)
        // The unstaged work must survive untouched.
        #expect(after.unstaged.count == before.unstaged.count)
    }

    @Test("refuses an empty commit message", .enabled(if: MutationTests.fixturesAvailable))
    func emptyMessage() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        await #expect(throws: GitError.emptyCommitMessage) {
            try await engine.commit(message: "   \n  ")
        }
    }

    @Test("makes the first commit in an unborn repository", .enabled(if: MutationTests.fixturesAvailable))
    func firstCommit() async throws {
        let (engine, root) = try await makeEngine(from: "delta")
        defer { cleanUp(root) }

        var status = try await engine.status()
        #expect(status.isUnborn)

        try await engine.stage(status.changes)
        try await engine.commit(message: "Initial commit")

        status = try await engine.status()
        #expect(!status.isUnborn)
        #expect(status.headOID != nil)
        #expect(status.changes.isEmpty)
    }

    // MARK: Discard — the operation that can lose work

    @Test("discarding a tracked file restores it and leaves a backup", .enabled(if: MutationTests.fixturesAvailable))
    func discardTracked() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        var status = try await engine.status()
        let venue = try #require(
            status.changes.first { $0.displayPath.hasSuffix("VenueDetail.js") })

        let contentsBefore = try String(
            contentsOf: root.appending(path: venue.displayPath), encoding: .utf8)
        #expect(contentsBefore.contains("venue capacity fix"))

        let outcome = try await engine.discard([venue])

        // The edit is gone from the worktree…
        let contentsAfter = try String(
            contentsOf: root.appending(path: venue.displayPath), encoding: .utf8)
        #expect(!contentsAfter.contains("venue capacity fix"))

        status = try await engine.status()
        #expect(!status.changes.contains { $0.displayPath == venue.displayPath })

        // …but recoverable, which is the whole point.
        let backupRef = try #require(outcome.backupRef, "no backup ref was created")
        #expect(backupRef.hasPrefix("refs/grove/backup/"))

        let runner = GitRunner(environment: await GitEnvironment.resolve())
        let show = try await runner.read(
            ["show", "\(backupRef):\(venue.displayPath)"], in: root)
        #expect(show.didSucceed, "the backup ref does not resolve")
        #expect(String(decoding: show.stdout, as: UTF8.self).contains("venue capacity fix"))
    }

    /// Untracked files are not in git at all, so a backup ref cannot hold them.
    /// The Trash is what makes this reversible — never `git clean`.
    @Test("discarding an untracked file moves it to the Trash", .enabled(if: MutationTests.fixturesAvailable))
    func discardUntrackedGoesToTrash() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        let status = try await engine.status()
        let config = try #require(status.changes.first { $0.displayPath.hasSuffix("config.js") })
        let path = root.appending(path: config.displayPath)
        #expect(FileManager.default.fileExists(atPath: path.path()))

        let outcome = try await engine.discard([config])

        #expect(!FileManager.default.fileExists(atPath: path.path()))
        #expect(outcome.trashedPaths == [config.displayPath])
        #expect(outcome.failures.isEmpty)
        // It went to the Trash, not through `git clean`, so it is recoverable
        // from Finder.
        #expect(outcome.restoredPaths.isEmpty)
    }

    @Test("a backup ref is invisible to branch and stash listings", .enabled(if: MutationTests.fixturesAvailable))
    func backupRefIsHidden() async throws {
        let (engine, root) = try await makeEngine(from: "alpha")
        defer { cleanUp(root) }

        let ref = try #require(try await engine.createBackup(reason: "test"))
        let runner = GitRunner(environment: await GitEnvironment.resolve())

        let branches = try await runner.read(["branch", "--all"], in: root)
        #expect(!String(decoding: branches.stdout, as: UTF8.self).contains("grove"))

        let stashes = try await runner.read(["stash", "list"], in: root)
        #expect(String(decoding: stashes.stdout, as: UTF8.self).isEmpty)

        // But it resolves, and the worktree was never touched creating it.
        let verify = try await runner.read(["rev-parse", "--verify", ref], in: root)
        #expect(verify.didSucceed)

        let status = try await engine.status()
        #expect(status.dirtyCount == 6, "creating a backup must not change the worktree")
    }

    @Test("createBackup returns nil in a clean repository", .enabled(if: MutationTests.fixturesAvailable))
    func backupOfCleanRepo() async throws {
        let (engine, root) = try await makeEngine(from: "beta")
        defer { cleanUp(root) }

        let status = try await engine.status()
        #expect(status.changes.isEmpty)
        #expect(try await engine.createBackup(reason: "test") == nil)
    }
}
