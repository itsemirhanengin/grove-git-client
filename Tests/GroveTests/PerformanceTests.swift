import Foundation
import Testing

@testable import Grove

/// Performance gates against the generated `perf` fixture.
///
/// The thresholds are **configuration-aware**, because the difference is not
/// marginal: parsing the 2,000-entry status takes 0.65 ms with optimisations and
/// 24.6 ms at `-Onone`, a 38× spread. A single threshold either fails constantly
/// in Debug — where tests actually run — or is so loose it catches nothing in
/// Release. Both are set to roughly 3× the measured value, so they catch an
/// order-of-magnitude regression without failing on a busy machine.
@Suite("Performance gates")
struct PerformanceTests {

    /// Measured 2026-09-16 on an M-series Mac, best of 5.
    /// Release: 0.65 ms · Debug: 24.6 ms.
    private var statusParseBudgetMilliseconds: Double {
        #if DEBUG
            70
        #else
            2
        #endif
    }

    /// Measured: 0.5 ms Release, 0.8 ms Debug. Dominated by directory I/O rather
    /// than by Swift, so the spread is small.
    private var discoveryBudgetMilliseconds: Double { 250 }

    nonisolated static var perfFixtureAvailable: Bool {
        FileManager.default.fileExists(
            atPath: GitRunnerTests.fixtures.appending(path: "perf/.git").path())
    }

    private var perfRepo: URL { GitRunnerTests.fixtures.appending(path: "perf") }

    private func elapsed(_ body: () throws -> Void) rethrows -> Duration {
        let start = ContinuousClock.now
        try body()
        return ContinuousClock.now - start
    }

    @Test(
        "status of 2,000 dirty files parses well under a frame",
        .enabled(if: PerformanceTests.perfFixtureAvailable),
        .timeLimit(.minutes(1))
    )
    func parseLargeStatus() async throws {
        let runner = GitRunner(environment: await GitEnvironment.resolve())
        let result = try await runner.read(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            in: perfRepo
        )
        #expect(result.didSucceed)
        #expect(result.stdout.count > 200_000, "fixture looks too small to be a real test")

        // Parse it several times and take the best, so a noisy machine does not
        // decide the outcome.
        var best = Duration.seconds(60)
        var parsed = RepoStatus.empty
        for _ in 0..<5 {
            let time = elapsed { parsed = StatusParser.parse(result.stdout) }
            best = min(best, time)
        }

        #expect(parsed.changes.count >= 2000)

        let milliseconds = Double(best.components.attoseconds) / 1e15
            + Double(best.components.seconds) * 1000
        #expect(
            milliseconds < statusParseBudgetMilliseconds,
            """
            parsing 2,000 entries took \(String(format: "%.2f", milliseconds)) ms,             budget \(statusParseBudgetMilliseconds) ms
            """
        )
    }

    @Test(
        "discovery of a workspace containing the perf repo stays fast",
        .enabled(if: PerformanceTests.perfFixtureAvailable),
        .timeLimit(.minutes(1))
    )
    func discoveryStaysFast() async {
        // The perf repo holds 2,000 files in one directory; discovery must not
        // pay for them, because it stops descending at `.git`.
        var best = Duration.seconds(60)
        var found: [Repository] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            found = await RepoDiscovery.scan(root: GitRunnerTests.fixtures)
            best = min(best, ContinuousClock.now - start)
        }

        #expect(found.count >= 5, "expected the perf repo alongside the others")

        let milliseconds = Double(best.components.attoseconds) / 1e15
            + Double(best.components.seconds) * 1000
        #expect(
            milliseconds < discoveryBudgetMilliseconds,
            "scanning took \(String(format: "%.1f", milliseconds)) ms"
        )
    }

    /// The whole point of the 300-row cap: a repository with thousands of
    /// changes must not hand the sidebar thousands of rows to lay out.
    @Test(
        "a huge repository is capped before it reaches the view",
        .enabled(if: PerformanceTests.perfFixtureAvailable)
    )
    @MainActor
    func hugeRepositoryIsCapped() async throws {
        let environment = await GitEnvironment.resolve()
        let runner = GitRunner(environment: environment)
        let limiter = GitTaskLimiter(capacity: 4)

        let repository = Repository(
            root: perfRepo,
            gitPath: perfRepo.appending(path: ".git"),
            kind: .standard,
            depth: 1
        )
        let model = RepoViewModel(
            repository: repository,
            engine: RepoEngine(repository: repository, runner: runner, limiter: limiter)
        )
        await model.refreshAndWait()

        #expect(model.loadState == .ready)
        #expect(model.status.changes.count >= 2000)

        // The full truth is still available…
        #expect(model.dirtyCount >= 2000)
        // …but what the list renders is bounded.
        #expect(model.displayedUnstaged.count <= RepoViewModel.displayRowCap)
        #expect(model.hasMoreThanDisplayed)
    }
}
