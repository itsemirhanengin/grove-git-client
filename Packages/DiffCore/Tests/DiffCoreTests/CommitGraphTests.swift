import Testing

@testable import DiffCore

@Suite("Commit graph layout")
struct CommitGraphTests {

    private func node(_ id: String, _ parents: String...) -> CommitGraphNode {
        CommitGraphNode(id: id, parents: parents)
    }

    // MARK: Linear

    @Test("a straight history stays in one column")
    func linear() {
        let rows = CommitGraph.layout([
            node("c", "b"),
            node("b", "a"),
            node("a"),
        ])

        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.width) == [1, 1, 1])

        // The newest commit has nothing above it, so its only line leaves
        // downwards; the oldest has no parent, so its only line arrives.
        #expect(rows[0].links == [.init(from: 0, to: 0, touchesCommit: true)])
        #expect(rows[2].links == [.init(from: 0, to: 0, touchesCommit: true)])
        #expect(rows[1].links.count == 2)
    }

    @Test("the root of the page has no line leaving it")
    func rootHasNoOutgoingLink() {
        let rows = CommitGraph.layout([node("b", "a"), node("a")])
        // `a` has no parents: the line into it arrives, and nothing continues.
        #expect(rows[1].links == [.init(from: 0, to: 0, touchesCommit: true)])
    }

    // MARK: Branch and merge

    /// ```text
    ///  m      merge of feature into main
    ///  |\
    ///  | f    the feature commit
    ///  |/
    ///  b      their common parent
    /// ```
    @Test("a merge forks a second column and the branch rejoins it")
    func mergeAndRejoin() {
        let rows = CommitGraph.layout([
            node("m", "b", "f"),
            node("f", "b"),
            node("b", "a"),
            node("a"),
        ])

        #expect(rows[0].lane == 0, "the merge stays on the first parent's line")
        #expect(rows[1].lane == 1, "the second parent gets its own column")
        #expect(rows[2].lane == 0, "and the shared parent is back on the first")

        // The merge sends one line straight down to `b` and one across to `f`.
        #expect(rows[0].links.contains(.init(from: 0, to: 0, touchesCommit: true)))
        #expect(rows[0].links.contains(.init(from: 0, to: 1, touchesCommit: true)))
        #expect(rows[0].width == 2)

        // `b` is waited for by both columns, so both arrive at its dot.
        let arriving = rows[2].links.filter(\.touchesCommit)
        #expect(arriving.contains(.init(from: 0, to: 0, touchesCommit: true)))
        #expect(arriving.contains(.init(from: 1, to: 0, touchesCommit: true)))

        // And the second column is free again below it.
        #expect(rows[3].width == 1)
    }

    /// A branch that is still open at the bottom of the page keeps its column,
    /// and the commits beside it are drawn as running past.
    @Test("an unrelated branch runs past a commit without touching it")
    func passesThrough() {
        let rows = CommitGraph.layout([
            node("x", "w"),  // tip of a branch that never merges here
            node("c", "b"),
            node("b", "a"),
            node("a"),
        ])

        #expect(rows[0].lane == 0)
        #expect(rows[1].lane == 1, "a second tip needs its own column")

        // On `c`'s row, `x`'s line runs straight past.
        let passing = rows[1].links.filter { !$0.touchesCommit }
        #expect(passing == [.init(from: 0, to: 0, touchesCommit: false)])
    }

    // MARK: Awkward shapes

    @Test("an octopus merge forks a column per extra parent")
    func octopus() {
        let rows = CommitGraph.layout([
            node("o", "a", "b", "c"),
            node("a"),
            node("b"),
            node("c"),
        ])

        #expect(rows[0].lane == 0)
        #expect(rows[0].width == 3)

        let leaving = rows[0].links.filter(\.touchesCommit)
        #expect(leaving.contains(.init(from: 0, to: 0, touchesCommit: true)))
        #expect(leaving.contains(.init(from: 0, to: 1, touchesCommit: true)))
        #expect(leaving.contains(.init(from: 0, to: 2, touchesCommit: true)))
    }

    /// Two children of one commit must not each claim a column for it, or the
    /// rail draws two lines into the same dot from the same side.
    @Test("two branches sharing a parent converge on one column")
    func sharedParent() {
        let rows = CommitGraph.layout([
            node("x", "base"),
            node("y", "base"),
            node("base"),
        ])

        #expect(rows[0].lane == 0)
        #expect(rows[1].lane == 1)
        #expect(rows[2].lane == 0, "the first column that wanted it wins")

        let arriving = rows[2].links.filter(\.touchesCommit)
        #expect(arriving.count == 2)
        #expect(arriving.contains(.init(from: 1, to: 0, touchesCommit: true)))
    }

    /// Order matters here: history is topological, so every child appears above
    /// its parents. `t` is a child of `a`, so it comes *before* `a`, not after.
    @Test("a column freed by a finished branch is reused rather than growing the rail")
    func lanesAreReused() {
        let rows = CommitGraph.layout([
            node("m", "b", "f"),
            node("f", "b"),
            node("b", "a"),
            // A second tip, appearing after the feature branch has closed. It
            // should take the column `f` gave back rather than a third one.
            node("t", "a"),
            node("a"),
        ])

        #expect(rows.map(\.width).max() == 2, "the rail never needs a third column")
        #expect(rows[3].lane == 1)
        #expect(rows[4].lane == 0, "and both columns converge on the shared parent")
    }

    /// Unrelated roots are not a branch — nothing is waiting for them and
    /// nothing follows, so they each take the first free column, which is the
    /// same one every time.
    @Test("unrelated roots reuse the first column and draw no lines")
    func multipleRoots() {
        let rows = CommitGraph.layout([node("a"), node("b"), node("c")])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.width) == [1, 1, 1])
        let noLines = rows.allSatisfy { $0.links.isEmpty }
        #expect(noLines, "a root with no parents and no children has nothing to draw")
    }

    // MARK: Limits

    @Test("the rail stops widening past the maximum, rather than growing forever")
    func laneCeiling() {
        // Far more simultaneous tips than the ceiling allows.
        let nodes = (0..<(CommitGraph.maximumLanes + 8)).map {
            CommitGraphNode(id: "tip\($0)", parents: ["shared"])
        }
        let rows = CommitGraph.layout(nodes + [CommitGraphNode(id: "shared", parents: [])])

        let widthsFit = rows.allSatisfy { $0.width <= CommitGraph.maximumLanes }
        let lanesFit = rows.allSatisfy { $0.lane < CommitGraph.maximumLanes }
        #expect(widthsFit)
        #expect(lanesFit)
    }

    @Test("an empty page lays out to nothing")
    func empty() {
        #expect(CommitGraph.layout([]).isEmpty)
    }
}
