import Testing

@testable import Grove

@Suite("Sidebar model")
struct SidebarSelectionTests {

    @Test("repo selections are distinct per section")
    func repoSelectionIdentity() {
        let repo = RepoID(path: "/tmp/alpha")
        #expect(SidebarSelection.repo(repo, .workingCopy) != .repo(repo, .history))
        #expect(SidebarSelection.repo(repo, .workingCopy) == .repo(repo, .workingCopy))
        #expect(SidebarSelection.overview != .repo(repo, .workingCopy))
    }

    @Test("every section has a title and a symbol")
    func sectionsAreComplete() {
        for section in RepoSection.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.symbol.isEmpty)
        }
    }
}
