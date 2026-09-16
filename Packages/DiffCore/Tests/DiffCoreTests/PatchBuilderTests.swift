import Testing

@testable import DiffCore

/// More captured `git diff` output, for the cases the builder has to refuse or
/// treat specially.
extension RealDiffs {

    /// A new file with more than one line, so a *partial* selection of it is
    /// possible at all.
    static let newFileMultiLine = """
        diff --git a/fresh.txt b/fresh.txt
        new file mode 100644
        index 0000000..ff6e6b1
        --- /dev/null
        +++ b/fresh.txt
        @@ -0,0 +1,3 @@
        +first
        +second
        +third

        """

    static let deletedFile = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index ac9837c..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,3 +0,0 @@
        -line 1
        -line 2
        -line 3

        """

    static let binary = """
        diff --git a/bin.dat b/bin.dat
        index 0f49c4a..7ddf242 100644
        Binary files a/bin.dat and b/bin.dat differ

        """
}

@Suite("Patch synthesis")
struct PatchBuilderTests {

    private func file(_ patch: String) -> PatchFile {
        UnifiedPatchParser.parse(patch)[0]
    }

    // MARK: Round trips

    /// The strongest check available without running git: selecting everything
    /// must reproduce what git wrote, byte for byte. Any drift in the header
    /// arithmetic, the `,1` elision or the CRLF handling shows up here.
    @Test(
        "selecting the whole file reproduces git's own output",
        arguments: [
            RealDiffs.multiHunk, RealDiffs.crlf, RealDiffs.noEOL,
            RealDiffs.newFileMultiLine, RealDiffs.deletedFile,
        ]
    )
    func roundTripForward(_ patch: String) throws {
        let parsed = file(patch)
        let built = try PatchBuilder.build(
            file: parsed, selection: .wholeFile(parsed), application: .forward)
        #expect(built == patch)
    }

    /// And the mirror: a full selection is the one case where both directions
    /// have to agree, because nothing is dropped or demoted either way.
    @Test(
        "the reverse direction agrees with the forward one on a full selection",
        arguments: [
            RealDiffs.multiHunk, RealDiffs.crlf, RealDiffs.noEOL,
            RealDiffs.newFileMultiLine, RealDiffs.deletedFile,
        ]
    )
    func roundTripReverse(_ patch: String) throws {
        let parsed = file(patch)
        let built = try PatchBuilder.build(
            file: parsed, selection: .wholeFile(parsed), application: .reverse)
        #expect(built == patch)
    }

    // MARK: Hunk selection

    @Test("dropping an earlier hunk un-shifts the ones after it")
    func hunkOffsets() throws {
        let parsed = file(RealDiffs.multiHunk)

        // Only the last hunk. In git's output it starts at +18, because the
        // middle hunk inserted a line before it. Alone, it starts at +17.
        let built = try PatchBuilder.build(
            file: parsed,
            selection: .wholeHunks([parsed.hunks[2]]),
            application: .forward
        )

        #expect(built.contains("@@ -17,7 +17,7 @@ line 16"))
        #expect(!built.contains("@@ -1,6"))
        #expect(!built.contains("inserted after 10"))
        #expect(built.hasPrefix("diff --git a/multi.txt b/multi.txt\n"))
    }

    @Test("keeps the +18 shift when the hunk that caused it is also selected")
    func hunkOffsetsCumulative() throws {
        let parsed = file(RealDiffs.multiHunk)
        let built = try PatchBuilder.build(
            file: parsed,
            selection: .wholeHunks([parsed.hunks[1], parsed.hunks[2]]),
            application: .forward
        )

        #expect(built.contains("@@ -8,6 +8,7 @@ line 7"))
        #expect(built.contains("@@ -17,7 +18,7 @@ line 16"))
    }

    // MARK: The mirrored line transform

    @Test("forward keeps the old side whole: an unpicked - becomes context")
    func forwardDemotesDeletions() throws {
        let parsed = file(RealDiffs.multiHunk)

        // Stage only the addition of the pair in the first hunk.
        let selection = PatchSelection(additions: [3])
        let built = try PatchBuilder.build(
            file: parsed, selection: selection, application: .forward)

        let body = hunkBody(built)
        #expect(
            body == [
                " line 1", " line 2", " line 3", "+line 3 CHANGED",
                " line 4", " line 5", " line 6",
            ])
        // Six lines on the old side — unchanged — and seven on the new.
        #expect(built.contains("@@ -1,6 +1,7 @@"))
    }

    @Test("forward keeps the old side whole: an unpicked + is dropped")
    func forwardDropsAdditions() throws {
        let parsed = file(RealDiffs.multiHunk)

        // Stage only the deletion of the pair.
        let selection = PatchSelection(deletions: [3])
        let built = try PatchBuilder.build(
            file: parsed, selection: selection, application: .forward)

        let body = hunkBody(built)
        #expect(
            body == [
                " line 1", " line 2", "-line 3", " line 4", " line 5", " line 6",
            ])
        #expect(built.contains("@@ -1,6 +1,5 @@"))
    }

    @Test("reverse mirrors it: an unpicked + becomes context")
    func reverseDemotesAdditions() throws {
        let parsed = file(RealDiffs.multiHunk)

        // Unstage only the deletion of the pair.
        let selection = PatchSelection(deletions: [3])
        let built = try PatchBuilder.build(
            file: parsed, selection: selection, application: .reverse)

        let body = hunkBody(built)
        #expect(
            body == [
                " line 1", " line 2", "-line 3", " line 3 CHANGED",
                " line 4", " line 5", " line 6",
            ])
        // The new side is untouched at six lines; the old side gains one.
        #expect(built.contains("@@ -1,7 +1,6 @@"))
    }

    @Test("reverse mirrors it: an unpicked - is dropped")
    func reverseDropsDeletions() throws {
        let parsed = file(RealDiffs.multiHunk)

        let selection = PatchSelection(additions: [3])
        let built = try PatchBuilder.build(
            file: parsed, selection: selection, application: .reverse)

        let body = hunkBody(built)
        #expect(
            body == [
                " line 1", " line 2", "+line 3 CHANGED", " line 4", " line 5", " line 6",
            ])
        #expect(built.contains("@@ -1,5 +1,6 @@"))
    }

    // MARK: CRLF

    @Test("carries the carriage return through into the synthesised patch")
    func crlfSurvives() throws {
        let parsed = file(RealDiffs.crlf)
        let built = try PatchBuilder.build(
            file: parsed, selection: PatchSelection(additions: [2]), application: .forward)

        #expect(built.contains("+BETA\r\n"))
        #expect(built.contains(" beta\r\n"), "the unpicked deletion keeps its CR as context")
    }

    // MARK: No newline at end of file

    @Test("refuses to turn a line owning a no-newline marker into context")
    func noNewlineIsNotSplittable() {
        let parsed = file(RealDiffs.noEOL)

        // Picking only the additions would demote `-three`, which owns a
        // marker — asserting both sides end without a newline there, which is
        // exactly what the marker says is untrue.
        #expect(throws: PatchBuildError.noNewlineNotSplittable) {
            try PatchBuilder.build(
                file: parsed,
                selection: PatchSelection(additions: [2, 3]),
                application: .forward
            )
        }
    }

    @Test("allows a partial selection that only drops the marker's line")
    func noNewlineDroppedIsFine() throws {
        let parsed = file(RealDiffs.noEOL)

        // The additions are dropped whole, markers and all; nothing is demoted.
        let built = try PatchBuilder.build(
            file: parsed,
            selection: PatchSelection(deletions: [2, 3]),
            application: .forward
        )

        #expect(built.contains("@@ -1,3 +1 @@"))
        #expect(built.contains("-three\n\\ No newline at end of file\n"))
        #expect(!built.contains("three changed"))
    }

    @Test("a full selection keeps both markers where git put them")
    func noNewlineFullSelection() throws {
        let parsed = file(RealDiffs.noEOL)
        let built = try PatchBuilder.build(
            file: parsed, selection: .wholeFile(parsed), application: .forward)
        #expect(built == RealDiffs.noEOL)
    }

    // MARK: Refusals

    @Test("a partial selection cannot contradict a whole-file create or delete")
    func wholeFileOnly() {
        let addition = file(RealDiffs.newFileMultiLine)
        // Forward is fine — the old side stays empty either way.
        #expect(throws: Never.self) {
            try PatchBuilder.build(
                file: addition, selection: PatchSelection(additions: [1]), application: .forward)
        }
        // Reverse is not: the result would have to be an empty file that has
        // two lines in it.
        #expect(throws: PatchBuildError.wholeFileOnly) {
            try PatchBuilder.build(
                file: addition, selection: PatchSelection(additions: [1]), application: .reverse)
        }

        let deletion = file(RealDiffs.deletedFile)
        #expect(throws: PatchBuildError.wholeFileOnly) {
            try PatchBuilder.build(
                file: deletion, selection: PatchSelection(deletions: [1]), application: .forward)
        }
    }

    @Test("refuses a binary file, an empty selection and a selection that hits nothing")
    func refusals() {
        #expect(throws: PatchBuildError.binaryFile) {
            try PatchBuilder.build(
                file: file(RealDiffs.binary), selection: PatchSelection(additions: [1]),
                application: .forward)
        }

        let parsed = file(RealDiffs.multiHunk)
        #expect(throws: PatchBuildError.nothingSelected) {
            try PatchBuilder.build(
                file: parsed, selection: PatchSelection(), application: .forward)
        }
        #expect(throws: PatchBuildError.nothingSelected) {
            try PatchBuilder.build(
                file: parsed, selection: PatchSelection(additions: [9999]), application: .forward)
        }
    }

    @Test("a pure rename has no hunks, so there is nothing to build from")
    func pureRename() {
        let parsed = file(RealDiffs.pureRename)
        #expect(throws: PatchBuildError.nothingSelected) {
            try PatchBuilder.build(
                file: parsed, selection: .wholeFile(parsed), application: .forward)
        }
    }

    // MARK: Helper

    /// The lines of the first hunk body in a built patch, markers included.
    private func hunkBody(_ patch: String) -> [String] {
        let lines = UnifiedPatchParser.splitLines(patch)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("@@") }) else { return [] }
        var body: [String] = []
        for line in lines[lines.index(after: start)...] {
            if line.hasPrefix("@@") || line.isEmpty { break }
            body.append(String(line))
        }
        return body
    }
}
