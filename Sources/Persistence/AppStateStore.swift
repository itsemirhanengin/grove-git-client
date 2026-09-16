import Foundation

/// UI state Grove remembers for one workspace.
///
/// Everything here is keyed by a path **relative to the workspace root**, so
/// moving the whole folder — or checking it out somewhere else — keeps it.
nonisolated struct PersistedWorkspace: Codable, Sendable, Equatable {

    /// Repositories the user collapsed. Collapsed rather than expanded, because
    /// the default is open: a new repository appearing in the workspace should
    /// arrive open like every other one, not silently shut.
    var collapsedRepos: Set<String> = []

    /// Where the sidebar was. `nil` means the pinned Overview.
    var selectedRepo: String?
    var selectedSection: String?
}

/// Everything Grove remembers between launches.
///
/// Deliberately small. The scope filter is **not** here: restoring a workspace
/// with a non-default scope would open to a list that hides most of it, with
/// nothing on screen explaining why.
nonisolated struct PersistedState: Codable, Sendable, Equatable {

    /// Bumped when a field's meaning changes. A file from the future is
    /// discarded rather than half-read.
    static let currentVersion = 1

    var version = PersistedState.currentVersion

    /// Most recently opened first.
    var recentWorkspaces: [String] = []

    /// Per-workspace UI state, keyed by the workspace's own path.
    var workspaces: [String: PersistedWorkspace] = [:]
}

/// Reads and writes ``PersistedState``.
///
/// A JSON file rather than `UserDefaults`: this is a developer tool, and state
/// you can open, read and delete is worth more here than one `cfprefsd` caches
/// somewhere on your behalf.
@MainActor
final class AppStateStore {

    /// How many workspaces the switcher offers. Past this it stops being a
    /// shortcut and becomes a list to search.
    static let recentLimit = 8

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private(set) var state: PersistedState

    init(fileURL: URL = AppStateStore.defaultFileURL) {
        self.fileURL = fileURL
        self.state = Self.read(from: fileURL)
    }

    nonisolated static var defaultFileURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "Grove/state.json")
    }

    // MARK: Reading

    /// Never throws, and never reports.
    ///
    /// A missing file is the normal first launch, and a corrupt one must not be
    /// the reason the app will not open — the worst outcome of ignoring it is
    /// that the window comes up empty, which is recoverable by hand.
    private static func read(from url: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
            decoded.version <= PersistedState.currentVersion
        else { return PersistedState() }
        return decoded
    }

    // MARK: Workspaces

    /// Workspaces to offer, newest first, skipping any that are no longer on
    /// disk. Stale entries are dropped for good rather than hidden.
    func recentWorkspaces() -> [URL] {
        let existing = state.recentWorkspaces.filter {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
        if existing != state.recentWorkspaces {
            state.recentWorkspaces = existing
            scheduleSave()
        }
        return existing.map { URL(filePath: $0) }
    }

    func recordOpened(_ workspace: URL) {
        let path = workspace.path(percentEncoded: false)
        state.recentWorkspaces.removeAll { $0 == path }
        state.recentWorkspaces.insert(path, at: 0)
        if state.recentWorkspaces.count > Self.recentLimit {
            state.recentWorkspaces.removeLast(state.recentWorkspaces.count - Self.recentLimit)
        }
        scheduleSave()
    }

    /// Forgets a workspace, including whatever UI state it had.
    func forget(_ workspace: URL) {
        let path = workspace.path(percentEncoded: false)
        state.recentWorkspaces.removeAll { $0 == path }
        state.workspaces[path] = nil
        scheduleSave()
    }

    func workspaceState(for workspace: URL) -> PersistedWorkspace {
        state.workspaces[workspace.path(percentEncoded: false)] ?? PersistedWorkspace()
    }

    func updateWorkspace(_ workspace: URL, _ body: (inout PersistedWorkspace) -> Void) {
        let path = workspace.path(percentEncoded: false)
        var existing = state.workspaces[path] ?? PersistedWorkspace()
        body(&existing)
        guard state.workspaces[path] != existing else { return }
        state.workspaces[path] = existing
        scheduleSave()
    }

    // MARK: Writing

    /// Coalesces the burst a single interaction produces — expanding a section
    /// writes the collapsed set and moves the selection, which is two changes
    /// for one click.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    /// Writes immediately. Called on termination, where there is no later.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    /// Synchronous on purpose: the file is a couple of kilobytes, and the
    /// alternative on the way out of the process is losing it.
    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }

        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
