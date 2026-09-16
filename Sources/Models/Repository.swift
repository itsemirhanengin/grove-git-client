import Foundation

/// How a repository is attached to its `.git`.
nonisolated enum RepositoryKind: Sendable, Hashable {
    /// An ordinary repository with a `.git` directory.
    case standard
    /// A linked worktree — `.git` is a file pointing into `…/worktrees/<name>`.
    case worktree
    /// A submodule — `.git` is a file pointing into the parent's `…/modules/<name>`.
    case submodule
}

/// A repository Grove knows about.
///
/// This is the immutable descriptor produced by discovery. Everything that
/// changes over time — status, branches, errors — lives in `RepoStatus` and the
/// view model, so this value can be compared cheaply and used as an identity.
nonisolated struct Repository: Sendable, Hashable, Identifiable {

    /// Working-tree root.
    let root: URL

    /// Resolved `.git` location. For a worktree or submodule this is *not*
    /// `root/.git`, which is why it is stored rather than derived — the files
    /// that signal an in-progress merge or rebase live here.
    let gitPath: URL

    let kind: RepositoryKind

    /// How deep beneath the workspace root this repository sits, for display.
    let depth: Int

    var id: RepoID { RepoID(path: root.path()) }

    /// Folder name, which is what the sidebar shows.
    var name: String { root.lastPathComponent }

    /// Path relative to a workspace root, used to key persisted UI state so that
    /// moving the whole workspace does not lose it.
    func relativePath(from workspaceRoot: URL) -> String {
        let base = workspaceRoot.path()
        let full = root.path()
        guard full.hasPrefix(base) else { return full }
        return String(full.dropFirst(base.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
    }
}
