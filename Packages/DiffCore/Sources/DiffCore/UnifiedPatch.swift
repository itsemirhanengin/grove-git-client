/// A parser for git's own `diff --git` output, scoped to one job: turning a
/// *subset* of a diff back into a patch `git apply` accepts.
///
/// It is deliberately not a general-purpose diff model. The renderer already
/// understands git's format and draws from it; this exists because a patch has
/// to go back to *git*, which the web layer cannot do.
///
/// The one rule that makes it correct: **hunk bodies are consumed by counting
/// from the `@@` header, never by sniffing line prefixes.** A diff of a diff
/// contains context lines that begin with `diff --git` and `@@`, and a parser
/// that sniffs prefixes loses sync there for the rest of the file. `git apply`
/// counts, so counting is what makes synthesised patches apply.

// MARK: - Model

/// One line inside a hunk body.
public struct PatchLine: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// A ` ` line — present on both sides.
        case context
        /// A `+` line — present only on the new side.
        case addition
        /// A `-` line — present only on the old side.
        case deletion

        /// The character this line is written with in a unified diff.
        public var marker: Character {
            switch self {
            case .context: " "
            case .addition: "+"
            case .deletion: "-"
            }
        }
    }

    public var kind: Kind

    /// The line's text, without its leading marker and without the newline.
    ///
    /// A `\r` from a CRLF file is **part of this**, and re-emitting it is not
    /// optional: `git apply` compares bytes, and a patch that silently drops
    /// the carriage return does not apply to a CRLF file.
    public var content: Substring

    /// 1-based line number on the old side, or `0` for an addition.
    public var oldNumber: Int

    /// 1-based line number on the new side, or `0` for a deletion.
    public var newNumber: Int

    /// A `\ No newline at end of file` marker followed this line.
    ///
    /// Load-bearing for line staging: see ``PatchBuildError/noNewlineNotSplittable``.
    public var noNewlineAfter: Bool

    public init(
        kind: Kind,
        content: Substring,
        oldNumber: Int,
        newNumber: Int,
        noNewlineAfter: Bool = false
    ) {
        self.kind = kind
        self.content = content
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.noNewlineAfter = noNewlineAfter
    }

    public var isChange: Bool { kind != .context }
}

/// One `@@ … @@` block.
public struct PatchHunk: Sendable, Equatable {

    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int

    /// Everything after the closing `@@`, **including its leading space** — the
    /// function name git found. Kept verbatim so a re-emitted header is byte
    /// identical to git's.
    public var heading: Substring

    public var lines: [PatchLine]

    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        heading: Substring,
        lines: [PatchLine]
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.heading = heading
        self.lines = lines
    }

    /// The `+` and `-` lines, in order. These are what a selection picks from.
    public var changeLines: [PatchLine] { lines.filter(\.isChange) }

    public var additionCount: Int { lines.count { $0.kind == .addition } }
    public var deletionCount: Int { lines.count { $0.kind == .deletion } }
}

/// One file's diff.
public struct PatchFile: Sendable, Equatable {

    /// Every line from `diff --git` up to the first `@@`, verbatim.
    ///
    /// Copied into a synthesised patch **unchanged**. It carries the mode,
    /// rename and `index` lines, and rebuilding any of them is a way to
    /// disagree with git for no gain.
    public var headerLines: [Substring]

    /// Path on the old side, or `nil` when the header says `/dev/null` — i.e.
    /// the file is being created.
    public var oldPath: Substring?

    /// Path on the new side, or `nil` for `/dev/null` — i.e. a deletion.
    public var newPath: Substring?

    /// From `rename from` / `rename to`. A 100 %-similar rename emits **no**
    /// `---`/`+++` lines at all, so for those this is the only source of paths.
    public var renameFrom: Substring?
    public var renameTo: Substring?

    /// `Binary files … differ`, or a `GIT binary patch` body.
    public var isBinary: Bool

    /// A combined diff (`diff --cc`), which a conflicted file produces. Its
    /// hunks have two marker columns and `@@@` headers; nothing here parses
    /// them, and staging from one is refused rather than guessed at.
    public var isCombined: Bool

    public var hunks: [PatchHunk]

    public init(
        headerLines: [Substring],
        oldPath: Substring?,
        newPath: Substring?,
        renameFrom: Substring? = nil,
        renameTo: Substring? = nil,
        isBinary: Bool = false,
        isCombined: Bool = false,
        hunks: [PatchHunk]
    ) {
        self.headerLines = headerLines
        self.oldPath = oldPath
        self.newPath = newPath
        self.renameFrom = renameFrom
        self.renameTo = renameTo
        self.isBinary = isBinary
        self.isCombined = isCombined
        self.hunks = hunks
    }

    /// The path to show for this file: the new one where there is one.
    public var displayPath: Substring? {
        newPath ?? renameTo ?? oldPath ?? renameFrom
    }

    /// The file is being created — there is nothing on the old side.
    public var isAddition: Bool { oldPath == nil && renameFrom == nil }

    /// The file is being removed — there is nothing on the new side.
    public var isDeletion: Bool { newPath == nil && renameTo == nil }
}

// MARK: - Parser

public enum UnifiedPatchParser {

    /// Parses git's diff output into files and hunks.
    ///
    /// Never throws. Malformed input yields fewer files or fewer hunks rather
    /// than an error, because the caller's next move is the same either way:
    /// offer whole-file staging instead of line staging.
    public static func parse(_ text: String) -> [PatchFile] {
        let lines = splitLines(text)

        var files: [PatchFile] = []
        var index = 0

        while index < lines.count {
            guard isFileStart(lines[index]) else {
                index += 1
                continue
            }
            files.append(parseFile(lines, &index))
        }

        return files
    }

    /// Splits on the newline **byte**, not on `Character("\n")`.
    ///
    /// This is not a stylistic choice. In Swift `"\r\n"` is a single extended
    /// grapheme cluster, so `split(separator: "\n")` never sees a separator in
    /// a CRLF file — the whole diff comes back as one line and every hunk after
    /// the first CRLF line is lost. A patch is bytes; it has to be cut on bytes.
    static func splitLines(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        let utf8 = text.utf8
        var start = text.startIndex
        var index = utf8.startIndex

        while index < utf8.endIndex {
            if utf8[index] == 0x0A {
                lines.append(text[start..<index])
                start = utf8.index(after: index)
            }
            index = utf8.index(after: index)
        }
        // Whatever follows the last newline. A patch normally ends with one, in
        // which case there is nothing here — that is an absent line, not an
        // empty one.
        if start < text.endIndex { lines.append(text[start...]) }
        return lines
    }

    private static func isFileStart(_ line: Substring) -> Bool {
        line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ")
            || line.hasPrefix("diff --combined ")
    }

    private static func parseFile(_ lines: [Substring], _ index: inout Int) -> PatchFile {
        let start = index
        let isCombined = !lines[index].hasPrefix("diff --git ")
        index += 1

        var oldPath: Substring?
        var newPath: Substring?
        var renameFrom: Substring?
        var renameTo: Substring?
        var isBinary = false

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@@") || isFileStart(line) { break }

            if line.hasPrefix("--- ") {
                oldPath = path(fromHeader: line, stripping: "a/")
            } else if line.hasPrefix("+++ ") {
                newPath = path(fromHeader: line, stripping: "b/")
            } else if line.hasPrefix("rename from ") {
                renameFrom = line.dropFirst("rename from ".count)
            } else if line.hasPrefix("rename to ") {
                renameTo = line.dropFirst("rename to ".count)
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            }
            index += 1
        }

        let headerLines = Array(lines[start..<index])

        var hunks: [PatchHunk] = []
        if !isCombined && !isBinary {
            while index < lines.count, lines[index].hasPrefix("@@") {
                guard let hunk = parseHunk(lines, &index) else { break }
                hunks.append(hunk)
            }
        }

        // Anything left over before the next file — a binary payload, or a
        // combined diff's body — is skipped without interpretation.
        while index < lines.count, !isFileStart(lines[index]) {
            index += 1
        }

        return PatchFile(
            headerLines: headerLines,
            oldPath: oldPath,
            newPath: newPath,
            renameFrom: renameFrom,
            renameTo: renameTo,
            isBinary: isBinary,
            isCombined: isCombined,
            hunks: hunks
        )
    }

    /// `--- a/src/x.js` → `src/x.js`; `--- /dev/null` → `nil`.
    ///
    /// Every invocation runs under `diff.noprefix=false` and
    /// `diff.mnemonicPrefix=false`, so the prefix is always exactly `a/` or
    /// `b/` — which is the only reason stripping it blindly is safe.
    private static func path(fromHeader line: Substring, stripping prefix: String) -> Substring? {
        let value = line.dropFirst(4)
        if value == "/dev/null" { return nil }
        guard value.hasPrefix(prefix) else { return value }
        return value.dropFirst(prefix.count)
    }

    // MARK: Hunks

    private static func parseHunk(_ lines: [Substring], _ index: inout Int) -> PatchHunk? {
        guard let header = parseHunkHeader(lines[index]) else { return nil }
        index += 1

        var body: [PatchLine] = []
        var oldRemaining = header.oldCount
        var newRemaining = header.newCount
        var oldNumber = header.oldStart
        var newNumber = header.newStart

        while index < lines.count, oldRemaining > 0 || newRemaining > 0 {
            let line = lines[index]

            // `\ No newline at end of file` describes the line above it and is
            // counted by neither side.
            if line.hasPrefix("\\") {
                if !body.isEmpty { body[body.count - 1].noNewlineAfter = true }
                index += 1
                continue
            }

            let kind: PatchLine.Kind
            let content: Substring
            switch line.first {
            case "+": kind = .addition; content = line.dropFirst()
            case "-": kind = .deletion; content = line.dropFirst()
            case " ": kind = .context; content = line.dropFirst()
            // A context line that is empty is written as a single space, but
            // patches that have been through a mail client arrive with it
            // stripped. Treating a bare empty line as context keeps those in
            // sync instead of abandoning the rest of the file.
            case nil: kind = .context; content = line
            default: return finish(&body, header, lines, &index)
            }

            switch kind {
            case .context:
                guard oldRemaining > 0, newRemaining > 0 else {
                    return finish(&body, header, lines, &index)
                }
                body.append(
                    PatchLine(
                        kind: .context, content: content, oldNumber: oldNumber,
                        newNumber: newNumber))
                oldRemaining -= 1
                newRemaining -= 1
                oldNumber += 1
                newNumber += 1
            case .addition:
                guard newRemaining > 0 else { return finish(&body, header, lines, &index) }
                body.append(
                    PatchLine(
                        kind: .addition, content: content, oldNumber: 0, newNumber: newNumber))
                newRemaining -= 1
                newNumber += 1
            case .deletion:
                guard oldRemaining > 0 else { return finish(&body, header, lines, &index) }
                body.append(
                    PatchLine(
                        kind: .deletion, content: content, oldNumber: oldNumber, newNumber: 0))
                oldRemaining -= 1
                oldNumber += 1
            }

            index += 1
        }

        return finish(&body, header, lines, &index)
    }

    /// Attaches a `\ No newline` marker that sits *after* the last counted line
    /// — the counters reach zero before it is reached — and builds the hunk.
    private static func finish(
        _ body: inout [PatchLine],
        _ header: HunkHeader,
        _ lines: [Substring],
        _ index: inout Int
    ) -> PatchHunk {
        while index < lines.count, lines[index].hasPrefix("\\") {
            if !body.isEmpty { body[body.count - 1].noNewlineAfter = true }
            index += 1
        }

        return PatchHunk(
            oldStart: header.oldStart,
            oldCount: header.oldCount,
            newStart: header.newStart,
            newCount: header.newCount,
            heading: header.heading,
            lines: body
        )
    }

    private struct HunkHeader {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var heading: Substring
    }

    /// `@@ -1,3 +1,4 @@ func name()`.
    ///
    /// A missing `,count` means 1 — git omits it for single-line sides.
    private static func parseHunkHeader(_ line: Substring) -> HunkHeader? {
        guard line.hasPrefix("@@ ") else { return nil }
        var rest = line.dropFirst(3)

        guard rest.first == "-" else { return nil }
        guard let old = takeRange(&rest) else { return nil }

        guard rest.first == " " else { return nil }
        rest = rest.dropFirst()
        guard rest.first == "+" else { return nil }
        guard let new = takeRange(&rest) else { return nil }

        guard rest.hasPrefix(" @@") else { return nil }
        let heading = rest.dropFirst(3)

        return HunkHeader(
            oldStart: old.start, oldCount: old.count,
            newStart: new.start, newCount: new.count,
            heading: heading
        )
    }

    /// Consumes `-12,3` or `+12` from the front and returns its two numbers.
    private static func takeRange(_ rest: inout Substring) -> (start: Int, count: Int)? {
        rest = rest.dropFirst()  // the leading - or +

        guard let start = takeInteger(&rest) else { return nil }
        guard rest.first == "," else { return (start, 1) }
        rest = rest.dropFirst()
        guard let count = takeInteger(&rest) else { return nil }
        return (start, count)
    }

    private static func takeInteger(_ rest: inout Substring) -> Int? {
        var value = 0
        var digits = 0
        while let character = rest.first, let digit = character.wholeNumberValue,
            character.isASCII, character.isNumber
        {
            value = value * 10 + digit
            digits += 1
            rest = rest.dropFirst()
        }
        return digits > 0 ? value : nil
    }
}
