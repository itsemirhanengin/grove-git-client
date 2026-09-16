import Foundation
import Observation

/// What Grove has done to the repositories in this workspace, in order.
///
/// It exists because the safety net is otherwise invisible: a discard writes a
/// snapshot to `refs/grove/backup/`, and until now nothing said so, named it, or
/// offered it back. A log that records the operation *and* the ref it left
/// behind is what turns "Grove saves a snapshot first" from a claim into
/// something the user can act on.
///
/// In memory only. It is a record of this session's actions, not an audit trail
/// — the durable half is the backup refs themselves, which survive a relaunch
/// and are listed straight from git.
@Observable
@MainActor
final class OperationLog {

    /// How many entries are kept. Past this it is scrollback, not a log.
    static let limit = 200

    struct Entry: Identifiable, Sendable {

        enum Outcome: Sendable, Equatable {
            case running
            case succeeded
            case failed(String)
        }

        let id = UUID()
        let date: Date
        let repoID: RepoID
        let repoName: String

        /// What was asked for, in the words the user would use: "Discard 3
        /// files", "Pull and Rebase", "Stage 2 files".
        let summary: String

        var outcome: Outcome = .running

        /// The snapshot this operation left behind, when it took one.
        var backupRef: String?

        var isDestructive: Bool
    }

    private(set) var entries: [Entry] = []

    /// Records the start of an operation and returns its id.
    ///
    /// Recorded when it *starts* rather than when it finishes, so an operation
    /// that hangs or crashes still leaves a trace — which is exactly the one
    /// worth having.
    @discardableResult
    func begin(_ summary: String, in repo: RepoViewModel, destructive: Bool = false) -> UUID {
        let entry = Entry(
            date: Date(),
            repoID: repo.id,
            repoName: repo.name,
            summary: summary,
            isDestructive: destructive
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        return entry.id
    }

    func finish(_ id: UUID, outcome: Entry.Outcome, backupRef: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].outcome = outcome
        if let backupRef { entries[index].backupRef = backupRef }
    }

    func clear() {
        entries.removeAll()
    }

    var failureCount: Int {
        entries.count { if case .failed = $0.outcome { true } else { false } }
    }
}
