import DiffCore

/// A range of rows the user dragged out in the diff, exactly as the renderer
/// reports it.
///
/// The renderer addresses rows by **file line number and side**, not by row
/// index: a `-` row has only an old number, a `+` row only a new one, and a
/// context row has both. That is enough to find the rows again, because
/// ``PatchHunk/lines`` is already in render order — it is the unified diff's own
/// order, which is what is on screen.
struct DiffRowRange: Sendable, Equatable {

    enum Side: String, Sendable, Equatable {
        case deletions
        case additions
    }

    var start: Int
    var startSide: Side
    var end: Int
    var endSide: Side

    /// Decodes the `range` object from the page's `selection` message.
    ///
    /// `side` is optional on the wire — the renderer omits it for a row that
    /// exists on both sides — so it falls back to the additions column, which
    /// is the one a context row is numbered by in a unified view.
    init?(json: [String: Any]) {
        guard let start = json["start"] as? Int, let end = json["end"] as? Int else { return nil }
        self.start = start
        self.end = end
        self.startSide = (json["side"] as? String).flatMap(Side.init(rawValue:)) ?? .additions
        self.endSide = (json["endSide"] as? String).flatMap(Side.init(rawValue:)) ?? self.startSide
    }

    init(start: Int, startSide: Side, end: Int, endSide: Side) {
        self.start = start
        self.startSide = startSide
        self.end = end
        self.endSide = endSide
    }
}

/// What a selection resolves to, once it has been matched against the patch.
struct ResolvedDiffSelection: Sendable, Equatable {

    /// The changed lines inside the range. Context lines are not part of it —
    /// they are in every patch regardless, so selecting them means nothing.
    var lines: PatchSelection = PatchSelection()

    /// Every changed line of every chunk the range touches, which is what the
    /// "whole chunk" action takes.
    var chunks: PatchSelection = PatchSelection()

    /// How many chunks the range reaches into.
    var chunkCount: Int = 0

    var lineCount: Int { lines.additions.count + lines.deletions.count }
    var isEmpty: Bool { lineCount == 0 }
}

extension DiffRowRange {

    /// Matches the range against a parsed file and returns the changed lines it
    /// covers, plus the chunks it touches.
    ///
    /// Both ends are matched independently and then ordered, because a drag
    /// upwards reports its anchor first — `start` is where the pointer went
    /// down, not the top of the selection.
    func resolve(in file: PatchFile) -> ResolvedDiffSelection {
        // One flat list in render order, remembering which chunk each row is in.
        var rows: [(line: PatchLine, hunk: Int)] = []
        for (index, hunk) in file.hunks.enumerated() {
            for line in hunk.lines { rows.append((line, index)) }
        }

        guard
            let first = Self.index(of: start, side: startSide, in: rows),
            let last = Self.index(of: end, side: endSide, in: rows)
        else { return ResolvedDiffSelection() }

        var resolved = ResolvedDiffSelection()
        var touched: Set<Int> = []

        for row in rows[min(first, last)...max(first, last)] {
            switch row.line.kind {
            case .addition: resolved.lines.additions.insert(row.line.newNumber)
            case .deletion: resolved.lines.deletions.insert(row.line.oldNumber)
            case .context: continue
            }
            touched.insert(row.hunk)
        }

        resolved.chunkCount = touched.count
        resolved.chunks = PatchSelection.wholeHunks(touched.sorted().map { file.hunks[$0] })
        return resolved
    }

    /// Finds the row a `(line number, side)` pair names.
    ///
    /// A context row carries both numbers, so it answers to either side; a
    /// change row answers only to its own.
    private static func index(
        of number: Int, side: Side, in rows: [(line: PatchLine, hunk: Int)]
    ) -> Int? {
        rows.firstIndex { row in
            switch side {
            case .deletions: row.line.kind != .addition && row.line.oldNumber == number
            case .additions: row.line.kind != .deletion && row.line.newNumber == number
            }
        }
    }
}
