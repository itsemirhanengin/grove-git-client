import Foundation
import Testing

@testable import Grove

@Suite("RepoDiscovery")
struct RepoDiscoveryTests {

    // MARK: Against the real fixture workspace

    @Test(
        "finds every fixture repository and skips the plain folder",
        .enabled(if: GitRunnerTests.fixturesAvailable)
    )
    func scansFixtures() async {
        let repos = await RepoDiscovery.scan(root: GitRunnerTests.fixtures)
        let names = repos.map(\.name)

        #expect(names.contains("alpha"))
        #expect(names.contains("beta"))
        #expect(names.contains("gamma"))
        #expect(names.contains("delta"))

        // A folder without .git must never appear.
        #expect(!names.contains("not-a-repo"))

        // A bare repository is a directory ending in .git with no worktree, so
        // it is not a working copy and must not be listed as one.
        #expect(!names.contains("beta-remote.git"))

        // Sorted, so the sidebar never reshuffles between scans.
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test(
        "resolves the git directory of an ordinary repository",
        .enabled(if: GitRunnerTests.fixturesAvailable)
    )
    func resolvesGitPath() async {
        let repos = await RepoDiscovery.scan(root: GitRunnerTests.fixtures)
        let alpha = repos.first { $0.name == "alpha" }

        #expect(alpha?.kind == .standard)
        #expect(alpha?.gitPath.lastPathComponent == ".git")
        #expect(alpha?.depth == 1)
    }

    // MARK: Synthetic trees

    private func makeTree(_ build: (URL) throws -> Void) throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func makeRepo(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.appending(path: ".git"), withIntermediateDirectories: true)
    }

    @Test("never descends into pruned directories")
    func prunesNoiseDirectories() async throws {
        let root = try makeTree { root in
            try makeRepo(at: root.appending(path: "real"))
            // A repository hidden inside node_modules must stay hidden — this is
            // the case that makes a scan take minutes instead of milliseconds.
            try makeRepo(at: root.appending(path: "node_modules/some-package"))
            try makeRepo(at: root.appending(path: "build/artifact"))
            try makeRepo(at: root.appending(path: ".venv/lib"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let repos = await RepoDiscovery.scan(root: root)
        #expect(repos.map(\.name) == ["real"])
    }

    @Test("stops descending once a repository is found")
    func doesNotDescendIntoRepositories() async throws {
        let root = try makeTree { root in
            try makeRepo(at: root.appending(path: "outer"))
            // Vendored or submodule content below a repository.
            try makeRepo(at: root.appending(path: "outer/inner"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let repos = await RepoDiscovery.scan(root: root)
        #expect(repos.map(\.name) == ["outer"])

        var config = DiscoveryConfig()
        config.includeNestedRepos = true
        let nested = await RepoDiscovery.scan(root: root, config: config)
        #expect(nested.map(\.name).sorted() == ["inner", "outer"])
    }

    @Test("honours the depth limit")
    func respectsMaxDepth() async throws {
        let root = try makeTree { root in
            try makeRepo(at: root.appending(path: "a/b/c/deep"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        var shallow = DiscoveryConfig()
        shallow.maxDepth = 2
        #expect(await RepoDiscovery.scan(root: root, config: shallow).isEmpty)

        var deep = DiscoveryConfig()
        deep.maxDepth = 4
        #expect(await RepoDiscovery.scan(root: root, config: deep).map(\.name) == ["deep"])
    }

    @Test("finds a repository at the workspace root itself")
    func rootIsARepository() async throws {
        let root = try makeTree { try makeRepo(at: $0) }
        defer { try? FileManager.default.removeItem(at: root) }

        let repos = await RepoDiscovery.scan(root: root)
        #expect(repos.count == 1)
        #expect(repos.first?.depth == 0)
    }

    /// `.git` as a **file** means a linked worktree or a submodule. Resolving it
    /// matters beyond labelling: the merge/rebase marker files live at the
    /// resolved path, so assuming `root/.git` would report "no merge in
    /// progress" in the middle of a conflict.
    @Test("resolves a .git file to a worktree")
    func gitFileWorktree() async throws {
        let root = try makeTree { root in
            let main = root.appending(path: "main-checkout")
            try FileManager.default.createDirectory(
                at: main.appending(path: ".git/worktrees/feature"),
                withIntermediateDirectories: true
            )
            let linked = root.appending(path: "feature-checkout")
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            try "gitdir: \(main.path())/.git/worktrees/feature\n"
                .write(to: linked.appending(path: ".git"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let repos = await RepoDiscovery.scan(root: root)
        let linked = try #require(repos.first { $0.name == "feature-checkout" })

        #expect(linked.kind == .worktree)
        #expect(linked.gitPath.path().hasSuffix("/worktrees/feature"))
    }

    @Test("resolves a relative gitdir in a submodule")
    func gitFileSubmoduleRelative() async throws {
        let root = try makeTree { root in
            let parent = root.appending(path: "parent")
            try FileManager.default.createDirectory(
                at: parent.appending(path: ".git/modules/lib"),
                withIntermediateDirectories: true
            )
            let sub = parent.appending(path: "lib")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            // Git writes this relative, which is the form that breaks naive parsing.
            try "gitdir: ../.git/modules/lib\n"
                .write(to: sub.appending(path: ".git"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        var config = DiscoveryConfig()
        config.includeNestedRepos = true
        let repos = await RepoDiscovery.scan(root: root, config: config)

        let submodule = try #require(repos.first { $0.name == "lib" })
        #expect(submodule.kind == .submodule)
        #expect(submodule.gitPath.path().hasSuffix("/.git/modules/lib"))
    }

    /// Skipping symlinks removes cycle detection, infinite recursion and
    /// duplicate repositories in a single stroke.
    @Test("does not follow symlinks")
    func ignoresSymlinks() async throws {
        let root = try makeTree { root in
            try makeRepo(at: root.appending(path: "real"))
            try FileManager.default.createSymbolicLink(
                at: root.appending(path: "link-to-real"),
                withDestinationURL: root.appending(path: "real")
            )
            // A self-referential link would hang a follower.
            try FileManager.default.createSymbolicLink(
                at: root.appending(path: "loop"),
                withDestinationURL: root
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let repos = await RepoDiscovery.scan(root: root)
        #expect(repos.map(\.name) == ["real"])
    }

    @Test("returns nothing for a folder that does not exist")
    func missingRoot() async {
        let repos = await RepoDiscovery.scan(
            root: URL(filePath: "/nonexistent/\(UUID().uuidString)")
        )
        #expect(repos.isEmpty)
    }

    @Test("honours extra ignores from workspace settings")
    func extraIgnores() async throws {
        let root = try makeTree { root in
            try makeRepo(at: root.appending(path: "keep"))
            try makeRepo(at: root.appending(path: "legacy"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        var config = DiscoveryConfig()
        config.extraIgnores = ["legacy"]
        let repos = await RepoDiscovery.scan(root: root, config: config)
        #expect(repos.map(\.name) == ["keep"])
    }
}

@Suite("GitTaskLimiter")
struct GitTaskLimiterTests {

    @Test("never exceeds its capacity", .timeLimit(.minutes(1)))
    func respectsCapacity() async {
        let limiter = GitTaskLimiter(capacity: 3)
        let counter = ConcurrencyPeak()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await limiter.withSlot {
                        await counter.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        await counter.leave()
                    }
                }
            }
        }

        #expect(await counter.peak <= 3)
        #expect(await counter.peak > 1, "expected some real concurrency")
        #expect(await limiter.availableSlots == 3)
        #expect(await limiter.queueDepth == 0)
    }

    @Test("releases its slot when the body throws")
    func releasesOnThrow() async {
        let limiter = GitTaskLimiter(capacity: 1)
        struct Boom: Error {}

        for _ in 0..<5 {
            _ = try? await limiter.withSlot { throw Boom() }
        }

        // A leaked slot here would permanently wedge the app.
        #expect(await limiter.availableSlots == 1)
        #expect(await limiter.activeCount == 0)
    }
}

/// Tracks the highest observed concurrency.
private actor ConcurrencyPeak {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}
