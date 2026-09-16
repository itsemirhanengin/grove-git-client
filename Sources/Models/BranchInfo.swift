import Foundation

/// A multi-step git operation the repository is currently in the middle of.
///
/// Surfacing this is what stops a client from looking broken during a conflict:
/// the user needs to see "merging" and be offered abort/continue, rather than
/// just a pile of unexplained modified files.
nonisolated enum InProgressOperation: Sendable, Equatable {
    case merge
    case rebase
    case cherryPick
    case revert
    case bisect

    var label: String {
        switch self {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .cherryPick: "Cherry-picking"
        case .revert: "Reverting"
        case .bisect: "Bisecting"
        }
    }
}

/// One ref from `for-each-ref`.
nonisolated struct BranchInfo: Sendable, Hashable, Identifiable {

    /// Full ref name, e.g. `refs/heads/main`.
    let refName: String

    /// Short name, e.g. `main` or `origin/main`.
    let name: String

    let shortOID: String
    let upstream: String?
    let ahead: Int
    let behind: Int

    /// Last commit time, used for the most-recent-first ordering.
    let committerDate: Date?

    /// Whether this is the checked-out branch.
    let isHead: Bool

    var id: String { refName }

    var isRemote: Bool { refName.hasPrefix("refs/remotes/") }
    var isLocal: Bool { refName.hasPrefix("refs/heads/") }

    /// Both ahead and behind — the state that actually needs the user's
    /// attention, and the one worth colouring differently.
    var hasDiverged: Bool { ahead > 0 && behind > 0 }

    // MARK: Parsing

    /// Parses NUL-separated `for-each-ref` output.
    ///
    /// Records are newline-separated and fields NUL-separated, which is the
    /// inverse of `status -z`. Branch names cannot contain either, so this is
    /// unambiguous.
    static func parse(_ bytes: [UInt8]) -> [BranchInfo] {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count >= 7 else { return nil }

            let (ahead, behind) = parseTrack(String(fields[4]))

            return BranchInfo(
                refName: String(fields[0]),
                name: String(fields[1]),
                shortOID: String(fields[2]),
                upstream: fields[3].isEmpty ? nil : String(fields[3]),
                ahead: ahead,
                behind: behind,
                committerDate: TimeInterval(fields[5]).map(Date.init(timeIntervalSince1970:)),
                isHead: fields[6] == "*"
            )
        }
    }

    /// `%(upstream:track)` renders as `[ahead 2, behind 1]`, `[gone]` or empty.
    private static func parseTrack(_ track: String) -> (ahead: Int, behind: Int) {
        guard !track.isEmpty, track != "[gone]" else { return (0, 0) }

        var ahead = 0
        var behind = 0
        let trimmed = track.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        for part in trimmed.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("ahead ") { ahead = Int(piece.dropFirst(6)) ?? 0 }
            if piece.hasPrefix("behind ") { behind = Int(piece.dropFirst(7)) ?? 0 }
        }
        return (ahead, behind)
    }
}
