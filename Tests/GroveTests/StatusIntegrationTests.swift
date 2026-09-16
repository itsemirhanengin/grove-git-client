import Foundation
import Testing

@testable import Grove

/// End-to-end: real `git` output parsed into `RepoStatus`.
///
/// `StatusParserTests` proves the parser handles synthetic records. This suite
/// proves the records it receives from a real git are actually shaped the way
/// those tests assume — which is the half that silently rots when git changes.
@Suite("Status parsing against real repositories")
struct StatusIntegrationTests {

    nonisolated static var fixturesAvailable: Bool { GitRunnerTests.fixturesAvailable }

    private func status(of repoName: String) async throws -> RepoStatus {
        let runner = GitRunner(environment: await GitEnvironment.resolve())
        let result = try await runner.read(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            in: GitRunnerTests.fixtures.appending(path: repoName)
        )
        #expect(result.didSucceed, "git status failed: \(result.stderrText)")
        return StatusParser.parse(result.stdout)
    }

    @Test(
        "alpha parses into every status kind",
        .enabled(if: StatusIntegrationTests.fixturesAvailable)
    )
    func alpha() async throws {
        let status = try await status(of: "alpha")

        #expect(status.branch == "main")
        #expect(!status.isUnborn)
        #expect(!status.hasConflicts)

        func change(_ suffix: String) throws -> FileChange {
            try #require(
                status.changes.first { $0.displayPath.hasSuffix(suffix) },
                "no change for \(suffix) in \(status.changes.map(\.displayPath))"
            )
        }

        // Modified in the worktree only.
        let venue = try change("VenueDetail.js")
        #expect(venue.indexStatus == .unchanged)
        #expect(venue.worktreeStatus == .modified)
        #expect(venue.isUnstaged && !venue.isStaged)

        // Staged only.
        let en = try change("en.json")
        #expect(en.indexStatus == .modified)
        #expect(en.worktreeStatus == .unchanged)
        #expect(en.isStaged && !en.isUnstaged)

        // Staged AND modified again — must be in both lists.
        let tr = try change("tr.json")
        #expect(tr.indexStatus == .modified)
        #expect(tr.worktreeStatus == .modified)
        #expect(tr.isStaged && tr.isUnstaged)

        // Deleted in the worktree.
        let removed = try change("remove-me.js")
        #expect(removed.worktreeStatus == .deleted)

        // Renamed, with the original path recovered from the second record.
        let renamed = try change("helpers.js")
        #expect(renamed.indexStatus == .renamed)
        #expect(renamed.originalDisplayPath == "src/legacy.js")
        #expect(renamed.similarity == 100)

        // Untracked.
        let config = try change("config.js")
        #expect(config.kind == .untracked)
        #expect(config.isUnstaged)

        // The rename's original path must never surface as its own entry.
        #expect(!status.changes.contains { $0.displayPath == "src/legacy.js" })

        #expect(status.changes.count == 6)
        #expect(status.staged.count == 3)  // rename, en.json, tr.json
        #expect(status.dirtyCount == 6)
    }

    @Test(
        "gamma parses as conflicted with all three stages",
        .enabled(if: StatusIntegrationTests.fixturesAvailable)
    )
    func gamma() async throws {
        let status = try await status(of: "gamma")

        #expect(status.hasConflicts)
        #expect(status.conflicted.count == 1)

        let conflict = try #require(status.conflicted.first)
        #expect(conflict.displayPath == "auth.ts")
        #expect(conflict.indexStatus == .unmerged)
        #expect(conflict.worktreeStatus == .unmerged)

        // The three blob ids the conflict resolver reads.
        let stages = try #require(conflict.unmergedStages)
        #expect(stages.base.count == 40)
        #expect(stages.ours.count == 40)
        #expect(stages.theirs.count == 40)
        #expect(stages.base != stages.ours)
        #expect(stages.ours != stages.theirs)

        // And those ids resolve to real, different content.
        let runner = GitRunner(environment: await GitEnvironment.resolve())
        let repo = GitRunnerTests.fixtures.appending(path: "gamma")
        let ours = try await runner.read(["cat-file", "blob", stages.ours], in: repo)
        let theirs = try await runner.read(["cat-file", "blob", stages.theirs], in: repo)

        #expect(ours.didSucceed && theirs.didSucceed)
        #expect(ours.stdout != theirs.stdout)
        #expect(String(decoding: ours.stdout, as: UTF8.self).contains("ttl: 48"))
        #expect(String(decoding: theirs.stdout, as: UTF8.self).contains("ttl: 24"))
    }

    @Test(
        "delta parses as an unborn repository",
        .enabled(if: StatusIntegrationTests.fixturesAvailable)
    )
    func delta() async throws {
        let status = try await status(of: "delta")

        #expect(status.isUnborn)
        #expect(status.headOID == nil)
        #expect(status.branch == "main")
        #expect(status.untracked.count == 1)
        #expect(status.untracked.first?.displayPath == "README.md")
        #expect(status.staged.isEmpty)
    }

    @Test(
        "beta parses its upstream and ahead count",
        .enabled(if: StatusIntegrationTests.fixturesAvailable)
    )
    func beta() async throws {
        let status = try await status(of: "beta")

        #expect(status.branch == "master")
        #expect(status.upstream == "origin/master")
        #expect(status.ahead == 1)
        #expect(status.behind == 0)
        #expect(status.changes.isEmpty)
        #expect(status.dirtyCount == 0)
    }

    /// A filename containing a **newline**, a space and non-ASCII characters.
    ///
    /// This is the hostile case that is actually reachable on macOS. APFS
    /// rejects filenames that are not valid UTF-8 outright (`EILSEQ`), so a
    /// "path with an invalid byte" test cannot exist here — that path is covered
    /// by feeding bytes straight to the parser in `StatusParserTests`. A newline,
    /// however, is perfectly legal in a macOS filename, and git embeds it raw
    /// inside the `-z` record. Anything that reads git's output line by line
    /// splits this single entry into two and corrupts both.
    @Test("parses a path containing a newline, a space and non-ASCII characters")
    func hostileFileName() async throws {
        let scratch = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-hostile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let runner = GitRunner(environment: await GitEnvironment.resolve())
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = try await runner.write(["init", "-q", "-b", "main"], in: scratch)

        let hostileName = "garip dosya\nadı.txt"
        FileManager.default.createFile(
            atPath: scratch.path() + "/" + hostileName,
            contents: Data("hi".utf8)
        )

        let result = try await runner.read(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            in: scratch
        )

        // The newline really is inside the record, not a record separator.
        #expect(result.stdout.contains(UInt8(ascii: "\n")))

        let status = StatusParser.parse(result.stdout)

        // One entry, not two — this is the assertion that fails for a
        // line-based parser.
        #expect(status.untracked.count == 1)
        let untracked = try #require(status.untracked.first)
        #expect(untracked.displayPath == hostileName)
        #expect(untracked.pathBytes == Array(hostileName.utf8))

        // The newline is part of the name, not a separator, so there is no
        // directory component and the whole thing is the file name.
        #expect(untracked.directoryPrefix == "")
        #expect(untracked.fileName == hostileName)

        // For display it must collapse to one line, or this single row would be
        // taller than every other row in the list.
        #expect(untracked.singleLineDisplayPath == "garip dosya␊adı.txt")
        #expect(!untracked.singleLineDisplayPath.contains("\n"))
    }
}
