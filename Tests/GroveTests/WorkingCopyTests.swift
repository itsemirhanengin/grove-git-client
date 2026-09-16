import Foundation
import Testing

@testable import Grove

/// The wiring between the Working Copy buttons and git.
///
/// These call exactly what the buttons call, which is the part `MutationTests`
/// does not cover: `MutationTests` proves the engine does the right thing, this
/// proves the view model asks it to. Driving the real UI instead would mean
/// synthetic clicks against a live window — flaky, and it steals the user's
/// focus.
@Suite("Working Copy actions")
@MainActor
struct WorkingCopyTests {

    nonisolated static var fixturesAvailable: Bool { GitRunnerTests.fixturesAvailable }

    private func makeModel(from fixture: String) async throws -> (RepoViewModel, URL) {
        let source = GitRunnerTests.fixtures.appending(path: fixture)
        let destination = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-wc-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: destination)

        let environment = await GitEnvironment.resolve()
        let repository = Repository(
            root: destination,
            gitPath: destination.appending(path: ".git"),
            kind: .standard,
            depth: 0
        )
        let model = RepoViewModel(
            repository: repository,
            engine: RepoEngine(
                repository: repository,
                runner: GitRunner(environment: environment),
                limiter: GitTaskLimiter(capacity: 4)
            )
        )
        await model.refreshAndWait()
        return (model, destination)
    }

    private func cleanUp(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    // MARK: Staging

    @Test("Stage All moves everything into the index", .enabled(if: WorkingCopyTests.fixturesAvailable))
    func stageAll() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        #expect(!model.status.unstaged.isEmpty)
        #expect(!model.status.untracked.isEmpty)

        model.stageAll()
        await model.waitForOperation()

        #expect(model.status.unstaged.isEmpty)
        #expect(model.status.untracked.isEmpty)
        #expect(!model.status.staged.isEmpty)
        #expect(model.operationError == nil)
    }

    @Test("Unstage All empties the index", .enabled(if: WorkingCopyTests.fixturesAvailable))
    func unstageAll() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        model.stageAll()
        await model.waitForOperation()
        #expect(!model.status.staged.isEmpty)

        model.unstageAll()
        await model.waitForOperation()
        #expect(model.status.staged.isEmpty)
        #expect(model.operationError == nil)
    }

    // MARK: Commit

    @Test("Commit is disabled until there is a message and something staged",
          .enabled(if: WorkingCopyTests.fixturesAvailable))
    func commitEnablement() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        // Staged changes exist in alpha, but no message yet.
        #expect(!model.status.staged.isEmpty)
        #expect(!model.canCommit)

        model.draftMessage = "   "
        #expect(!model.canCommit, "whitespace is not a message")

        model.draftMessage = "feat: something"
        #expect(model.canCommit)

        model.unstageAll()
        await model.waitForOperation()
        #expect(!model.canCommit, "a message with nothing staged is not committable")
    }

    @Test("committing clears the draft", .enabled(if: WorkingCopyTests.fixturesAvailable))
    func commitClearsDraft() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        model.draftMessage = "test: commit from the view model"
        model.commit()
        await model.waitForOperation()

        #expect(model.operationError == nil)
        #expect(model.draftMessage.isEmpty)
        #expect(model.status.staged.isEmpty)
    }

    /// The draft is the user's writing. A rejected commit must not eat it.
    @Test("a failed commit keeps the draft", .enabled(if: WorkingCopyTests.fixturesAvailable))
    func failedCommitKeepsDraft() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        // Nothing staged, so git refuses.
        model.unstageAll()
        await model.waitForOperation()

        model.draftMessage = "this should survive"
        model.commit()
        await model.waitForOperation()

        #expect(model.operationError != nil)
        #expect(model.draftMessage == "this should survive")
    }

    // MARK: Discard

    /// Discard must never happen on the first click.
    @Test("discard asks before it acts", .enabled(if: WorkingCopyTests.fixturesAvailable))
    func discardRequiresConfirmation() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        let venue = try #require(
            model.status.unstaged.first { $0.displayPath.hasSuffix("VenueDetail.js") })
        let path = root.appending(path: venue.displayPath)
        let before = try String(contentsOf: path, encoding: .utf8)

        model.requestDiscard([venue])

        // Nothing has happened yet — only a question is pending.
        #expect(model.pendingDiscard != nil)
        #expect(try String(contentsOf: path, encoding: .utf8) == before)

        model.cancelPendingDiscard()
        #expect(model.pendingDiscard == nil)
        #expect(try String(contentsOf: path, encoding: .utf8) == before)
    }

    @Test("confirming a discard restores the file and reports the backup",
          .enabled(if: WorkingCopyTests.fixturesAvailable))
    func discardConfirmed() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        let venue = try #require(
            model.status.unstaged.first { $0.displayPath.hasSuffix("VenueDetail.js") })

        model.requestDiscard([venue])
        model.confirmPendingDiscard()
        await model.waitForOperation()

        #expect(model.pendingDiscard == nil)
        #expect(model.operationError == nil)

        let receipt = try #require(model.lastDiscard, "the user was told nothing")
        #expect(receipt.outcome.restoredPaths == [venue.displayPath])
        #expect(receipt.outcome.backupRef != nil, "no way to undo was offered")

        #expect(!model.status.changes.contains { $0.displayPath == venue.displayPath })
    }

    @Test("discarding an untracked file reports the Trash",
          .enabled(if: WorkingCopyTests.fixturesAvailable))
    func discardUntrackedReportsTrash() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        let config = try #require(model.status.untracked.first)

        model.requestDiscard([config])
        model.confirmPendingDiscard()
        await model.waitForOperation()

        let receipt = try #require(model.lastDiscard)
        #expect(receipt.outcome.trashedPaths == [config.displayPath])
        #expect(receipt.outcome.failures.isEmpty)
    }

    @Test("the pending discard counts tracked and untracked separately",
          .enabled(if: WorkingCopyTests.fixturesAvailable))
    func pendingDiscardCounts() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        let tracked = model.status.unstaged
        let untracked = model.status.untracked
        model.requestDiscard(tracked + untracked)

        let pending = try #require(model.pendingDiscard)
        #expect(pending.trackedCount == tracked.count)
        #expect(pending.untrackedCount == untracked.count)
    }

    @Test("requesting a discard of nothing does nothing",
          .enabled(if: WorkingCopyTests.fixturesAvailable))
    func discardNothing() async throws {
        let (model, root) = try await makeModel(from: "alpha")
        defer { cleanUp(root) }

        model.requestDiscard([])
        #expect(model.pendingDiscard == nil)
    }
}
