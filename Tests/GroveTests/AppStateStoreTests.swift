import Foundation
import Testing

@testable import Grove

/// What Grove remembers between launches.
///
/// The store is deliberately unable to fail loudly — a corrupt state file must
/// never be the reason the app will not open — so the tests are the only place
/// its behaviour is asserted at all.
@MainActor
@Suite("Persisted state")
struct AppStateStoreTests {

    private func makeStore() -> (AppStateStore, URL) {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-state-\(UUID().uuidString)")
        let file = directory.appending(path: "state.json")
        return (AppStateStore(fileURL: file), directory)
    }

    private func clean(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A real directory, because `recentWorkspaces()` drops paths that are gone.
    private func makeWorkspace(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Recents

    @Test("the most recently opened workspace comes first")
    func ordering() throws {
        let (store, directory) = makeStore()
        defer { clean(directory) }

        let alpha = try makeWorkspace("alpha", in: directory)
        let beta = try makeWorkspace("beta", in: directory)

        store.recordOpened(alpha)
        store.recordOpened(beta)
        #expect(store.recentWorkspaces() == [beta, alpha])

        // Re-opening moves it up rather than adding it twice.
        store.recordOpened(alpha)
        #expect(store.recentWorkspaces() == [alpha, beta])
    }

    @Test("the list stops at the limit, dropping the oldest")
    func limit() throws {
        let (store, directory) = makeStore()
        defer { clean(directory) }

        let workspaces = try (0..<(AppStateStore.recentLimit + 3)).map {
            try makeWorkspace("w\($0)", in: directory)
        }
        for workspace in workspaces { store.recordOpened(workspace) }

        let recent = store.recentWorkspaces()
        #expect(recent.count == AppStateStore.recentLimit)
        #expect(recent.first == workspaces.last)
        #expect(!recent.contains(workspaces[0]))
    }

    /// A workspace that has been deleted or unmounted is not something to offer.
    @Test("a workspace that is gone from disk is dropped, not hidden")
    func staleEntriesAreRemoved() throws {
        let (store, directory) = makeStore()
        defer { clean(directory) }

        let alpha = try makeWorkspace("alpha", in: directory)
        let doomed = try makeWorkspace("doomed", in: directory)
        store.recordOpened(alpha)
        store.recordOpened(doomed)

        try FileManager.default.removeItem(at: doomed)

        #expect(store.recentWorkspaces() == [alpha])
        #expect(store.state.recentWorkspaces == [alpha.path(percentEncoded: false)])
    }

    @Test("forgetting a workspace also forgets what it remembered")
    func forget() throws {
        let (store, directory) = makeStore()
        defer { clean(directory) }

        let alpha = try makeWorkspace("alpha", in: directory)
        store.recordOpened(alpha)
        store.updateWorkspace(alpha) { $0.collapsedRepos = ["api"] }

        store.forget(alpha)
        #expect(store.recentWorkspaces().isEmpty)
        #expect(store.workspaceState(for: alpha) == PersistedWorkspace())
    }

    // MARK: Round trip

    @Test("survives a relaunch")
    func roundTrip() throws {
        let (store, directory) = makeStore()
        defer { clean(directory) }

        let alpha = try makeWorkspace("alpha", in: directory)
        store.recordOpened(alpha)
        store.updateWorkspace(alpha) {
            $0.collapsedRepos = ["services/api", "web"]
            $0.selectedRepo = "web"
            $0.selectedSection = RepoSection.history.rawValue
        }
        store.flush()

        let reopened = AppStateStore(fileURL: directory.appending(path: "state.json"))
        #expect(reopened.recentWorkspaces() == [alpha])

        let restored = reopened.workspaceState(for: alpha)
        #expect(restored.collapsedRepos == ["services/api", "web"])
        #expect(restored.selectedRepo == "web")
        #expect(restored.selectedSection == RepoSection.history.rawValue)
    }

    // MARK: Failure is silent, on purpose

    @Test("a missing file is just a first launch")
    func missingFile() {
        let (store, directory) = makeStore()
        defer { clean(directory) }
        #expect(store.state == PersistedState())
        #expect(store.recentWorkspaces().isEmpty)
    }

    @Test("a corrupt file opens empty rather than not at all")
    func corruptFile() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-state-\(UUID().uuidString)")
        defer { clean(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appending(path: "state.json")
        try Data("{ this is not json".utf8).write(to: file)

        #expect(AppStateStore(fileURL: file).state == PersistedState())
    }

    /// A newer Grove may add fields this one would silently misread. Better to
    /// start clean than to half-understand it.
    @Test("a file from a future version is ignored")
    func futureVersion() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "grove-state-\(UUID().uuidString)")
        defer { clean(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appending(path: "state.json")
        let future = """
            { "version": 99, "recentWorkspaces": ["/somewhere"], "workspaces": {} }
            """
        try Data(future.utf8).write(to: file)

        #expect(AppStateStore(fileURL: file).state.recentWorkspaces.isEmpty)
    }

    // MARK: Keys

    /// Repository state is keyed by a path **relative to the workspace**, which
    /// is what lets the whole folder move without losing it.
    @Test("repository keys are relative to the workspace root")
    func relativeKeys() {
        let workspace = URL(filePath: "/Users/someone/code")
        let repository = Repository(
            root: workspace.appending(path: "services/api"),
            gitPath: workspace.appending(path: "services/api/.git"),
            kind: .standard,
            depth: 1
        )
        #expect(repository.relativePath(from: workspace) == "services/api")

        let moved = URL(filePath: "/Volumes/External/code")
        let afterMove = Repository(
            root: moved.appending(path: "services/api"),
            gitPath: moved.appending(path: "services/api/.git"),
            kind: .standard,
            depth: 1
        )
        #expect(afterMove.relativePath(from: moved) == repository.relativePath(from: workspace))
    }
}
