import DiffCore
import Foundation
import Testing

@testable import Grove

/// Reading history out of a real repository.
///
/// The graph *layout* is tested in `DiffCore` against hand-built nodes, because
/// it is arithmetic. These test the half that only git can answer: that the log
/// format parses back, that a rename is one entry rather than two, and that a
/// merge's file list is against its first parent.
@Suite("History")
struct HistoryTests {

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

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeLab() async throws -> Lab {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-history-\(UUID().uuidString)")
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
        return lab
    }

    // MARK: Log

    @Test("reads a linear history newest first, with parents and refs")
    func linearLog() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("a.txt", "one\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "first")
        try lab.write("a.txt", "two\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "second")

        let commits = try await lab.engine.log()
        #expect(commits.count == 2)
        #expect(commits[0].subject == "second")
        #expect(commits[1].subject == "first")

        #expect(commits[0].parents == [commits[1].oid])
        #expect(commits[1].parents.isEmpty)
        #expect(commits[1].isRoot)

        #expect(commits[0].isHead, "%D marks HEAD on the tip")
        #expect(commits[0].displayRefNames.contains("main"))
        #expect(commits[0].authorName == "Grove Test")
        #expect(commits[0].date != nil)
    }

    /// A stash is a merge commit that is not history.
    ///
    /// `--all` includes `refs/stash`, so stashing put two commits nobody wrote
    /// into the list — and because they are merges, they forked the graph rail
    /// into a knot beside them. Grove has a Stashes section; this is the guard
    /// that they stay in it.
    @Test("stashes and Grove's own backup refs stay out of the history")
    func historyExcludesStashesAndBackups() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("a.txt", "one\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "first")

        try lab.write("a.txt", "stash me\n")
        try await lab.git("stash", "push", "-m", "work in progress")

        // The shape of a ref Grove writes before a discard, so it can be undone.
        let head = try await lab.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try await lab.git("update-ref", "refs/grove/backup/1234567890", head)

        let commits = try await lab.engine.log()
        #expect(commits.count == 1, "only the real commit")
        #expect(!commits.contains { $0.subject.hasPrefix("WIP on") })
        #expect(!commits.contains { $0.subject.hasPrefix("index on") })
    }

    /// The badge colours are driven by the ref's kind, so the kind has to come
    /// from the ref's full path. With short decoration a local `feature/login`
    /// and a remote `origin/main` are the same string.
    @Test("refs are classified into HEAD, branches, tags and remotes")
    func refClassification() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("a.txt", "one\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "first")
        try await lab.git("tag", "v1.0.0")
        try await lab.git("branch", "feature/login")

        let head = try #require(try await lab.engine.log().first)
        let kinds = Dictionary(grouping: head.refs, by: \.kind).mapValues { $0.map(\.name) }

        #expect(kinds[.head] == ["HEAD"], "HEAD is its own badge, not merged into the branch")
        #expect(kinds[.branch]?.sorted() == ["feature/login", "main"])
        #expect(
            kinds[.tag] == ["v1.0.0"],
            "a tag keeps its name without git's `tag: ` prefix")
        #expect(
            kinds[.branch]?.contains("feature/login") == true,
            "a slash in a local branch must not make it a remote")
    }

    /// A subject is free text. It must not be able to end a record early or
    /// swallow the next one.
    @Test("a subject full of punctuation survives the round trip")
    func awkwardSubject() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        let subject = #"fix: "quoted", \escaped\, a|pipe, a,comma and a %H"#
        try lab.write("a.txt", "one\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", subject)

        let commits = try await lab.engine.log()
        #expect(commits.count == 1)
        #expect(commits[0].subject == subject)
    }

    @Test("an empty repository has no history rather than an error")
    func unbornRepository() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }
        #expect(try await lab.engine.log().isEmpty)
    }

    @Test("paging walks the whole history without repeating or skipping")
    func paging() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        for index in 0..<7 {
            try lab.write("a.txt", "v\(index)\n")
            try await lab.git("add", "-A")
            try await lab.git("commit", "-m", "commit \(index)")
        }

        let first = try await lab.engine.log(limit: 3, skip: 0)
        let second = try await lab.engine.log(limit: 3, skip: 3)
        let third = try await lab.engine.log(limit: 3, skip: 6)

        #expect(first.count == 3)
        #expect(second.count == 3)
        #expect(third.count == 1, "a short page is the end of history")

        let all = (first + second + third).map(\.oid)
        #expect(Set(all).count == 7, "no commit appears twice")
        #expect(all == (try await lab.engine.log(limit: 100)).map(\.oid))
    }

    // MARK: Graph shape from a real merge

    @Test("a real merge lays out as two columns that rejoin")
    func mergeGraph() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("a.txt", "base\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "base")

        try await lab.git("switch", "--create", "feature")
        try lab.write("b.txt", "feature\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "feature work")

        try await lab.git("switch", "main")
        try lab.write("c.txt", "main\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "main work")
        try await lab.git("merge", "--no-ff", "--no-edit", "feature")

        let commits = try await lab.engine.log()
        let rows = CommitGraph.layout(
            commits.map { CommitGraphNode(id: $0.oid, parents: $0.parents) })

        #expect(commits[0].isMerge)
        #expect(commits[0].parents.count == 2)
        #expect(rows[0].lane == 0, "the merge sits on its first parent's line")
        #expect(rows.map(\.width).max() == 2, "one branch means exactly one extra column")

        // The root is where both sides meet again. Its row is still two columns
        // wide — the two lines have to *arrive* somewhere — and both of them
        // land on its dot.
        let root = try #require(rows.last)
        #expect(root.lane == 0)
        let arriving = root.links.filter { $0.touchesCommit && $0.to == 0 }
        #expect(arriving.count == 2, "both branches converge on the common ancestor")
    }

    // MARK: Files in a commit

    @Test("reads what a commit touched, with adds, edits and deletes told apart")
    func commitChanges() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("keep.txt", "one\n")
        try lab.write("gone.txt", "bye\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "base")

        try lab.write("keep.txt", "two\n")
        try lab.write("fresh.txt", "new\n")
        try FileManager.default.removeItem(at: lab.root.appending(path: "gone.txt"))
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "second")

        let head = try await lab.engine.log()[0]
        let changes = try await lab.engine.commitChanges(head.oid)

        #expect(changes.count == 3)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.displayPath, $0) })
        #expect(byPath["keep.txt"]?.indexStatus == .modified)
        #expect(byPath["fresh.txt"]?.indexStatus == .added)
        #expect(byPath["gone.txt"]?.indexStatus == .deleted)
    }

    /// A rename is three NUL records, not two. Advancing by two reads the new
    /// path as the next status and loses sync for the rest of the commit.
    @Test("a rename is one entry carrying both paths")
    func renameIsOneEntry() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("old.txt", "contents that stay exactly the same\n")
        try lab.write("other.txt", "unrelated\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "base")

        try await lab.git("mv", "old.txt", "new.txt")
        try lab.write("other.txt", "touched\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "rename")

        let head = try await lab.engine.log()[0]
        let changes = try await lab.engine.commitChanges(head.oid)

        #expect(changes.count == 2, "the row after the rename must still be read")
        let renamed = try #require(changes.first { $0.displayPath == "new.txt" })
        #expect(renamed.indexStatus == .renamed)
        #expect(renamed.originalDisplayPath == "old.txt")
        #expect(changes.contains { $0.displayPath == "other.txt" })
    }

    @Test("a file's diff inside a commit is that commit's change, not the working copy's")
    func commitDiff() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("a.txt", "one\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "first")
        try lab.write("a.txt", "two\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "second")

        // The working copy moves on; the commit's diff must not.
        try lab.write("a.txt", "three\n")

        let head = try await lab.engine.log()[0]
        let change = try #require(try await lab.engine.commitChanges(head.oid).first)
        let patch = try await lab.engine.commitDiff(for: change, in: head.oid)

        #expect(patch.contains("-one"))
        #expect(patch.contains("+two"))
        #expect(!patch.contains("three"))
    }

    @Test("the full message comes back with its body, not just the subject")
    func fullMessage() async throws {
        let lab = try await makeLab()
        defer { lab.tearDown() }

        try lab.write("a.txt", "one\n")
        try await lab.git("add", "-A")
        try await lab.git("commit", "-m", "subject line", "-m", "a body paragraph")

        let head = try await lab.engine.log()[0]
        #expect(head.subject == "subject line")

        let message = try await lab.engine.commitMessage(head.oid)
        #expect(message.contains("subject line"))
        #expect(message.contains("a body paragraph"))
    }
}
