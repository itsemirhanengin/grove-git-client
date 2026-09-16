import Testing

@testable import DiffCore

/// Every patch in this file is **captured `git diff` output**, pasted verbatim.
///
/// Hand-written fixtures were tried on the previous parser and produced wrong
/// hunk counts three separate times, each of which looked like a parser bug for
/// an afternoon. Nothing here is typed from memory.
enum RealDiffs {

    /// Three hunks, the middle one a pure insertion — so the third hunk's
    /// `+start` is shifted and a builder that ignores that gets it wrong.
    static let multiHunk = """
        diff --git a/multi.txt b/multi.txt
        index ac9837c..204b1ed 100644
        --- a/multi.txt
        +++ b/multi.txt
        @@ -1,6 +1,6 @@
         line 1
         line 2
        -line 3
        +line 3 CHANGED
         line 4
         line 5
         line 6
        @@ -8,6 +8,7 @@ line 7
         line 8
         line 9
         line 10
        +inserted after 10
         line 11
         line 12
         line 13
        @@ -17,7 +18,7 @@ line 16
         line 17
         line 18
         line 19
        -line 20
        +line 20 CHANGED
         line 21
         line 22
         line 23

        """

    /// A CRLF file. The `\\r` is part of every line's content and has to
    /// survive the round trip — `git apply` compares bytes.
    static let crlf = """
        diff --git a/crlf.txt b/crlf.txt
        index b4ec4d1..c6d393e 100644
        --- a/crlf.txt
        +++ b/crlf.txt
        @@ -1,3 +1,3 @@
         alpha\r
        -beta\r
        +BETA\r
         gamma\r

        """

    /// Both sides end without a trailing newline, so two `\\ No newline`
    /// markers sit inside one hunk.
    static let noEOL = """
        diff --git a/noeol.txt b/noeol.txt
        index 54d55bf..d945578 100644
        --- a/noeol.txt
        +++ b/noeol.txt
        @@ -1,3 +1,3 @@
         one
        -two
        -three
        \\ No newline at end of file
        +TWO
        +three changed
        \\ No newline at end of file

        """

    /// An untracked file, as `git diff --no-index -- /dev/null <path>` writes
    /// it. Note `@@ -0,0 +1 @@`: a count of 1 is written without the comma.
    static let newFile = """
        diff --git a/src/config.js b/src/config.js
        new file mode 100644
        index 0000000..ecbe222
        --- /dev/null
        +++ b/src/config.js
        @@ -0,0 +1 @@
        +export const config = { api: 'https://example.invalid' };

        """

    /// A 100 %-similar rename. There is **no** `---`/`+++` pair and no hunk at
    /// all — the paths exist only on the rename lines.
    static let pureRename = """
        diff --git a/src/helpers.js b/src/legacy.js
        similarity index 100%
        rename from src/helpers.js
        rename to src/legacy.js

        """

    /// A diff whose *content* is a diff. Context lines here start with
    /// `diff --git` and `@@`, which is what breaks a parser that sniffs
    /// prefixes instead of counting from the hunk header.
    static let diffOfADiff = """
        diff --git a/sample.patch b/sample.patch
        index 1111111..2222222 100644
        --- a/sample.patch
        +++ b/sample.patch
        @@ -1,5 +1,5 @@
         diff --git a/x b/x
         @@ -1,2 +1,2 @@
        - old
        + new
         trailer

        """
}

@Suite("Unified patch parsing")
struct UnifiedPatchTests {

    @Test("reads three hunks and their headers")
    func multiHunkShape() {
        let files = UnifiedPatchParser.parse(RealDiffs.multiHunk)
        #expect(files.count == 1)

        let file = files[0]
        #expect(file.oldPath == "multi.txt")
        #expect(file.newPath == "multi.txt")
        #expect(file.headerLines.count == 4)
        #expect(file.hunks.count == 3)

        #expect(file.hunks[0].oldStart == 1)
        #expect(file.hunks[0].oldCount == 6)
        #expect(file.hunks[0].newStart == 1)
        #expect(file.hunks[0].newCount == 6)
        #expect(file.hunks[0].heading == "")

        #expect(file.hunks[1].oldStart == 8)
        #expect(file.hunks[1].newCount == 7)
        #expect(file.hunks[1].heading == " line 7")

        #expect(file.hunks[2].oldStart == 17)
        #expect(file.hunks[2].newStart == 18)
    }

    @Test("numbers every line on the side it exists on")
    func lineNumbers() {
        let file = UnifiedPatchParser.parse(RealDiffs.multiHunk)[0]
        let hunk = file.hunks[0]

        #expect(hunk.lines.count == 7)
        #expect(hunk.lines[0].kind == .context)
        #expect(hunk.lines[0].oldNumber == 1)
        #expect(hunk.lines[0].newNumber == 1)

        let deletion = hunk.lines[2]
        #expect(deletion.kind == .deletion)
        #expect(deletion.content == "line 3")
        #expect(deletion.oldNumber == 3)
        #expect(deletion.newNumber == 0)

        let addition = hunk.lines[3]
        #expect(addition.kind == .addition)
        #expect(addition.content == "line 3 CHANGED")
        #expect(addition.oldNumber == 0)
        #expect(addition.newNumber == 3)

        // The line after the change is 4 on both sides again.
        #expect(hunk.lines[4].oldNumber == 4)
        #expect(hunk.lines[4].newNumber == 4)
    }

    @Test("counts hunk bodies instead of sniffing prefixes")
    func diffOfADiff() {
        let files = UnifiedPatchParser.parse(RealDiffs.diffOfADiff)
        #expect(files.count == 1, "a `diff --git` context line must not start a second file")

        let file = files[0]
        #expect(file.hunks.count == 1, "an `@@` context line must not start a second hunk")
        #expect(file.hunks[0].lines.count == 5)
        #expect(file.hunks[0].lines[0].content == "diff --git a/x b/x")
        #expect(file.hunks[0].lines[1].content == "@@ -1,2 +1,2 @@")
        #expect(file.hunks[0].lines[2].kind == .deletion)
        #expect(file.hunks[0].lines[3].kind == .addition)
    }

    @Test("keeps the carriage return of a CRLF file in the content")
    func carriageReturns() {
        let file = UnifiedPatchParser.parse(RealDiffs.crlf)[0]
        let hunk = file.hunks[0]
        #expect(hunk.lines.count == 4)
        for line in hunk.lines {
            #expect(line.content.hasSuffix("\r"), "\(line.content) lost its carriage return")
        }
    }

    @Test("attaches a no-newline marker to the line above it, counting neither")
    func noNewlineMarkers() {
        let file = UnifiedPatchParser.parse(RealDiffs.noEOL)[0]
        let hunk = file.hunks[0]

        #expect(hunk.oldCount == 3)
        #expect(hunk.newCount == 3)
        #expect(hunk.lines.count == 5, "the two `\\ No newline` lines are markers, not lines")

        #expect(hunk.lines[2].content == "three")
        #expect(hunk.lines[2].kind == .deletion)
        #expect(hunk.lines[2].noNewlineAfter)

        #expect(hunk.lines[4].content == "three changed")
        #expect(hunk.lines[4].kind == .addition)
        #expect(hunk.lines[4].noNewlineAfter)

        #expect(!hunk.lines[3].noNewlineAfter)
    }

    @Test("reads /dev/null as an absent side, and a count of 1 without a comma")
    func newFile() {
        let file = UnifiedPatchParser.parse(RealDiffs.newFile)[0]
        #expect(file.oldPath == nil)
        #expect(file.newPath == "src/config.js")
        #expect(file.isAddition)
        #expect(!file.isDeletion)

        let hunk = file.hunks[0]
        #expect(hunk.oldStart == 0)
        #expect(hunk.oldCount == 0)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 1)
    }

    @Test("takes a pure rename's paths from the rename lines, since it has no ---/+++")
    func pureRename() {
        let file = UnifiedPatchParser.parse(RealDiffs.pureRename)[0]
        #expect(file.oldPath == nil)
        #expect(file.newPath == nil)
        #expect(file.renameFrom == "src/helpers.js")
        #expect(file.renameTo == "src/legacy.js")
        #expect(file.hunks.isEmpty)
        #expect(file.displayPath == "src/legacy.js")
    }

    @Test("splits a multi-file diff on its file boundaries")
    func multipleFiles() {
        let combined = RealDiffs.multiHunk + RealDiffs.crlf + RealDiffs.newFile
        let files = UnifiedPatchParser.parse(combined)
        #expect(files.count == 3)
        #expect(files.map(\.displayPath) == ["multi.txt", "crlf.txt", "src/config.js"])
        #expect(files.map { $0.hunks.count } == [3, 1, 1])
    }

    @Test("survives truncated input without inventing hunks")
    func truncated() {
        let truncated = """
            diff --git a/multi.txt b/multi.txt
            --- a/multi.txt
            +++ b/multi.txt
            @@ -1,6 +1,6 @@
             line 1
            """
        let files = UnifiedPatchParser.parse(truncated)
        #expect(files.count == 1)
        #expect(files[0].hunks.count == 1)
        #expect(files[0].hunks[0].lines.count == 1)
    }
}
