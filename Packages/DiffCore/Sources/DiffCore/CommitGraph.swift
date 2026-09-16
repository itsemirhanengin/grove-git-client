/// Lane assignment for a commit graph.
///
/// Given commits in the order they will be drawn — newest first, topologically
/// ordered, each knowing its parents — this works out which column each commit's
/// dot sits in and which lines cross each row. It is the same model gitk and
/// GitX use, and it lives here rather than in a view because it is arithmetic
/// over strings: no framework, no drawing, and fully testable.
///
/// Nothing here compacts lanes. A column freed by a merge stays free until
/// something needs it, which keeps a branch on a stable column for its whole
/// life instead of sliding sideways every time an unrelated branch ends.

/// One row of the rail.
public struct CommitGraphRow: Sendable, Equatable {

    /// A line crossing this row, from a column at its top edge to a column at
    /// its bottom edge.
    public struct Link: Sendable, Equatable {
        /// Column where the line enters, at the top of the row.
        public var from: Int
        /// Column where it leaves, at the bottom.
        public var to: Int
        /// The line meets this row's dot, rather than running past it.
        ///
        /// A pass-through is a branch that exists on both sides of this commit
        /// and has nothing to do with it — drawn straight, and dimmer.
        public var touchesCommit: Bool

        public init(from: Int, to: Int, touchesCommit: Bool) {
            self.from = from
            self.to = to
            self.touchesCommit = touchesCommit
        }
    }

    /// Column the commit's dot sits in.
    public var lane: Int

    public var links: [Link]

    /// Columns in use at this row, counting both edges. What the rail has to be
    /// wide enough to draw.
    public var width: Int

    public init(lane: Int, links: [Link], width: Int) {
        self.lane = lane
        self.links = links
        self.width = width
    }
}

/// What the graph needs to know about a commit. Deliberately not the commit
/// model itself — this package has no opinion about authors or dates.
public struct CommitGraphNode: Sendable, Equatable {
    public var id: String
    public var parents: [String]

    public init(id: String, parents: [String]) {
        self.id = id
        self.parents = parents
    }
}

public enum CommitGraph {

    /// Beyond this many columns the rail stops being a picture and starts being
    /// a wall. Extra branches are folded into the last column rather than
    /// widening the list forever.
    public static let maximumLanes = 12

    /// Lays out one page of history.
    ///
    /// - Parameter nodes: newest first, in the order they will be drawn.
    public static func layout(_ nodes: [CommitGraphNode]) -> [CommitGraphRow] {
        /// For each column, the commit id that column is currently waiting for.
        /// `nil` is a free column.
        var lanes: [String?] = []
        var rows: [CommitGraphRow] = []
        rows.reserveCapacity(nodes.count)

        for node in nodes {
            let top = lanes

            // Every column waiting for this commit converges on it. There is
            // more than one whenever several children share a parent.
            let arriving = lanes.indices.filter { lanes[$0] == node.id }

            // A commit nothing is waiting for is a tip: the newest commit, or a
            // branch head whose children are not on this page.
            let lane = arriving.first ?? freeLane(in: &lanes)

            // The first parent continues in this commit's own column, which is
            // what keeps a branch on one line for its whole length.
            lanes[lane] = node.parents.first
            for index in arriving where index != lane { lanes[index] = nil }

            var links: [Link] = []

            // Lines coming down into this row.
            for index in top.indices {
                guard let waiting = top[index] else { continue }
                if waiting == node.id {
                    links.append(Link(from: index, to: lane, touchesCommit: true))
                } else if let destination = lanes.firstIndex(of: waiting) {
                    // Running past. Its column does not move, but it is looked
                    // up rather than assumed — an assumption here is how a rail
                    // ends up drawing lines to the wrong branch.
                    links.append(Link(from: index, to: destination, touchesCommit: false))
                }
            }

            // …and lines leaving it. The first parent leaves straight down.
            if node.parents.first != nil {
                links.append(Link(from: lane, to: lane, touchesCommit: true))
            }

            // A merge's other parents fork off sideways, reusing a column that
            // is already waiting for that parent where one exists — otherwise
            // two lines would run to the same commit.
            for parent in node.parents.dropFirst() {
                let destination = lanes.firstIndex(of: parent) ?? freeLane(in: &lanes)
                lanes[destination] = parent
                links.append(Link(from: lane, to: destination, touchesCommit: true))
            }

            rows.append(
                CommitGraphRow(
                    lane: lane,
                    links: links,
                    width: max(usedWidth(top), usedWidth(lanes), lane + 1)
                )
            )
        }

        return rows
    }

    private typealias Link = CommitGraphRow.Link

    /// The lowest free column, appending one if every column is taken.
    ///
    /// Lowest rather than next, so a branch that ends gives its column back to
    /// the next branch that starts instead of the rail creeping rightwards.
    private static func freeLane(in lanes: inout [String?]) -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
        guard lanes.count < maximumLanes else {
            // Out of room. Everything further right shares the last column,
            // which draws a slightly wrong picture rather than an unreadably
            // wide one.
            return lanes.count - 1
        }
        lanes.append(nil)
        return lanes.count - 1
    }

    private static func usedWidth(_ lanes: [String?]) -> Int {
        (lanes.lastIndex(where: { $0 != nil }).map { $0 + 1 }) ?? 0
    }
}
