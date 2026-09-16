import DiffCore
import Testing

@testable import Grove

/// Turning "the user dragged from here to there" into "these changed lines".
///
/// The renderer names rows by file line number and side, never by row index, so
/// this mapping is the only thing that knows a `-` row and a `+` row with the
/// same number are two different rows.
@Suite("Diff row selection")
struct DiffSelectionTests {

    /// Captured `git diff` output: one hunk, one changed line, context around it.
    private static let patch = """
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

    private var file: PatchFile { UnifiedPatchParser.parse(Self.patch)[0] }

    @Test("a range over a whole chunk picks both sides of the change")
    func wholeChunk() {
        let range = DiffRowRange(start: 1, startSide: .additions, end: 6, endSide: .additions)
        let resolved = range.resolve(in: file)

        #expect(resolved.lines.additions == [3])
        #expect(resolved.lines.deletions == [3])
        #expect(resolved.lineCount == 2)
        #expect(resolved.chunkCount == 1)
    }

    @Test("a single deletion row picks only the deletion")
    func singleDeletion() {
        let range = DiffRowRange(start: 3, startSide: .deletions, end: 3, endSide: .deletions)
        let resolved = range.resolve(in: file)

        #expect(resolved.lines.deletions == [3])
        #expect(resolved.lines.additions.isEmpty)
    }

    /// The same *number* on the other side is a different row. Getting this
    /// wrong stages the half the user did not click.
    @Test("a single addition row picks only the addition")
    func singleAddition() {
        let range = DiffRowRange(start: 3, startSide: .additions, end: 3, endSide: .additions)
        let resolved = range.resolve(in: file)

        #expect(resolved.lines.additions == [3])
        #expect(resolved.lines.deletions.isEmpty)
    }

    @Test("context lines contribute nothing — they are in every patch anyway")
    func contextOnly() {
        let range = DiffRowRange(start: 1, startSide: .additions, end: 2, endSide: .additions)
        #expect(range.resolve(in: file).isEmpty)
    }

    @Test("a drag upwards reports its anchor first, and still selects the span")
    func reversedDrag() {
        let downwards = DiffRowRange(start: 2, startSide: .additions, end: 4, endSide: .additions)
        let upwards = DiffRowRange(start: 4, startSide: .additions, end: 2, endSide: .additions)
        #expect(downwards.resolve(in: file) == upwards.resolve(in: file))
    }

    @Test("a range spanning two chunks reports both, and offers all of both")
    func acrossChunks() {
        let range = DiffRowRange(start: 3, startSide: .deletions, end: 21, endSide: .additions)
        let resolved = range.resolve(in: file)

        #expect(resolved.chunkCount == 2)
        #expect(resolved.lines.deletions == [3, 20])
        #expect(resolved.lines.additions == [3, 21])
        // "Take the whole chunk" reaches the same set here, because the range
        // already covers every change in both.
        #expect(resolved.chunks == resolved.lines)
    }

    @Test("the chunk action widens a one-line pick to everything in that chunk")
    func chunkWidensSelection() {
        let range = DiffRowRange(start: 3, startSide: .additions, end: 3, endSide: .additions)
        let resolved = range.resolve(in: file)

        #expect(resolved.lines == PatchSelection(additions: [3]))
        #expect(resolved.chunks == PatchSelection(additions: [3], deletions: [3]))
    }

    @Test("a range naming rows that are not in this diff resolves to nothing")
    func unknownRows() {
        let range = DiffRowRange(start: 900, startSide: .additions, end: 901, endSide: .additions)
        #expect(range.resolve(in: file).isEmpty)
    }

    @Test("decodes the renderer's range object, side and all")
    func decoding() {
        let decoded = DiffRowRange(json: ["start": 3, "side": "deletions", "end": 4])
        #expect(decoded?.start == 3)
        #expect(decoded?.startSide == .deletions)
        #expect(decoded?.end == 4)
        // No `endSide` on the wire means the drag never left the column it
        // started in.
        #expect(decoded?.endSide == .deletions)

        #expect(DiffRowRange(json: ["side": "additions"]) == nil)
    }
}
