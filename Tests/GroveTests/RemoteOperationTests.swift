import Foundation
import Testing

@testable import Grove

/// Fetch, pull, push, switch and merge, against real repositories.
///
/// The remote is a bare repository on disk, so none of this touches the network
/// — but every command is the real one, talking to a real remote, which is the
/// only way to find out that `--set-upstream` needs a branch name or that a
/// refused fast-forward says so on stderr rather than stdout.
@Suite("Remote and branch operations")
struct RemoteOperationTests {

    // MARK: Scaffolding

    private struct Lab {
        var engine: RepoEngine
        var root: URL
        var remote: URL
        var runner: GitRunner
        var scratch: URL

        @discardableResult
        func git(_ arguments: String..., in directory: URL? = nil) async throws -> String {
            let result = try await runner.write(arguments, in: directory ?? root)
            #expect(result.didSucceed, "git \(arguments.joined(separator: " ")) failed")
            return String(decoding: result.stdout, as: UTF8.self)
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(
                to: root.appending(path: name), atomically: true, encoding: .utf8)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    /// A repository with a bare remote it is already tracking.
    private func makeLab() async throws -> Lab {
        let scratch = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-remote-\(UUID().uuidString)")
        let root = scratch.appending(path: "work")
        let remote = scratch.appending(path: "origin.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let environment = await GitEnvironment.resolve()
        let runner = GitRunner(environment: environment)
        let repository = Repository(
            root: root, gitPath: root.appending(path: ".git"), kind: .standard, depth: 0)

        let lab = Lab(
            engine: RepoEngine(
                repository: repository, runner: runner, limiter: GitTaskLimiter(capacity: 4)),
            root: root,
            remote: remote,
            runner: runner,
            scratch: scratch
        )

        try await lab.git("init", "--bare", "--initial-branch=main", remote.path())
        try await lab.git("init", "--initial-branch=main")
        try await lab.git("config", "user.email", "grove@test.invalid")
        try await lab.git("config", "user.name", "Grove Test")
        try lab.write("README.md", "one\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "first")
        try await lab.git("remote", "add", "origin", remote.path())
        try await lab.git("push", "--set-upstream", "origin", "main")
        return lab
    }

    /// A second clone, standing in for someone else pushing to the same remote.
    private func makeCollaborator(_ lab: Lab) async throws -> URL {
        let other = lab.scratch.appending(path: "other")
        try await lab.git("clone", lab.remote.path(), other.path(), in: lab.scratch)
        try await lab.git("config", "user.email", "other@test.invalid", in: other)
        try await lab.git("config", "user.name", "Other", in: other)
        return other
    }

    // MARK: Push

    @Test("publishes a branch that has never been pushed, and refuses to guess otherwise")
    func publishesNewBranch() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try await lab.engine.createBranch(named: "feature")
        try lab.write("feature.txt", "work\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "feature work")

        var status = try await lab.engine.status()
        #expect(status.upstream == nil, "a fresh branch has nowhere to go yet")

        // Without `setUpstream` git has no idea where this belongs, and says so
        // rather than picking a remote.
        await #expect(throws: GitError.noUpstream) {
            try await lab.engine.push(setUpstream: false)
        }

        try await lab.engine.push(setUpstream: true)
        status = try await lab.engine.status()
        #expect(status.upstream == "origin/feature")
        #expect(status.ahead == 0)
    }

    @Test("pushes an existing branch and clears the ahead count")
    func pushesAhead() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("README.md", "one\ntwo\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "second")

        var status = try await lab.engine.status()
        #expect(status.ahead == 1)

        try await lab.engine.push(setUpstream: false)
        status = try await lab.engine.status()
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
    }

    // MARK: Fetch and pull

    @Test("fetch reports what the remote gained without touching the working tree")
    func fetchLeavesTheWorkingTreeAlone() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        let other = try await makeCollaborator(lab)
        try "one\ntheirs\n".write(
            to: other.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await lab.git("add", "-A", in: other)
        try await lab.git("commit", "-m", "theirs", in: other)
        try await lab.git("push", in: other)

        try await lab.engine.fetch()

        let status = try await lab.engine.status()
        #expect(status.behind == 1, "the branch is behind, and knows it")
        #expect(status.changes.isEmpty, "fetch must not touch the working tree")

        let onDisk = try String(
            contentsOf: lab.root.appending(path: "README.md"), encoding: .utf8)
        #expect(onDisk == "one\n")
    }

    @Test("a fast-forward pull brings the work in")
    func pullFastForward() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        let other = try await makeCollaborator(lab)
        try "one\ntheirs\n".write(
            to: other.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await lab.git("add", "-A", in: other)
        try await lab.git("commit", "-m", "theirs", in: other)
        try await lab.git("push", in: other)

        try await lab.engine.pull(.fastForwardOnly)

        let onDisk = try String(
            contentsOf: lab.root.appending(path: "README.md"), encoding: .utf8)
        #expect(onDisk == "one\ntheirs\n")
        #expect(try await lab.engine.status().behind == 0)
    }

    /// The reason `pull` defaults to `--ff-only`: when both sides have moved,
    /// git is asked to refuse rather than to invent a merge commit.
    @Test("a diverged branch refuses to fast-forward instead of merging silently")
    func pullRefusesToInventAMerge() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        let other = try await makeCollaborator(lab)
        try "one\ntheirs\n".write(
            to: other.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await lab.git("add", "-A", in: other)
        try await lab.git("commit", "-m", "theirs", in: other)
        try await lab.git("push", in: other)

        try lab.write("mine.txt", "mine\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "mine")

        await #expect(throws: GitError.notFastForward) {
            try await lab.engine.pull(.fastForwardOnly)
        }

        // Nothing was merged, and the local commit is untouched.
        let status = try await lab.engine.status()
        #expect(status.inProgress == nil)
        #expect(status.ahead == 1)

        // Asked explicitly, it merges.
        try await lab.engine.pull(.merge)
        let merged = try await lab.engine.status()
        #expect(merged.behind == 0)
        #expect(FileManager.default.fileExists(atPath: lab.root.appending(path: "mine.txt").path()))
    }

    // MARK: Branches

    @Test("switches to a local branch, and creates a tracking one from a remote")
    func switching() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        let other = try await makeCollaborator(lab)
        try await lab.git("switch", "--create", "theirs", in: other)
        try "x\n".write(
            to: other.appending(path: "theirs.txt"), atomically: true, encoding: .utf8)
        try await lab.git("add", "-A", in: other)
        try await lab.git("commit", "-m", "their branch", in: other)
        try await lab.git("push", "--set-upstream", "origin", "theirs", in: other)

        try await lab.engine.fetch()

        let remoteBranch = try #require(
            try await lab.engine.branches().first { $0.name == "origin/theirs" })
        try await lab.engine.switchTo(remoteBranch)

        var status = try await lab.engine.status()
        #expect(status.branch == "theirs")
        #expect(status.upstream == "origin/theirs")

        let main = try #require(try await lab.engine.branches().first { $0.name == "main" })
        try await lab.engine.switchTo(main)
        status = try await lab.engine.status()
        #expect(status.branch == "main")

        // Going back to the remote branch again must not fail on "already
        // exists" — the local one is what was meant.
        try await lab.engine.switchTo(remoteBranch)
        #expect(try await lab.engine.status().branch == "theirs")
    }

    @Test("refuses to switch when it would overwrite uncommitted work")
    func switchProtectsUncommittedWork() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try await lab.engine.createBranch(named: "feature")
        try lab.write("README.md", "feature version\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "feature edit")
        try await lab.git("switch", "main")

        // Uncommitted, and in the way.
        try lab.write("README.md", "uncommitted\n")

        let feature = try #require(try await lab.engine.branches().first { $0.name == "feature" })
        await #expect(throws: (any Error).self) {
            try await lab.engine.switchTo(feature)
        }

        #expect(try await lab.engine.status().branch == "main")
        let onDisk = try String(
            contentsOf: lab.root.appending(path: "README.md"), encoding: .utf8)
        #expect(onDisk == "uncommitted\n", "the work is still there")
    }

    // MARK: Merge

    @Test("reports which kind of merge it was")
    func mergeOutcomes() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try await lab.engine.createBranch(named: "feature")
        try lab.write("feature.txt", "work\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "feature work")
        try await lab.git("switch", "main")

        let feature = try #require(try await lab.engine.branches().first { $0.name == "feature" })

        #expect(try await lab.engine.merge(feature) == .fastForward)
        #expect(try await lab.engine.merge(feature) == .alreadyUpToDate)
    }

    /// A conflict is a state, not a failure. Reporting it as an error invites
    /// the UI to roll back a merge the user now has to finish.
    @Test("a conflicting merge comes back as a state, with the repository mid-merge")
    func mergeConflict() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try await lab.engine.createBranch(named: "feature")
        try lab.write("README.md", "theirs\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "their edit")

        try await lab.git("switch", "main")
        try lab.write("README.md", "ours\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "our edit")

        let feature = try #require(try await lab.engine.branches().first { $0.name == "feature" })
        #expect(try await lab.engine.merge(feature) == .conflicted)

        var status = try await lab.engine.status()
        #expect(status.inProgress == .merge)
        #expect(status.hasConflicts)

        try await lab.engine.abort(.merge)
        status = try await lab.engine.status()
        #expect(status.inProgress == nil)
        #expect(!status.hasConflicts)

        let onDisk = try String(
            contentsOf: lab.root.appending(path: "README.md"), encoding: .utf8)
        #expect(onDisk == "ours\n", "aborting puts the branch back as it was")
    }
}
