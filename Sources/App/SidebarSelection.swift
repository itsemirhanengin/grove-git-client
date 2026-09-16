import Foundation

/// Identifies a repository within the running app.
///
/// A repo is identified by its resolved toplevel path, so it survives a rescan
/// without needing a stored id.
struct RepoID: Hashable, Sendable {
    let path: String
}

/// The sections Grove offers for a single repository, mirroring Tower's sidebar.
///
/// `pullRequests` and `branchesReview` are deliberately absent: they need
/// GitHub/GitLab API integration and OAuth, which is a separate project.
enum RepoSection: String, Hashable, Sendable, CaseIterable, Identifiable {
    case workingCopy
    case history
    case stashes
    case branches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workingCopy: "Working Copy"
        case .history: "History"
        case .stashes: "Stashes"
        case .branches: "Branches"
        }
    }

    var symbol: String {
        switch self {
        case .workingCopy: "folder"
        case .history: "clock"
        case .stashes: "tray"
        case .branches: "arrow.triangle.branch"
        }
    }
}

/// What the sidebar currently has selected, which decides what the list and
/// detail columns show.
///
/// `overview` is Grove's addition to Tower's model: the all-repos-at-once view
/// that the workspace idea exists for in the first place.
enum SidebarSelection: Hashable, Sendable {
    case overview
    case repo(RepoID, RepoSection)
}
