import Foundation
import Testing

@testable import Grove

/// Opening a diff from the Overview.
///
/// The selection lives on the repository, because that is what the diff needs.
/// The Overview shows every repository at once and the sidebar points at none
/// of them, so the workspace has to say which one the last click belonged to —
/// without that, clicking a file in the Overview did nothing at all.
@Suite("Overview selection")
@MainActor
struct OverviewSelectionTests {

    private func makeWorkspace(_ names: [String]) async -> WorkspaceModel {
        let environment = await GitEnvironment.resolve()
        let runner = GitRunner(environment: environment)
        let limiter = GitTaskLimiter(capacity: 2)

        let workspace = WorkspaceModel(
            root: URL(filePath: "/tmp/workspace"), runner: runner, limiter: limiter)

        workspace.repos = names.map { name in
            let repository = Repository(
                root: URL(filePath: "/tmp/workspace/\(name)"),
                gitPath: URL(filePath: "/tmp/workspace/\(name)/.git"),
                kind: .standard,
                depth: 1
            )
            return RepoViewModel(
                repository: repository,
                engine: RepoEngine(repository: repository, runner: runner, limiter: limiter)
            )
        }
        return workspace
    }

    private func change(_ path: String) -> FileChange {
        FileChange(
            pathBytes: Array(path.utf8),
            displayPath: path,
            indexStatus: .unchanged,
            worktreeStatus: .modified,
            kind: .tracked
        )
    }

    @Test("selecting a change records both the change and which repository owns it")
    func selectRecordsOwner() async {
        let workspace = await makeWorkspace(["alpha", "beta"])
        let alpha = workspace.repos[0]

        #expect(workspace.focusedRepoID == nil)

        workspace.select(change("src/a.swift"), staged: false, in: alpha)

        #expect(workspace.focusedRepoID == alpha.id)
        #expect(alpha.selectedChange?.change.displayPath == "src/a.swift")
        #expect(alpha.selectedChange?.staged == false)
    }

    /// Two highlighted rows in the Overview, only one of which is showing, is
    /// worse than no highlight at all.
    @Test("selecting in one repository clears the selection in every other")
    func selectionIsExclusive() async {
        let workspace = await makeWorkspace(["alpha", "beta"])
        let alpha = workspace.repos[0]
        let beta = workspace.repos[1]

        workspace.select(change("src/a.swift"), staged: false, in: alpha)
        workspace.select(change("lib/b.swift"), staged: true, in: beta)

        #expect(workspace.focusedRepoID == beta.id)
        #expect(beta.selectedChange?.change.displayPath == "lib/b.swift")
        #expect(alpha.selectedChange == nil)
    }

    /// The same file staged and unstaged are two different diffs, so the side is
    /// part of the selection rather than a display toggle.
    @Test("the staged side is part of what was selected")
    func stagedSideIsPartOfTheSelection() async {
        let workspace = await makeWorkspace(["alpha"])
        let alpha = workspace.repos[0]
        let file = change("src/a.swift")

        workspace.select(file, staged: false, in: alpha)
        #expect(alpha.selectedChange == SelectedChange(change: file, staged: false))

        workspace.select(file, staged: true, in: alpha)
        #expect(alpha.selectedChange == SelectedChange(change: file, staged: true))
        #expect(alpha.selectedChange != SelectedChange(change: file, staged: false))
    }
}
