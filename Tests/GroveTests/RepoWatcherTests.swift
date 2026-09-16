import Foundation
import Testing

@testable import Grove

/// Live refresh, in two halves.
///
/// The filter is a pure function over paths and is tested as one — that is where
/// every decision worth making lives. The stream itself gets a single end-to-end
/// test, because the only thing worth asserting about it is that a real write to
/// a real directory really arrives.
@Suite("Repository watching")
struct RepoWatcherTests {

    private static let alpha = WatchedRepository(
        id: RepoID(path: "/w/alpha"),
        root: "/w/alpha",
        gitPath: "/w/alpha/.git"
    )

    /// A submodule: its root sits *inside* alpha's, and its `.git` is somewhere
    /// else entirely. Both are why attribution cannot be a first match.
    private static let nested = WatchedRepository(
        id: RepoID(path: "/w/alpha/vendor/lib"),
        root: "/w/alpha/vendor/lib",
        gitPath: "/w/alpha/.git/modules/lib"
    )

    private var all: [WatchedRepository] { [Self.alpha, Self.nested] }

    // MARK: Inside .git

    @Test(
        "the files that change what git status prints get through",
        arguments: [
            "/w/alpha/.git/HEAD",
            "/w/alpha/.git/index",
            "/w/alpha/.git/packed-refs",
            "/w/alpha/.git/MERGE_HEAD",
            "/w/alpha/.git/ORIG_HEAD",
            "/w/alpha/.git/CHERRY_PICK_HEAD",
            "/w/alpha/.git/refs/heads/main",
            "/w/alpha/.git/rebase-merge/done",
            "/w/alpha/.git/rebase-apply/next",
        ]
    )
    func allowedInsideGit(_ path: String) {
        #expect(RepoEventFilter.matters(path, in: Self.alpha), "\(path) should refresh")
    }

    /// `index.lock` is the loudest thing on the disk — it appears and vanishes
    /// several times per git command — and it says nothing.
    @Test(
        "git's own churn does not",
        arguments: [
            "/w/alpha/.git/index.lock",
            "/w/alpha/.git/HEAD.lock",
            "/w/alpha/.git/refs/heads/main.lock",
            "/w/alpha/.git/objects/ab/cdef0123456789",
            "/w/alpha/.git/logs/HEAD",
            "/w/alpha/.git/COMMIT_EDITMSG",
            "/w/alpha/.git/FETCH_HEAD",
            "/w/alpha/.git/config",
        ]
    )
    func ignoredInsideGit(_ path: String) {
        #expect(!RepoEventFilter.matters(path, in: Self.alpha), "\(path) should be ignored")
    }

    /// Grove writes these itself, as part of an operation that already refreshes.
    @Test("Grove's own backup refs are not news")
    func ownBackupRefs() {
        #expect(!RepoEventFilter.matters("/w/alpha/.git/refs/grove/backup/1758000000", in: Self.alpha))
    }

    // MARK: Working tree

    @Test("an ordinary edit in the working tree refreshes")
    func workingTreeEdit() {
        #expect(RepoEventFilter.matters("/w/alpha/src/main.swift", in: Self.alpha))
        #expect(RepoEventFilter.matters("/w/alpha/README.md", in: Self.alpha))
    }

    @Test("a path outside the repository does not")
    func outside() {
        #expect(!RepoEventFilter.matters("/w/beta/src/main.swift", in: Self.alpha))
        // A sibling whose name merely starts the same way.
        #expect(!RepoEventFilter.matters("/w/alpha-old/src/main.swift", in: Self.alpha))
    }

    // MARK: Attribution

    @Test("the longest matching path wins, so a submodule is not read as its parent")
    func nestedRepository() {
        #expect(
            RepoEventFilter.affected(by: "/w/alpha/vendor/lib/src/x.c", in: all) == Self.nested.id)
        #expect(RepoEventFilter.affected(by: "/w/alpha/src/x.c", in: all) == Self.alpha.id)
    }

    @Test("a submodule's git directory lives under its parent's, and still belongs to it")
    func nestedGitDirectory() {
        #expect(
            RepoEventFilter.affected(by: "/w/alpha/.git/modules/lib/HEAD", in: all)
                == Self.nested.id)
        #expect(RepoEventFilter.affected(by: "/w/alpha/.git/HEAD", in: all) == Self.alpha.id)
    }

    /// Without this, every repository nested inside the workspace would refresh
    /// its parent every time git touched its own bookkeeping.
    @Test("an untracked repository's .git inside the working tree is ignored")
    func foreignGitDirectory() {
        #expect(!RepoEventFilter.matters("/w/alpha/vendor/other/.git/index", in: Self.alpha))
        #expect(RepoEventFilter.affected(by: "/w/alpha/vendor/other/.git/index", in: all) == nil)
    }

    @Test("a path belonging to nothing we watch is dropped")
    func unknownPath() {
        #expect(RepoEventFilter.affected(by: "/Users/someone/Desktop/notes.txt", in: all) == nil)
    }

    // MARK: The stream itself

    /// Collects what the watcher delivers, on the main actor where it arrives.
    @MainActor
    private final class Collector {
        var received: Set<RepoID> = []

        func waitForChange(_ timeout: Duration) async -> Set<RepoID> {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if !received.isEmpty { return received }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return received
        }
    }

    /// One end-to-end pass over a real directory.
    ///
    /// Both halves matter, and the order is the point: the quiet half proves the
    /// filter holds, and the loud half that follows proves the watcher was alive
    /// the whole time — otherwise a stream that never started would pass the
    /// quiet half perfectly.
    @Test("ignores git's churn, then reports a real edit")
    func endToEnd() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-watch-\(UUID().uuidString)")
        let gitPath = root.appending(path: ".git")
        try FileManager.default.createDirectory(at: gitPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = Repository(
            root: root, gitPath: gitPath, kind: .standard, depth: 0)

        let collector = Collector()
        let watcher = RepoWatcher { changed in
            collector.received.formUnion(changed)
        }
        defer { watcher.stop() }

        watcher.watch([repository])
        // FSEvents arms asynchronously; writing immediately can beat it.
        try await Task.sleep(for: .milliseconds(400))

        try "".write(to: gitPath.appending(path: "index.lock"), atomically: true, encoding: .utf8)
        try "x".write(to: gitPath.appending(path: "COMMIT_EDITMSG"), atomically: true, encoding: .utf8)

        // Latency (0.2 s) plus debounce (0.3 s) plus room on a loaded machine.
        _ = await collector.waitForChange(.milliseconds(1500))
        #expect(collector.received.isEmpty, "lock files and git's scratch must not refresh")

        try "hello".write(to: root.appending(path: "file.txt"), atomically: true, encoding: .utf8)

        let changed = await collector.waitForChange(.seconds(6))
        #expect(changed.contains(repository.id), "a real edit must reach the watcher")
    }
}
