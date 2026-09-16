import Foundation
import Testing

@testable import Grove

@Suite("StatusParser")
struct StatusParserTests {

    /// Joins records the way `-z` does: each terminated by NUL.
    private func records(_ items: [String]) -> [UInt8] {
        var out: [UInt8] = []
        for item in items {
            out.append(contentsOf: Array(item.utf8))
            out.append(0)
        }
        return out
    }

    private func rawRecords(_ items: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for item in items {
            out.append(contentsOf: item)
            out.append(0)
        }
        return out
    }

    private let oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    // MARK: Branch headers

    @Test("reads branch, upstream and ahead/behind")
    func branchHeaders() {
        let status = StatusParser.parse(
            records([
                "# branch.oid \(oid)",
                "# branch.head main",
                "# branch.upstream origin/main",
                "# branch.ab +3 -1",
            ])
        )

        #expect(status.headOID == oid)
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 3)
        #expect(status.behind == 1)
        #expect(!status.isUnborn)
        #expect(!status.isDetached)
    }

    @Test("treats (initial) as an unborn HEAD rather than a commit id")
    func unbornHead() {
        let status = StatusParser.parse(
            records(["# branch.oid (initial)", "# branch.head main"])
        )

        #expect(status.isUnborn)
        #expect(status.headOID == nil)
        #expect(status.branch == "main")
    }

    @Test("treats (detached) as no branch")
    func detachedHead() {
        let status = StatusParser.parse(
            records(["# branch.oid \(oid)", "# branch.head (detached)"])
        )

        #expect(status.isDetached)
        #expect(status.branch == nil)
        #expect(status.headOID == oid)
    }

    @Test("ignores headers it does not recognise")
    func unknownHeader() {
        let status = StatusParser.parse(
            records([
                "# branch.oid \(oid)",
                "# some.future.header whatever value",
                "# branch.head main",
            ])
        )

        #expect(status.branch == "main")
        #expect(status.changes.isEmpty)
    }

    // MARK: Ordinary entries

    @Test("splits XY into index and worktree status")
    func ordinaryEntry() {
        let status = StatusParser.parse(
            records(["1 .M N... 100644 100644 100644 \(oid) \(oid) src/app.swift"])
        )

        let change = try! #require(status.changes.first)
        #expect(change.indexStatus == .unchanged)
        #expect(change.worktreeStatus == .modified)
        #expect(change.displayPath == "src/app.swift")
        #expect(change.kind == .tracked)
        #expect(change.isUnstaged)
        #expect(!change.isStaged)
    }

    /// The case most clients collapse: staged, then edited again.
    @Test("a MM file appears in BOTH the staged and unstaged lists")
    func stagedAndDirty() {
        let status = StatusParser.parse(
            records(["1 MM N... 100644 100644 100644 \(oid) \(oid) locales/tr.json"])
        )

        let change = try! #require(status.changes.first)
        #expect(change.indexStatus == .modified)
        #expect(change.worktreeStatus == .modified)
        #expect(change.isStaged)
        #expect(change.isUnstaged)
        #expect(status.staged.count == 1)
        #expect(status.unstaged.count == 1)
    }

    @Test("keeps paths that contain spaces intact")
    func pathWithSpaces() {
        let status = StatusParser.parse(
            records(["1 M. N... 100644 100644 100644 \(oid) \(oid) My Folder/Some File.txt"])
        )

        #expect(status.changes.first?.displayPath == "My Folder/Some File.txt")
    }

    @Test("preserves raw bytes for paths that are not valid UTF-8")
    func invalidUTF8Path() {
        // A path ending in two bytes that cannot be UTF-8.
        var record = Array("1 .M N... 100644 100644 100644 \(oid) \(oid) bad/".utf8)
        record.append(contentsOf: [0xFF, 0xFE])

        let status = StatusParser.parse(rawRecords([record]))
        let change = try! #require(status.changes.first)

        // The bytes survive, which is what gets written back to git.
        #expect(change.pathBytes.suffix(2) == [0xFF, 0xFE])
        // The display string is repaired rather than empty or nil.
        #expect(change.displayPath.hasPrefix("bad/"))
    }

    // MARK: Renames — the record that spans two entries

    @Test("reads a rename and its original path")
    func rename() {
        let status = StatusParser.parse(
            records([
                "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 src/helpers.js",
                "src/legacy.js",
            ])
        )

        #expect(status.changes.count == 1)
        let change = try! #require(status.changes.first)
        #expect(change.displayPath == "src/helpers.js")
        #expect(change.originalDisplayPath == "src/legacy.js")
        #expect(change.indexStatus == .renamed)
        #expect(change.similarity == 100)
    }

    /// The regression this whole design exists to prevent: a parser that
    /// advances by one record after a rename treats the original path as the
    /// next entry and mis-reads everything after it.
    @Test("stays in sync with entries that follow a rename")
    func renameDoesNotDesync() {
        let status = StatusParser.parse(
            records([
                "# branch.oid \(oid)",
                "# branch.head main",
                "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 src/helpers.js",
                "src/legacy.js",
                "1 .M N... 100644 100644 100644 \(oid) \(oid) src/after.js",
                "? src/untracked.js",
            ])
        )

        #expect(status.changes.count == 3)
        #expect(status.changes.map(\.displayPath) == [
            "src/helpers.js", "src/after.js", "src/untracked.js",
        ])
        // If sync were lost, "src/legacy.js" would show up as an entry.
        #expect(!status.changes.contains { $0.displayPath == "src/legacy.js" })
        #expect(status.changes[2].kind == .untracked)
    }

    @Test("handles two consecutive renames")
    func consecutiveRenames() {
        let status = StatusParser.parse(
            records([
                "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 a-new.js",
                "a-old.js",
                "2 R. N... 100644 100644 100644 \(oid) \(oid) R090 b-new.js",
                "b-old.js",
            ])
        )

        #expect(status.changes.count == 2)
        #expect(status.changes[0].originalDisplayPath == "a-old.js")
        #expect(status.changes[1].originalDisplayPath == "b-old.js")
        #expect(status.changes[1].similarity == 90)
    }

    // MARK: Unmerged

    @Test("reads all three stages of a conflicted path")
    func unmerged() {
        let base = String(repeating: "1", count: 40)
        let ours = String(repeating: "2", count: 40)
        let theirs = String(repeating: "3", count: 40)

        let status = StatusParser.parse(
            records([
                "u UU N... 100644 100644 100644 100644 \(base) \(ours) \(theirs) auth.ts"
            ])
        )

        let change = try! #require(status.changes.first)
        #expect(change.kind == .unmerged)
        #expect(change.isConflicted)
        #expect(change.displayPath == "auth.ts")
        #expect(change.unmergedStages?.base == base)
        #expect(change.unmergedStages?.ours == ours)
        #expect(change.unmergedStages?.theirs == theirs)
        #expect(status.hasConflicts)
        #expect(status.conflicted.count == 1)
    }

    // MARK: Untracked, ignored, submodules

    @Test("classifies untracked and ignored separately")
    func untrackedAndIgnored() {
        let status = StatusParser.parse(
            records(["? src/new.js", "! build/output.o"])
        )

        #expect(status.untracked.map(\.displayPath) == ["src/new.js"])
        #expect(status.changes.count { $0.kind == .ignored } == 1)
        // Ignored files are not dirt.
        #expect(status.dirtyCount == 1)
        // An ignored file belongs in neither working list.
        #expect(status.unstaged.isEmpty)
    }

    @Test("decodes the submodule field")
    func submodule() {
        let status = StatusParser.parse(
            records([
                "1 .M SCMU 160000 160000 160000 \(oid) \(oid) vendor/lib",
                "1 .M N... 100644 100644 100644 \(oid) \(oid) plain.txt",
            ])
        )

        let sub = try! #require(status.changes[0].submodule)
        #expect(sub.commitChanged)
        #expect(sub.hasModifiedTrackedFiles)
        #expect(sub.hasUntrackedFiles)
        // A normal file has no submodule state at all.
        #expect(status.changes[1].submodule == nil)
    }

    // MARK: Robustness

    @Test("skips malformed records instead of failing the whole parse")
    func malformedRecords() {
        let status = StatusParser.parse(
            records([
                "# branch.head main",
                "1 too few fields",
                "z unknown record type",
                "1 .M N... 100644 100644 100644 \(oid) \(oid) good.swift",
            ])
        )

        #expect(status.branch == "main")
        #expect(status.changes.map(\.displayPath) == ["good.swift"])
    }

    @Test("returns an empty status for empty input")
    func emptyInput() {
        let status = StatusParser.parse([])
        #expect(status == RepoStatus.empty)
        #expect(status.changes.isEmpty)
        #expect(status.dirtyCount == 0)
    }

    @Test("collapses control characters for single-line display")
    func singleLineSanitization() {
        // Newlines and tabs are legal in macOS filenames; a fixed-height row
        // cannot render them.
        #expect(FileChange.sanitizeForSingleLine("plain.txt") == "plain.txt")
        #expect(FileChange.sanitizeForSingleLine("a\nb.txt") == "a␊b.txt")
        #expect(FileChange.sanitizeForSingleLine("a\tb.txt") == "a␉b.txt")
        // CRLF is a single grapheme cluster in Swift, so it collapses to one
        // symbol rather than two — which is also what reads better.
        #expect(FileChange.sanitizeForSingleLine("a\r\nb") == "a␊b")
        // Non-ASCII is left alone — it is only control characters that break layout.
        #expect(FileChange.sanitizeForSingleLine("adı-şğü.txt") == "adı-şğü.txt")
    }

    @Test("splits the display path into directory and file name")
    func pathComponents() {
        let status = StatusParser.parse(
            records(["1 .M N... 100644 100644 100644 \(oid) \(oid) src/features/Auth/Login.swift"])
        )

        let change = try! #require(status.changes.first)
        #expect(change.fileName == "Login.swift")
        #expect(change.directoryPrefix == "src/features/Auth")
    }
}
