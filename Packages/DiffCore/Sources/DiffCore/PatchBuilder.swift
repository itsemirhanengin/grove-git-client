/// Turns a *subset* of a parsed diff back into a patch `git apply` accepts.
///
/// This is the whole point of ``UnifiedPatchParser``. Everything else about a
/// diff — colour, alignment, syntax — is the renderer's job; only this has to
/// go back to git, byte for byte.

// MARK: - Selection

/// Which changed lines the user picked, addressed the way the renderer reports
/// them: by line number and side.
///
/// Line numbers rather than indices on purpose. The web layer reports a
/// selection as a range of rendered rows with a side, and an index into a hunk
/// body is a number only Swift knows — it would have to be invented, sent, and
/// kept in sync through every re-render.
public struct PatchSelection: Sendable, Equatable {

    /// New-side line numbers of selected `+` lines.
    public var additions: Set<Int>

    /// Old-side line numbers of selected `-` lines.
    public var deletions: Set<Int>

    public init(additions: Set<Int> = [], deletions: Set<Int> = []) {
        self.additions = additions
        self.deletions = deletions
    }

    public var isEmpty: Bool { additions.isEmpty && deletions.isEmpty }

    /// How many changed lines are picked, across both sides.
    public var count: Int { additions.count + deletions.count }

    public func contains(_ line: PatchLine) -> Bool {
        switch line.kind {
        case .context: false
        case .addition: additions.contains(line.newNumber)
        case .deletion: deletions.contains(line.oldNumber)
        }
    }

    /// Every change line in the given hunks — what a "stage chunk" button picks.
    public static func wholeHunks(_ hunks: [PatchHunk]) -> PatchSelection {
        var selection = PatchSelection()
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .addition: selection.additions.insert(line.newNumber)
                case .deletion: selection.deletions.insert(line.oldNumber)
                case .context: break
                }
            }
        }
        return selection
    }

    /// Every change line in the file.
    public static func wholeFile(_ file: PatchFile) -> PatchSelection {
        wholeHunks(file.hunks)
    }

    public static func forRange(
        _ hunks: [PatchHunk],
        additions: ClosedRange<Int>? = nil,
        deletions: ClosedRange<Int>? = nil
    ) -> PatchSelection {
        var selection = PatchSelection()
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .addition:
                    if additions?.contains(line.newNumber) == true {
                        selection.additions.insert(line.newNumber)
                    }
                case .deletion:
                    if deletions?.contains(line.oldNumber) == true {
                        selection.deletions.insert(line.oldNumber)
                    }
                case .context:
                    break
                }
            }
        }
        return selection
    }
}

// MARK: - Direction

/// How the synthesised patch will be handed to `git apply`.
///
/// This is *not* a property of the operation's name — it is which side of the
/// patch has to match the thing being patched, and getting it backwards yields
/// "patch does not apply", or worse, a silently wrong index.
///
/// | operation | diff source        | application | target      |
/// |-----------|--------------------|-------------|-------------|
/// | stage     | `git diff`         | `.forward`  | `--cached`  |
/// | unstage   | `git diff --cached`| `.reverse`  | `--cached`  |
/// | discard   | `git diff`         | `.reverse`  | worktree    |
///
/// Note that discard is `.reverse` even though its diff is the same one staging
/// uses: `git apply -R` matches the patch's **new** side against the file, and
/// for a discard that file is the worktree, which is the new side.
public enum PatchApplication: Sendable, Equatable {
    /// `git apply` — the patch's **old** side must reproduce the target
    /// exactly, so an unselected `-` becomes context and an unselected `+` is
    /// dropped.
    case forward
    /// `git apply -R` — the patch's **new** side must reproduce the target
    /// exactly, so the transform is mirrored: an unselected `+` becomes context
    /// and an unselected `-` is dropped.
    case reverse
}

public enum PatchBuildError: Error, Sendable, Equatable {
    /// No change line was selected, so there is no patch to build.
    case nothingSelected
    /// A binary file has no lines to select.
    case binaryFile
    /// A combined diff, from a conflicted file. Resolve the conflict first.
    case combinedDiff
    /// A partial selection would have had to turn a line that owns a
    /// `\ No newline at end of file` marker into context.
    ///
    /// That would assert both sides lack the trailing newline, which is exactly
    /// what the marker says is not true, and produces a patch git rejects — or
    /// applies into a file with a newline nobody asked for. Stage the whole
    /// chunk instead.
    case noNewlineNotSplittable
    /// The header says the file is created or removed in full, and a partial
    /// selection contradicts it.
    case wholeFileOnly
}

// MARK: - Builder

public enum PatchBuilder {

    /// Builds a patch containing only the selected lines.
    ///
    /// Always run the result through `git apply --check` before applying it.
    /// The transform below is mirror-symmetric and a mistake in it is invisible
    /// until the index is already wrong.
    public static func build(
        file: PatchFile,
        selection: PatchSelection,
        application: PatchApplication
    ) throws -> String {
        guard !file.isBinary else { throw PatchBuildError.binaryFile }
        guard !file.isCombined else { throw PatchBuildError.combinedDiff }
        guard !selection.isEmpty else { throw PatchBuildError.nothingSelected }

        var body = ""
        var offset = 0
        var emittedHunks = 0

        for hunk in file.hunks {
            let changes = hunk.lines.count(where: \.isChange)
            let picked = hunk.lines.count { $0.isChange && selection.contains($0) }
            guard picked > 0 else { continue }

            let isPartial = picked < changes
            if isPartial {
                // A creation or a removal is all-or-nothing in one direction:
                // the side the header declares empty would come out non-empty.
                if application == .forward && file.isDeletion {
                    throw PatchBuildError.wholeFileOnly
                }
                if application == .reverse && file.isAddition {
                    throw PatchBuildError.wholeFileOnly
                }
            }

            let emitted = try transform(hunk, selection, application)

            let oldCount = emitted.count { $0.kind != .addition }
            let newCount = emitted.count { $0.kind != .deletion }

            // Exactly one side is preserved verbatim — the side `git apply`
            // matches against the target. The other side is what the patch
            // produces, so its start has to absorb what earlier hunks in *this*
            // patch did, not what the original diff's hunks did.
            let oldStart: Int
            let newStart: Int
            switch application {
            case .forward:
                oldStart = hunk.oldStart
                newStart = shifted(
                    anchor: hunk.oldStart, anchorCount: oldCount, ownCount: newCount,
                    offset: offset)
                offset += newCount - oldCount
            case .reverse:
                newStart = hunk.newStart
                oldStart = shifted(
                    anchor: hunk.newStart, anchorCount: newCount, ownCount: oldCount,
                    offset: offset)
                offset += oldCount - newCount
            }

            body += "@@ -\(span(oldStart, oldCount)) +\(span(newStart, newCount)) @@"
            body += hunk.heading
            body += "\n"

            for line in emitted {
                body.append(line.kind.marker)
                body += line.content
                body += "\n"
                if line.noNewlineAfter { body += "\\ No newline at end of file\n" }
            }

            emittedHunks += 1
        }

        guard emittedHunks > 0 else { throw PatchBuildError.nothingSelected }

        // Verbatim, including the mode, rename and `index` lines. Anything
        // rebuilt here is a second opinion about what git already said.
        var patch = ""
        for line in file.headerLines {
            patch += line
            patch += "\n"
        }
        return patch + body
    }

    // MARK: Transform

    /// The mirrored core of line staging.
    ///
    /// ```text
    /// FORWARD  (git apply)       ' ' → ' '   '+' in S → '+'   '+' not in S → DROP
    ///                                        '-' in S → '-'   '-' not in S → ' '
    ///
    /// REVERSE  (git apply -R)    ' ' → ' '   '-' in S → '-'   '-' not in S → DROP
    ///                                        '+' in S → '+'   '+' not in S → ' '
    /// ```
    ///
    /// Read it as: whichever side has to match the file keeps all of its lines;
    /// the other side keeps only what was picked.
    private static func transform(
        _ hunk: PatchHunk,
        _ selection: PatchSelection,
        _ application: PatchApplication
    ) throws -> [PatchLine] {
        let dropped: PatchLine.Kind = application == .forward ? .addition : .deletion

        var emitted: [PatchLine] = []
        emitted.reserveCapacity(hunk.lines.count)

        for line in hunk.lines {
            if line.kind == .context || selection.contains(line) {
                emitted.append(line)
                continue
            }
            if line.kind == dropped { continue }

            // Turning this line into context asserts that both sides end
            // without a newline here, which is the one thing its marker says is
            // false. Refuse rather than synthesise a patch that will not apply.
            if line.noNewlineAfter { throw PatchBuildError.noNewlineNotSplittable }

            var context = line
            context.kind = .context
            emitted.append(context)
        }

        return emitted
    }

    // MARK: Header arithmetic

    /// Where the produced side of a hunk starts, once earlier hunks in this
    /// patch have shifted it.
    ///
    /// Git writes a zero-length side's start as the line *before* the change
    /// rather than the line at it — `@@ -0,0 +1 @@` for a new file — so the two
    /// degenerate cases each need their own adjustment.
    private static func shifted(anchor: Int, anchorCount: Int, ownCount: Int, offset: Int) -> Int {
        if ownCount == 0 { return anchor + offset - 1 }
        if anchorCount == 0 { return anchor + offset + 1 }
        return anchor + offset
    }

    /// `12,3`, or just `12` when the count is 1 — which is how git writes it,
    /// and matching it lets a full selection round-trip byte for byte.
    private static func span(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }
}
