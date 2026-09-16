import Foundation
import Testing

@testable import Grove

/// Integration tests against the generated `Fixtures/` workspace.
///
/// These run actual `git`, on purpose: the whole backend is a bet that shelling
/// out is more faithful than a library, and the fixtures cover the cases that
/// break naive clients — a rename, a staged-and-dirty file, a live merge
/// conflict, and a repository with no commits at all.
///
/// Build them with `scripts/make-fixtures.sh`; without them these tests report
/// as skipped rather than passing vacuously.
@Suite("GitRunner against Fixtures")
struct GitRunnerTests {

    /// The generated workspace at `<project>/Fixtures`, built by
    /// `scripts/make-fixtures.sh`.
    ///
    /// Located from `#filePath` rather than a hardcoded home-relative path, so
    /// the tests follow the checkout instead of depending on where it happens to
    /// live. `GROVE_FIXTURES` overrides it for CI.
    nonisolated static let fixtures: URL = {
        if let override = ProcessInfo.processInfo.environment["GROVE_FIXTURES"] {
            return URL(filePath: override)
        }
        return URL(filePath: #filePath)
            .deletingLastPathComponent()  // GroveTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // project root
            .appending(path: "Fixtures")
    }()

    /// `nonisolated` because `.enabled(if:)` evaluates its condition from a
    /// Sendable closure, outside the main actor this module defaults to.
    nonisolated static var fixturesAvailable: Bool {
        FileManager.default.fileExists(atPath: fixtures.appending(path: "alpha").path())
    }

    private func repo(_ name: String) -> URL {
        Self.fixtures.appending(path: name)
    }

    private func makeRunner() async -> GitRunner {
        GitRunner(environment: await GitEnvironment.resolve())
    }

    // MARK: Environment

    @Test("finds a real git and a usable PATH")
    func environment() async throws {
        let env = await GitEnvironment.resolve()

        #expect(FileManager.default.isExecutableFile(atPath: env.executable.path()))
        #expect(env.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env.environment["LC_ALL"] == "C")
        // The user's own config must still apply — that is why we shell out.
        #expect(env.environment["GIT_CONFIG_NOSYSTEM"] == nil)

        let path = try #require(env.environment["PATH"])
        #expect(!path.isEmpty)
    }

    @Test("runs git --version")
    func version() async throws {
        let runner = await makeRunner()
        let result = try await runner.read(["--version"], in: URL(filePath: NSTemporaryDirectory()))

        #expect(result.didSucceed)
        #expect(String(decoding: result.stdout, as: UTF8.self).hasPrefix("git version"))
    }

    // MARK: Status

    @Test(
        "reads every status kind from the alpha fixture",
        .enabled(if: GitRunnerTests.fixturesAvailable)
    )
    func alphaStatus() async throws {
        let runner = await makeRunner()
        let result = try await runner.read(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            in: repo("alpha")
        )
        #expect(result.didSucceed)

        let records = result.nulSeparatedRecords.map { String(decoding: $0, as: UTF8.self) }

        #expect(records.contains { $0 == "# branch.head main" })

        // A modified-in-worktree file.
        #expect(records.contains { $0.hasPrefix("1 .M") && $0.hasSuffix("VenueDetail.js") })
        // Staged and then modified again — this file must appear in BOTH lists.
        #expect(records.contains { $0.hasPrefix("1 MM") && $0.hasSuffix("tr.json") })
        // A deletion.
        #expect(records.contains { $0.hasPrefix("1 .D") && $0.hasSuffix("remove-me.js") })
        // An untracked file.
        #expect(records.contains { $0 == "? src/config.js" })

        // A rename is a type-2 record whose ORIGINAL path is the next NUL record.
        let renameIndex = try #require(records.firstIndex { $0.hasPrefix("2 R.") })
        #expect(records[renameIndex].hasSuffix("src/helpers.js"))
        #expect(records[renameIndex + 1] == "src/legacy.js")
    }

    @Test(
        "sees the live merge conflict in gamma",
        .enabled(if: GitRunnerTests.fixturesAvailable)
    )
    func gammaConflict() async throws {
        let runner = await makeRunner()
        let status = try await runner.read(
            ["status", "--porcelain=v2", "--branch", "-z"], in: repo("gamma")
        )
        let records = status.nulSeparatedRecords.map { String(decoding: $0, as: UTF8.self) }

        // Any `u` record means the repository is conflicted.
        let unmerged = try #require(records.first { $0.hasPrefix("u ") })
        #expect(unmerged.hasSuffix("auth.ts"))
        #expect(unmerged.hasPrefix("u UU"))

        // All three sides must be readable for the conflict resolver.
        for stage in 1...3 {
            let side = try await runner.read(["show", ":\(stage):auth.ts"], in: repo("gamma"))
            #expect(side.didSucceed)
            #expect(!side.stdout.isEmpty)
        }
    }

    @Test(
        "handles delta, which has no commits at all",
        .enabled(if: GitRunnerTests.fixturesAvailable)
    )
    func deltaUnbornHead() async throws {
        let runner = await makeRunner()

        let status = try await runner.read(
            ["status", "--porcelain=v2", "--branch", "-z"], in: repo("delta")
        )
        let records = status.nulSeparatedRecords.map { String(decoding: $0, as: UTF8.self) }
        #expect(records.contains { $0 == "# branch.oid (initial)" })

        // The edge case: HEAD does not resolve, and anything diffing against it
        // must take a different path rather than surfacing a fatal error.
        let head = try await runner.read(["rev-parse", "HEAD"], in: repo("delta"))
        #expect(!head.didSucceed)
        #expect(head.stderrText.contains("ambiguous argument 'HEAD'"))
    }

    @Test(
        "reads ahead/behind for beta without an extra process",
        .enabled(if: GitRunnerTests.fixturesAvailable)
    )
    func betaAheadBehind() async throws {
        let runner = await makeRunner()
        let status = try await runner.read(
            ["status", "--porcelain=v2", "--branch", "-z"], in: repo("beta")
        )
        let records = status.nulSeparatedRecords.map { String(decoding: $0, as: UTF8.self) }

        #expect(records.contains { $0 == "# branch.upstream origin/master" })
        #expect(records.contains { $0 == "# branch.ab +1 -0" })
    }

    @Test("reports a clear failure outside a repository")
    func notARepository() async throws {
        let runner = await makeRunner()
        let result = try await runner.read(
            ["status", "--porcelain=v2"], in: URL(filePath: NSTemporaryDirectory())
        )

        #expect(!result.didSucceed)
        #expect(result.stderrText.contains("not a git repository"))
    }

    // MARK: Concurrency

    @Test(
        "refreshes all fixture repos concurrently",
        .enabled(if: GitRunnerTests.fixturesAvailable),
        .timeLimit(.minutes(1))
    )
    func concurrentRefresh() async throws {
        let runner = await makeRunner()
        let names = ["alpha", "beta", "gamma", "delta"]

        let statuses = try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            for name in names {
                group.addTask {
                    let r = try await runner.read(
                        ["status", "--porcelain=v2", "--branch", "-z"], in: repo(name)
                    )
                    return (name, r.didSucceed)
                }
            }
            var out: [String: Bool] = [:]
            for try await (name, ok) in group { out[name] = ok }
            return out
        }

        #expect(statuses.count == 4)
        for name in names { #expect(statuses[name] == true) }
    }
}
