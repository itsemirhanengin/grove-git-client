import Foundation

/// Which repositories the workspace is currently showing.
///
/// A workspace of ten repositories is mostly quiet at any moment, so the useful
/// default is not "all of them" but "the ones that need me".
nonisolated enum RepoScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case changed
    case conflicts
    case ahead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .changed: "Changed"
        case .conflicts: "Conflicts"
        case .ahead: "Ahead"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .changed: "pencil"
        case .conflicts: "exclamationmark.triangle"
        case .ahead: "arrow.up.circle"
        }
    }

    func matches(_ status: RepoStatus) -> Bool {
        switch self {
        case .all: true
        case .changed: status.dirtyCount > 0
        case .conflicts: status.hasConflicts
        case .ahead: status.ahead > 0
        }
    }
}
