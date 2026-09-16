import Foundation

/// A single-letter status from git's `XY` pair.
nonisolated enum StatusCode: UInt8, Sendable, Equatable {
    case unchanged = 0x2E  // .
    case modified = 0x4D  // M
    case added = 0x41  // A
    case deleted = 0x44  // D
    case renamed = 0x52  // R
    case copied = 0x43  // C
    case typeChanged = 0x54  // T
    case unmerged = 0x55  // U

    init?(byte: UInt8) {
        guard let code = StatusCode(rawValue: byte) else { return nil }
        self = code
    }

    var isChanged: Bool { self != .unchanged }

    /// The letter shown in the status column. Rendered in a monospaced font so
    /// every code shares an advance width and the column stays flush.
    var letter: String {
        self == .unchanged ? "" : String(UnicodeScalar(rawValue))
    }
}

/// Which list a change belongs to, beyond its `XY` codes.
nonisolated enum ChangeKind: Sendable, Equatable {
    case tracked
    case untracked
    case ignored
    /// A conflicted path. Git reports these as `u` records and they carry all
    /// three merge stages.
    case unmerged
}

/// Submodule state from porcelain v2's 4-character `<sub>` field.
nonisolated struct SubmoduleState: Sendable, Equatable {
    var commitChanged: Bool
    var hasModifiedTrackedFiles: Bool
    var hasUntrackedFiles: Bool
}

/// The three blob ids of a conflicted path, from a `u` record.
///
/// These are what the conflict resolver reads via `git show :1:` / `:2:` / `:3:`.
/// A missing stage is the empty id — add/add conflicts have no stage 1.
nonisolated struct UnmergedStages: Sendable, Equatable {
    /// Common ancestor.
    var base: String
    /// Ours — the branch being merged into.
    var ours: String
    /// Theirs — the branch being merged in.
    var theirs: String
}

/// One changed path in a repository.
///
/// The raw path bytes are kept alongside the displayable string because git
/// paths need not be valid UTF-8, and may contain spaces or newlines. Writing
/// `pathBytes` back through `--pathspec-from-file=- --pathspec-file-nul` is what
/// makes staging and discarding such files work at all, rather than silently
/// targeting the wrong file.
nonisolated struct FileChange: Sendable, Equatable, Identifiable {

    /// Raw bytes exactly as git emitted them.
    var pathBytes: [UInt8]

    /// Lossily decoded for display. Never send this back to git.
    var displayPath: String

    /// For renames and copies: where the file came from.
    var originalPathBytes: [UInt8]?
    var originalDisplayPath: String?

    /// Status in the index — i.e. staged.
    var indexStatus: StatusCode

    /// Status in the working tree — i.e. unstaged.
    var worktreeStatus: StatusCode

    var kind: ChangeKind
    var submodule: SubmoduleState?

    /// Rename or copy similarity, 0–100.
    var similarity: Int?

    var unmergedStages: UnmergedStages?

    var id: [UInt8] { pathBytes }

    // MARK: Derived

    /// Whether this change belongs in the **Staged** list.
    var isStaged: Bool {
        kind == .tracked && indexStatus.isChanged
    }

    /// Whether this change belongs in the **Changes** (unstaged) list.
    ///
    /// A file can be in both lists at once: `XY == "MM"` means staged *and*
    /// modified again since. Collapsing that into a single list is the most
    /// common way a git client misleads its user.
    var isUnstaged: Bool {
        switch kind {
        case .tracked: worktreeStatus.isChanged
        case .untracked, .unmerged: true
        case .ignored: false
        }
    }

    var isConflicted: Bool { kind == .unmerged }

    /// Directory portion of the path, dimmed ahead of the filename in the UI.
    var directoryPrefix: String {
        let components = displayPath.split(separator: "/")
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    var fileName: String {
        String(displayPath.split(separator: "/").last ?? "")
    }

    /// `displayPath` with control characters replaced, safe to put in a
    /// fixed-height row.
    ///
    /// Newlines and tabs are legal in macOS filenames, and git passes them
    /// through raw. Rendering one directly would make a single row taller than
    /// every other row, which breaks the uniform row height the sidebar and the
    /// diff renderer both rely on.
    var singleLineDisplayPath: String {
        Self.sanitizeForSingleLine(displayPath)
    }

    var singleLineFileName: String {
        Self.sanitizeForSingleLine(fileName)
    }

    static func sanitizeForSingleLine(_ value: String) -> String {
        guard value.contains(where: { $0.isNewline || $0 == "\t" || $0.isASCII && $0 < " " })
        else { return value }

        return String(
            value.map { character in
                if character.isNewline { return "␊" }
                if character == "\t" { return "␉" }
                if character.isASCII, character < " " { return "�" }
                return character
            }
        )
    }
}

/// The state of one repository at a moment in time.
nonisolated struct RepoStatus: Sendable, Equatable {

    /// HEAD's commit id, or `nil` in a repository with no commits yet.
    var headOID: String?

    /// Current branch, or `nil` when HEAD is detached.
    var branch: String?

    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0

    var changes: [FileChange] = []

    /// A merge, rebase, cherry-pick or revert the repository is in the middle
    /// of. Detected from marker files, so it costs no extra process.
    var inProgress: InProgressOperation?

    /// A repository with no commits. `rev-parse HEAD` fails here, so anything
    /// that diffs against HEAD needs a different path — diffing against the
    /// empty tree instead.
    var isUnborn: Bool { headOID == nil }

    var isDetached: Bool { branch == nil }

    var staged: [FileChange] { changes.filter(\.isStaged) }
    var unstaged: [FileChange] { changes.filter { $0.isUnstaged && $0.kind == .tracked } }
    var untracked: [FileChange] { changes.filter { $0.kind == .untracked } }
    var conflicted: [FileChange] { changes.filter(\.isConflicted) }

    var hasConflicts: Bool { changes.contains(where: \.isConflicted) }

    /// Count shown in the repo header badge.
    var dirtyCount: Int {
        changes.count { $0.kind != .ignored }
    }

    static let empty = RepoStatus()
}
