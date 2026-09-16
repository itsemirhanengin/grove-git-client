import Foundation
import Testing

@testable import Grove

@Suite("Workspace scope and filter")
@MainActor
struct WorkspaceFilterTests {

    /// Builds a workspace with repositories in given states, without touching
    /// disk or running git.
    private func makeWorkspace(
        _ specs: [(name: String, dirty: Int, conflicts: Bool, ahead: Int, failed: Bool)]
    ) async -> WorkspaceModel {
        let environment = await GitEnvironment.resolve()
        let runner = GitRunner(environment: environment)
        let limiter = GitTaskLimiter(capacity: 2)

        let workspace = WorkspaceModel(
            root: URL(filePath: "/tmp/workspace"), runner: runner, limiter: limiter)

        workspace.repos = specs.map { spec in
            let repository = Repository(
                root: URL(filePath: "/tmp/workspace/\(spec.name)"),
                gitPath: URL(filePath: "/tmp/workspace/\(spec.name)/.git"),
                kind: .standard,
                depth: 1
            )
            let model = RepoViewModel(
                repository: repository,
                engine: RepoEngine(repository: repository, runner: runner, limiter: limiter)
            )

            var status = RepoStatus()
            status.branch = "main"
            status.ahead = spec.ahead
            status.changes = (0..<spec.dirty).map { index in
                FileChange(
                    pathBytes: Array("file\(index).txt".utf8),
                    displayPath: "file\(index).txt",
                    indexStatus: .unchanged,
                    worktreeStatus: .modified,
                    kind: .tracked
                )
            }
            if spec.conflicts {
                status.changes.append(
                    FileChange(
                        pathBytes: Array("conflict.txt".utf8),
                        displayPath: "conflict.txt",
                        indexStatus: .unmerged,
                        worktreeStatus: .unmerged,
                        kind: .unmerged
                    )
                )
            }
            model.status = status
            model.loadState = spec.failed ? .failed(.notARepository) : .ready
            return model
        }

        return workspace
    }

    private func fixture() async -> WorkspaceModel {
        await makeWorkspace([
            ("alpha", 3, false, 0, false),
            ("beta", 0, false, 1, false),
            ("gamma", 0, true, 0, false),
            ("delta", 0, false, 0, false),
        ])
    }

    @Test("All shows everything")
    func scopeAll() async {
        let workspace = await fixture()
        workspace.scope = .all
        #expect(workspace.visibleRepos.map(\.name) == ["alpha", "beta", "gamma", "delta"])
        #expect(workspace.hiddenRepoCount == 0)
        #expect(!workspace.isFiltering)
    }

    @Test("Changed shows only repositories with uncommitted work")
    func scopeChanged() async {
        let workspace = await fixture()
        workspace.scope = .changed
        // gamma counts as changed too — a conflict is uncommitted work.
        #expect(workspace.visibleRepos.map(\.name) == ["alpha", "gamma"])
        #expect(workspace.hiddenRepoCount == 2)
        #expect(workspace.isFiltering)
    }

    @Test("Conflicts narrows to the repository that is actually blocked")
    func scopeConflicts() async {
        let workspace = await fixture()
        workspace.scope = .conflicts
        #expect(workspace.visibleRepos.map(\.name) == ["gamma"])
    }

    @Test("Ahead shows only repositories with something to push")
    func scopeAhead() async {
        let workspace = await fixture()
        workspace.scope = .ahead
        #expect(workspace.visibleRepos.map(\.name) == ["beta"])
    }

    @Test("the text filter matches on name, case-insensitively")
    func textFilter() async {
        let workspace = await fixture()
        workspace.filterText = "AM"
        #expect(workspace.visibleRepos.map(\.name) == ["gamma"])

        // Surrounding whitespace is trimmed; the match is a substring, so "a"
        // hits every one of alpha, beta, gamma and delta.
        workspace.filterText = "  a  "
        #expect(workspace.visibleRepos.map(\.name) == ["alpha", "beta", "gamma", "delta"])

        workspace.filterText = "lph"
        #expect(workspace.visibleRepos.map(\.name) == ["alpha"])

        workspace.filterText = "nothing"
        #expect(workspace.visibleRepos.isEmpty)
    }

    @Test("scope and text filter combine")
    func combined() async {
        let workspace = await makeWorkspace([
            ("api-admin", 2, false, 0, false),
            ("api-server", 0, false, 0, false),
            ("web-admin", 4, false, 0, false),
        ])
        workspace.scope = .changed
        workspace.filterText = "api"
        #expect(workspace.visibleRepos.map(\.name) == ["api-admin"])
    }

    /// A failed repository must never be filtered out. Hiding it would shrink
    /// the workspace silently and leave no way to retry.
    @Test("a failed repository stays visible under every scope")
    func failedAlwaysVisible() async {
        let workspace = await makeWorkspace([
            ("broken", 0, false, 0, true),
            ("clean", 0, false, 0, false),
        ])

        for scope in RepoScope.allCases {
            workspace.scope = scope
            #expect(
                workspace.visibleRepos.contains { $0.name == "broken" },
                "broken repo disappeared under scope .\(scope.rawValue)"
            )
        }
    }

    @Test("every scope has a title and a symbol")
    func scopeMetadata() {
        for scope in RepoScope.allCases {
            #expect(!scope.title.isEmpty)
            #expect(!scope.symbol.isEmpty)
        }
    }

    // MARK: Display cap

    @Test("a repository under the cap renders everything")
    func underCap() async {
        let workspace = await makeWorkspace([("small", 10, false, 0, false)])
        let repo = workspace.repos[0]

        #expect(repo.displayedUnstaged.count == 10)
        #expect(!repo.hasMoreThanDisplayed)
        #expect(repo.hiddenRowCount == 0)
    }

    /// The badge must keep reporting the truth even when the list does not —
    /// under-reporting uncommitted work is worse than truncating the list.
    @Test("a repository over the cap truncates rows but not the count")
    func overCap() async {
        let total = RepoViewModel.displayRowCap + 742
        let workspace = await makeWorkspace([("huge", total, false, 0, false)])
        let repo = workspace.repos[0]

        #expect(repo.dirtyCount == total)
        #expect(repo.displayedUnstaged.count == RepoViewModel.displayRowCap)
        #expect(repo.hasMoreThanDisplayed)
        #expect(repo.hiddenRowCount == 742)
    }

    @Test("the cap applies per group, not across the repository")
    func capIsPerGroup() async {
        let workspace = await makeWorkspace([("mixed", 5, true, 0, false)])
        let repo = workspace.repos[0]

        // Well under the cap in every group, so nothing is hidden.
        #expect(repo.displayedConflicted.count == 1)
        #expect(repo.displayedUnstaged.count == 5)
        #expect(!repo.hasMoreThanDisplayed)
    }
}
