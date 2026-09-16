import DiffCore
import Foundation
import Testing

@testable import Grove

/// Line and chunk staging, end to end through real `git apply`.
///
/// The unit tests in `DiffCore` prove the patch *text* is what it should be.
/// These prove git accepts it — which is the only claim that matters, and the
/// one a string comparison cannot make. Every repository here is built from
/// scratch by git rather than copied from the fixtures, because these need a
/// file with several hunks in it and the fixtures are deliberately small.
@Suite("Partial staging")
struct PartialStagingTests {

    // MARK: Scaffolding

    /// A throwaway repository with one committed file and an engine over it.
    private struct Lab {
        var engine: RepoEngine
        var root: URL
        var runner: GitRunner

        func write(_ name: String, _ contents: String) throws {
            try contents.write(
                to: root.appending(path: name), atomically: true, encoding: .utf8)
        }

        func read(_ name: String) throws -> String {
            try String(contentsOf: root.appending(path: name), encoding: .utf8)
        }

        @discardableResult
        func git(_ arguments: String...) async throws -> String {
            let result = try await runner.write(arguments, in: root)
            #expect(result.didSucceed, "git \(arguments.joined(separator: " ")) failed")
            return String(decoding: result.stdout, as: UTF8.self)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeLab() async throws -> Lab {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let environment = await GitEnvironment.resolve()
        let runner = GitRunner(environment: environment)
        let repository = Repository(
            root: root,
            gitPath: root.appending(path: ".git"),
            kind: .standard,
            depth: 0
        )
        let lab = Lab(
            engine: RepoEngine(
                repository: repository, runner: runner,
                limiter: GitTaskLimiter(capacity: 4)),
            root: root,
            runner: runner
        )

        try await lab.git("init", "--initial-branch=main")
        try await lab.git("config", "user.email", "grove@test.invalid")
        try await lab.git("config", "user.name", "Grove Test")
        return lab
    }

    /// `line 1` … `line 30`, committed.
    private func seedThirtyLines(_ lab: Lab) async throws {
        let contents = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try lab.write("multi.txt", contents)
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "seed")
    }

    /// Three separate edits, so `git diff` produces three hunks.
    private func editThreeSpots(_ lab: Lab) throws {
        var lines = (1...30).map { "line \($0)" }
        lines[2] = "line 3 CHANGED"
        lines.insert("inserted after 10", at: 10)
        lines[20] = "line 20 CHANGED"
        try lab.write("multi.txt", lines.joined(separator: "\n") + "\n")
    }

    private func change(_ status: RepoStatus, _ suffix: String) throws -> FileChange {
        try #require(status.changes.first { $0.displayPath.hasSuffix(suffix) })
    }

    // MARK: Chunks

    @Test("stages one chunk of three and leaves the other two alone")
    func stageOneChunk() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        try await seedThirtyLines(lab)
        try editThreeSpots(lab)

        var status = try await lab.engine.status()
        let file = try change(status, "multi.txt")

        let diff = try await lab.engine.diff(for: file, staged: false)
        let parsed = UnifiedPatchParser.parse(diff)[0]
        #expect(parsed.hunks.count == 3)

        // The middle chunk — the pure insertion. Picking it alone is what makes
        // the third chunk's `+start` wrong if the header arithmetic is.
        try await lab.engine.applyPartial(
            diff: diff,
            selection: .wholeHunks([parsed.hunks[1]]),
            operation: .stage
        )

        status = try await lab.engine.status()
        let after = try change(status, "multi.txt")
        #expect(after.isStaged && after.isUnstaged, "one chunk staged, two still dirty")

        let staged = try await lab.engine.diff(for: after, staged: true)
        #expect(staged.contains("+inserted after 10"))
        #expect(!staged.contains("line 3 CHANGED"))
        #expect(!staged.contains("line 20 CHANGED"))

        // The working tree is untouched: staging moves work into the index and
        // nowhere else.
        let onDisk = try lab.read("multi.txt")
        #expect(onDisk.contains("line 3 CHANGED"))
        #expect(onDisk.contains("line 20 CHANGED"))
    }

    @Test("staging the last chunk alone re-bases its +start correctly")
    func stageLastChunk() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        try await seedThirtyLines(lab)
        try editThreeSpots(lab)

        let status = try await lab.engine.status()
        let file = try change(status, "multi.txt")
        let diff = try await lab.engine.diff(for: file, staged: false)
        let parsed = UnifiedPatchParser.parse(diff)[0]

        // In git's output this hunk starts at +18, because an earlier hunk
        // inserted a line. On its own it starts at +17, and a patch that still
        // claims +18 is the classic off-by-one that `--check` catches.
        try await lab.engine.applyPartial(
            diff: diff, selection: .wholeHunks([parsed.hunks[2]]), operation: .stage)

        let after = try change(try await lab.engine.status(), "multi.txt")
        let staged = try await lab.engine.diff(for: after, staged: true)
        #expect(staged.contains("+line 20 CHANGED"))
        #expect(staged.contains("@@ -17,7 +17,7 @@"))
    }

    // MARK: Individual lines

    @Test("stages one side of a changed line, leaving the other side dirty")
    func stageOneLine() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        try await seedThirtyLines(lab)
        try editThreeSpots(lab)

        let status = try await lab.engine.status()
        let file = try change(status, "multi.txt")
        let diff = try await lab.engine.diff(for: file, staged: false)

        // Only the `-line 3` half of the pair: the index should lose line 3
        // without gaining its replacement.
        try await lab.engine.applyPartial(
            diff: diff, selection: PatchSelection(deletions: [3]), operation: .stage)

        let after = try change(try await lab.engine.status(), "multi.txt")
        let staged = try await lab.engine.diff(for: after, staged: true)
        #expect(staged.contains("-line 3\n"))
        #expect(!staged.contains("+line 3 CHANGED"))
    }

    @Test("unstages one line, mirrored — the index keeps what was not picked")
    func unstageOneLine() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        try await seedThirtyLines(lab)
        try editThreeSpots(lab)
        try await lab.git("add", "multi.txt")

        var status = try await lab.engine.status()
        var file = try change(status, "multi.txt")
        #expect(file.isStaged && !file.isUnstaged)

        // Unstage the middle chunk's insertion only, from the *staged* diff.
        let staged = try await lab.engine.diff(for: file, staged: true)
        try await lab.engine.applyPartial(
            diff: staged,
            selection: PatchSelection(additions: [11]),
            operation: .unstage
        )

        status = try await lab.engine.status()
        file = try change(status, "multi.txt")
        #expect(file.isStaged, "the other two chunks are still staged")
        #expect(file.isUnstaged, "the unstaged one is dirty again")

        let remaining = try await lab.engine.diff(for: file, staged: true)
        #expect(!remaining.contains("inserted after 10"))
        #expect(remaining.contains("+line 3 CHANGED"))
        #expect(remaining.contains("+line 20 CHANGED"))

        // And it is back in the working-tree diff, not lost.
        let dirty = try await lab.engine.diff(for: file, staged: false)
        #expect(dirty.contains("+inserted after 10"))
    }

    // MARK: Discard

    @Test("discards one chunk from the working tree, and leaves a backup ref")
    func discardOneChunk() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        try await seedThirtyLines(lab)
        try editThreeSpots(lab)

        let status = try await lab.engine.status()
        let file = try change(status, "multi.txt")
        let diff = try await lab.engine.diff(for: file, staged: false)
        let parsed = UnifiedPatchParser.parse(diff)[0]

        let backup = try await lab.engine.applyPartial(
            diff: diff, selection: .wholeHunks([parsed.hunks[0]]), operation: .discard)

        let onDisk = try lab.read("multi.txt")
        #expect(!onDisk.contains("line 3 CHANGED"), "the picked chunk is gone")
        #expect(onDisk.contains("line 3\n"))
        #expect(onDisk.contains("inserted after 10"), "the others are untouched")
        #expect(onDisk.contains("line 20 CHANGED"))

        // The one operation that can lose work always leaves a way back.
        let ref = try #require(backup)
        #expect(ref.hasPrefix("refs/grove/backup/"))
        let shown = try await lab.git("rev-parse", "--verify", ref)
        #expect(!shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: Awkward files

    @Test("stages a line out of a CRLF file without eating the carriage return")
    func crlf() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("crlf.txt", "alpha\r\nbeta\r\ngamma\r\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "seed")
        try lab.write("crlf.txt", "alpha\r\nBETA\r\ngamma\r\n")

        let file = try change(try await lab.engine.status(), "crlf.txt")
        let diff = try await lab.engine.diff(for: file, staged: false)

        // Nothing but `--check` stands between a dropped `\r` and a patch that
        // does not apply, so this failing is the signal that it was dropped.
        try await lab.engine.applyPartial(
            diff: diff, selection: PatchSelection(additions: [2]), operation: .stage)

        let after = try change(try await lab.engine.status(), "crlf.txt")
        let staged = try await lab.engine.diff(for: after, staged: true)
        // `"\r\n"` is one Character in Swift, so searching for a bare `"\r"`
        // never matches inside CRLF text — the same grapheme trap that makes
        // `split(separator: "\n")` unusable in the parser.
        #expect(staged.contains("+BETA\r\n"))
    }

    @Test("takes a whole chunk from a file with no trailing newline")
    func noTrailingNewline() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("noeol.txt", "one\ntwo\nthree")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "seed")
        try lab.write("noeol.txt", "one\nTWO\nthree changed")

        let file = try change(try await lab.engine.status(), "noeol.txt")
        let diff = try await lab.engine.diff(for: file, staged: false)
        let parsed = UnifiedPatchParser.parse(diff)[0]

        try await lab.engine.applyPartial(
            diff: diff, selection: .wholeHunks(parsed.hunks), operation: .stage)

        let after = try change(try await lab.engine.status(), "noeol.txt")
        #expect(after.isStaged && !after.isUnstaged)
    }

    @Test("refuses to split a chunk whose last line owns a no-newline marker")
    func noTrailingNewlineIsNotSplittable() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("noeol.txt", "one\ntwo\nthree")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "seed")
        try lab.write("noeol.txt", "one\nTWO\nthree changed")

        let file = try change(try await lab.engine.status(), "noeol.txt")
        let diff = try await lab.engine.diff(for: file, staged: false)

        await #expect(throws: GitError.cannotSplitPatch(.noNewlineNotSplittable)) {
            try await lab.engine.applyPartial(
                diff: diff, selection: PatchSelection(additions: [2, 3]), operation: .stage)
        }
    }

    @Test("stages part of a brand new, untracked file")
    func partOfANewFile() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        try await seedThirtyLines(lab)

        try lab.write("fresh.txt", "first\nsecond\nthird\n")

        let file = try change(try await lab.engine.status(), "fresh.txt")
        #expect(file.kind == .untracked)

        // An untracked file's diff comes from `--no-index` against /dev/null.
        // Its header says `new file mode`, and the old side stays empty however
        // few lines are picked — so a forward partial is legitimate here.
        let diff = try await lab.engine.diff(for: file, staged: false)
        try await lab.engine.applyPartial(
            diff: diff, selection: PatchSelection(additions: [1, 2]), operation: .stage)

        let after = try change(try await lab.engine.status(), "fresh.txt")
        #expect(after.isStaged)
        let staged = try await lab.engine.diff(for: after, staged: true)
        #expect(staged.contains("+first"))
        #expect(staged.contains("+second"))
        #expect(!staged.contains("+third"))
    }

    // MARK: Staleness

    /// Note what is *not* tested here: editing the working tree does not
    /// invalidate a staging selection. `git apply --cached` reads the patch and
    /// the index, and the patch already holds the exact lines the user picked —
    /// so the index gets what was asked for whatever the file does afterwards.
    @Test("refuses to stage when the index has moved past the diff")
    func staleIndexIsRejected() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        try await seedThirtyLines(lab)
        try editThreeSpots(lab)

        let file = try change(try await lab.engine.status(), "multi.txt")
        let diff = try await lab.engine.diff(for: file, staged: false)

        // Something else stages the whole file — a terminal, another pane. The
        // old side of the selection is no longer what the index holds.
        try await lab.git("add", "multi.txt")

        await #expect(throws: (any Error).self) {
            try await lab.engine.applyPartial(
                diff: diff, selection: PatchSelection(deletions: [3]), operation: .stage)
        }

        // `--check` ran first, so nothing was half-applied on top of it.
        let after = try change(try await lab.engine.status(), "multi.txt")
        #expect(!after.isUnstaged, "the index is exactly as the other writer left it")
    }

    @Test("refuses to discard when the working tree has moved past the diff")
    func staleWorktreeIsRejected() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        try await seedThirtyLines(lab)
        try editThreeSpots(lab)

        let file = try change(try await lab.engine.status(), "multi.txt")
        let diff = try await lab.engine.diff(for: file, staged: false)

        // A discard targets the working tree, so this is the one that matters:
        // applying a stale selection here would destroy work that is not in the
        // diff the user was looking at.
        try lab.write("multi.txt", "completely different\n")

        await #expect(throws: (any Error).self) {
            try await lab.engine.applyPartial(
                diff: diff, selection: PatchSelection(deletions: [3]), operation: .discard)
        }

        #expect(try lab.read("multi.txt") == "completely different\n")
    }
}
