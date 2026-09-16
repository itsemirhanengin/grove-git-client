import Foundation
import Testing

@testable import Grove

/// Resolving a real merge conflict.
///
/// Every repository here is put into conflict by git itself rather than by
/// writing marker text into a file: the index stages, `MERGE_HEAD` and the
/// working-tree markers all have to be genuinely present, and only a real merge
/// produces all three consistently.
@Suite("Conflict resolution")
struct ConflictResolutionTests {

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

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        /// Whether the index still holds unmerged stages for anything.
        ///
        /// The real test of "resolved", and the only one that holds for both
        /// sides: taking *ours* leaves a file identical to HEAD, so it shows up
        /// in no status list at all — which looks exactly like nothing having
        /// happened, and is not.
        func hasUnmergedEntries() async throws -> Bool {
            let result = try await runner.read(["ls-files", "--unmerged"], in: root)
            return !result.stdout.isEmpty
        }
    }

    /// A repository sitting in a real conflicted merge of `shared.txt`.
    private func makeConflict() async throws -> Lab {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-conflict-\(UUID().uuidString)")
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

        try lab.write("shared.txt", "top\nbase\nbottom\n")
        try lab.write("quiet.txt", "untouched\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "base")

        try await lab.git("switch", "--create", "theirs")
        try lab.write("shared.txt", "top\ntheirs\nbottom\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "their edit")

        try await lab.git("switch", "main")
        try lab.write("shared.txt", "top\nours\nbottom\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "our edit")

        let theirs = try #require(try await lab.engine.branches().first { $0.name == "theirs" })
        #expect(try await lab.engine.merge(theirs) == .conflicted)
        return lab
    }

    private func conflicted(_ lab: Lab) async throws -> FileChange {
        let status = try await lab.engine.status()
        return try #require(status.conflicted.first { $0.displayPath == "shared.txt" })
    }

    // MARK: Reading

    @Test("reads the file git actually left on disk, markers and all")
    func readsMarkers() async throws {
        let lab = try await makeConflict()
        defer { lab.tearDown() }

        let change = try await conflicted(lab)
        let contents = try await lab.engine.conflictedContents(for: change)

        #expect(contents.contains("<<<<<<<"))
        #expect(contents.contains("======="))
        #expect(contents.contains(">>>>>>>"))
        #expect(contents.contains("ours"))
        #expect(contents.contains("theirs"))
        // The unchanged surroundings survive, which is what makes it resolvable
        // by hand rather than only side-by-side.
        #expect(contents.contains("top"))
        #expect(contents.contains("bottom"))

        // And it is byte-for-byte what is on disk — not a reconstruction.
        #expect(contents == (try lab.read("shared.txt")))
    }

    @Test("all three stages are readable, which is what a three-way view needs")
    func stagesArePresent() async throws {
        let lab = try await makeConflict()
        defer { lab.tearDown() }

        let change = try await conflicted(lab)
        let stages = try #require(change.unmergedStages)
        #expect(!stages.base.isEmpty, "a modify/modify conflict has a common ancestor")
        #expect(!stages.ours.isEmpty)
        #expect(!stages.theirs.isEmpty)
    }

    // MARK: Resolving

    @Test(
        "taking one side whole rewrites the file and stages it",
        arguments: [
            (RepoEngine.ConflictSide.ours, "ours"),
            (RepoEngine.ConflictSide.theirs, "theirs"),
        ]
    )
    func takeOneSide(_ side: RepoEngine.ConflictSide, _ expected: String) async throws {
        let lab = try await makeConflict()
        defer { lab.tearDown() }

        let change = try await conflicted(lab)
        try await lab.engine.resolve(change, using: side)

        #expect(try lab.read("shared.txt") == "top\n\(expected)\nbottom\n")

        let status = try await lab.engine.status()
        #expect(!status.hasConflicts)
        // Staging is what tells git it is settled — markers being gone is not
        // enough, and an unstaged "resolution" is how one gets silently lost.
        #expect(try await lab.hasUnmergedEntries() == false)
        #expect(status.inProgress == .merge, "still mid-merge until it is committed")

        // Only *theirs* is a change relative to HEAD. Taking ours restores
        // exactly what was already committed, so it correctly appears in no
        // status list whatsoever.
        #expect(
            status.staged.contains { $0.displayPath == "shared.txt" } == (side == .theirs))
    }

    @Test("a resolution written by the resolver is put on disk and staged")
    func applyResolution() async throws {
        let lab = try await makeConflict()
        defer { lab.tearDown() }

        let change = try await conflicted(lab)
        // What the page hands back: the whole file, markers gone.
        try await lab.engine.applyResolution("top\nours\ntheirs\nbottom\n", to: change)

        #expect(try lab.read("shared.txt") == "top\nours\ntheirs\nbottom\n")

        let status = try await lab.engine.status()
        #expect(!status.hasConflicts)
        #expect(try await lab.hasUnmergedEntries() == false)
        #expect(status.staged.contains { $0.displayPath == "shared.txt" })
    }

    /// A file with several conflict regions arrives one region at a time.
    ///
    /// Staging on the first one would settle the conflict in the index *around*
    /// the remaining markers — which is exactly how conflict markers end up in a
    /// commit.
    @Test("a partly-resolved file is written but not staged")
    func partialResolutionIsNotStaged() async throws {
        let lab = try await makeConflict()
        defer { lab.tearDown() }

        let change = try await conflicted(lab)
        let original = try await lab.engine.conflictedContents(for: change)

        // One region taken, a second still open — what the page produces when a
        // file has two conflicts and only one has been decided.
        let halfway = original + "\n<<<<<<< HEAD\nstill open\n=======\ntheir side\n>>>>>>> theirs\n"

        let settled = try await lab.engine.applyResolution(halfway, to: change)
        #expect(settled == false)
        #expect(try lab.read("shared.txt") == halfway, "it is still written to disk")

        let midway = try await lab.engine.status()
        #expect(midway.hasConflicts, "and still conflicted, because it still is")
        #expect(try await lab.hasUnmergedEntries())

        // Finished, and now it stages.
        let done = try await lab.engine.applyResolution("top\nours\nbottom\n", to: change)
        #expect(done)
        #expect(try await lab.hasUnmergedEntries() == false)
    }

    @Test(
        "marker detection only trusts a line start",
        arguments: [
            ("<<<<<<< HEAD\nx\n", true),
            ("a\n<<<<<<< HEAD\nx\n", true),
            ("a <<<<<<< not a marker\n", false),
            ("clean\nfile\n", false),
        ]
    )
    func markerDetection(_ text: String, _ expected: Bool) {
        #expect(RepoEngine.containsConflictMarkers(text) == expected)
    }

    // MARK: Finishing

    @Test("the merge commits once nothing is conflicted, and keeps git's message")
    func continueMerge() async throws {
        let lab = try await makeConflict()
        defer { lab.tearDown() }

        let change = try await conflicted(lab)
        try await lab.engine.resolve(change, using: .theirs)
        try await lab.engine.continueMerge()

        let status = try await lab.engine.status()
        #expect(status.inProgress == nil)
        #expect(!status.hasConflicts)
        #expect(status.changes.isEmpty)

        let log = try await lab.git("log", "-1", "--pretty=%s")
        #expect(log.contains("Merge branch 'theirs'"))
    }

    @Test("aborting puts the branch back exactly as it was")
    func abort() async throws {
        let lab = try await makeConflict()
        defer { lab.tearDown() }

        try await lab.engine.abort(.merge)

        let status = try await lab.engine.status()
        #expect(status.inProgress == nil)
        #expect(!status.hasConflicts)
        #expect(status.changes.isEmpty)
        #expect(try lab.read("shared.txt") == "top\nours\nbottom\n")
    }

    /// Only one file conflicted; the rest of the merge is not in question.
    @Test("files that merged cleanly are already staged and stay out of the way")
    func cleanFilesAreNotConflicted() async throws {
        let lab = try await makeConflict()
        defer { lab.tearDown() }

        let status = try await lab.engine.status()
        #expect(status.conflicted.count == 1)
        #expect(status.conflicted[0].displayPath == "shared.txt")
        #expect(!status.changes.contains { $0.displayPath == "quiet.txt" })
    }

    // MARK: Binary

    @Test("a binary conflict says so instead of showing mangled text")
    func binaryConflict() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-conflict-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

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

        let file = root.appending(path: "blob.bin")
        try Data([0x00, 0x01, 0x02]).write(to: file)
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "base")

        try await lab.git("switch", "--create", "theirs")
        try Data([0x00, 0xFF, 0xFE, 0x03]).write(to: file)
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "their bytes")

        try await lab.git("switch", "main")
        try Data([0x00, 0x7F, 0x80, 0x04]).write(to: file)
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "our bytes")

        let theirs = try #require(try await lab.engine.branches().first { $0.name == "theirs" })
        #expect(try await lab.engine.merge(theirs) == .conflicted)

        let change = try #require(
            try await lab.engine.status().conflicted.first { $0.displayPath == "blob.bin" })

        await #expect(throws: GitError.binaryConflict) {
            _ = try await lab.engine.conflictedContents(for: change)
        }

        // Taking a side still works — that is the only resolution a binary has.
        try await lab.engine.resolve(change, using: .theirs)
        #expect(try await lab.engine.status().hasConflicts == false)
    }
}
