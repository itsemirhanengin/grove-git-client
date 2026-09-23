import Foundation

/// One commit, as the history list shows it.
///
/// The body is deliberately absent. A page of history is a few hundred subjects
/// and a scroll view; carrying every message body would multiply the parse for
/// text nobody has asked to read yet. It is fetched for the one commit that is
/// selected.
/// One ref pointing at a commit, already classified.
///
/// The kind is what the badge's colour means, so it has to be derived from the
/// full ref path rather than guessed from the name — see ``CommitInfo/refs``.
nonisolated struct CommitRef: Sendable, Hashable, Identifiable {

    nonisolated enum Kind: Sendable, Hashable {
        /// Where the working copy is.
        case head
        case branch
        case tag
        /// A remote-tracking branch: `origin/main`.
        case remote
    }

    let kind: Kind
    let name: String

    var id: String { "\(kind):\(name)" }
}

nonisolated struct CommitInfo: Sendable, Hashable, Identifiable {

    let oid: String
    let shortOID: String

    /// The tree this commit points at. Shown in the changeset header, and the
    /// one id in that table that is not reachable from any other field.
    let treeOID: String

    /// Parent ids, first-parent first. Empty for a root commit; more than one
    /// for a merge.
    let parents: [String]

    let authorName: String
    let authorEmail: String
    let date: Date?

    /// Who committed it, which is the author again for anything but a rebase,
    /// a cherry-pick or a patch applied on someone's behalf — and is exactly
    /// the case the changeset header exists to make visible.
    let committerName: String
    let committerEmail: String
    let committerDate: Date?

    /// First line of the message.
    let subject: String

    /// Branch, tag and HEAD names pointing at this commit, already stripped of
    /// their `refs/…` prefixes by `%D`.
    let refNames: [String]

    var id: String { oid }

    var isMerge: Bool { parents.count > 1 }
    var isRoot: Bool { parents.isEmpty }

    /// Whether the committer is someone other than the author, or the commit
    /// was written at a different time than it was authored. The changeset
    /// header uses this to decide whether the committer rows are worth the two
    /// lines they cost.
    var wasRecommitted: Bool {
        committerEmail != authorEmail || committerDate != date
    }

    /// `%D` puts `HEAD -> refs/heads/main` first when HEAD is here.
    var isHead: Bool { refNames.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") } }

    /// The refs pointing at this commit, as the row's badges.
    ///
    /// Ordered the way Tower reads them — HEAD, local branches, tags, then
    /// remote-tracking branches — because that is also least-to-most
    /// disposable, and the badges collapse from the right when the column is
    /// narrow.
    ///
    /// `HEAD -> main` becomes **two** badges rather than one. They are two
    /// different facts — "this is where you are" and "this is what the branch is
    /// called" — and the first is the one worth spotting from across the list.
    var refs: [CommitRef] {
        var head: [CommitRef] = []
        var branches: [CommitRef] = []
        var tags: [CommitRef] = []
        var remotes: [CommitRef] = []

        for raw in refNames {
            var name = raw

            if name == "HEAD" {
                head.append(CommitRef(kind: .head, name: "HEAD"))
                continue
            }
            if name.hasPrefix("HEAD -> ") {
                head.append(CommitRef(kind: .head, name: "HEAD"))
                name = String(name.dropFirst("HEAD -> ".count))
            }
            if name.hasPrefix("tag: ") {
                name = String(name.dropFirst("tag: ".count))
            }

            // `--decorate=full` is what makes this exact. Short decoration
            // prints `feature/login` and `origin/main` identically, and there is
            // no way to tell a local branch with a slash in it from a remote —
            // which is most branches, at which point every badge is the wrong
            // colour.
            if let branch = name.strippingPrefix("refs/heads/") {
                branches.append(CommitRef(kind: .branch, name: branch))
            } else if let tag = name.strippingPrefix("refs/tags/") {
                tags.append(CommitRef(kind: .tag, name: tag))
            } else if let remote = name.strippingPrefix("refs/remotes/") {
                remotes.append(CommitRef(kind: .remote, name: remote))
            }
            // Anything else is a ref Grove wrote for itself — `refs/grove/backup/…`
            // — or one some other tool left behind. Neither is history.
        }

        return head + branches + tags + remotes
    }

    /// The badge labels, in display order. Kept for tests and tooltips.
    var displayRefNames: [String] { refs.map(\.name) }

    // MARK: Parsing

    /// The fields, in order, that ``parse(_:)`` expects.
    ///
    /// Separated by **unit** and **record** separators rather than NUL. `git
    /// log` has no `-z` for `--format`, and a commit subject can legally
    /// contain almost anything — but not a control character git itself uses as
    /// a delimiter in its own porcelain. Parsing counts fields per record so a
    /// pathological subject truncates one row rather than desynchronising the
    /// rest.
    /// `%s` stays last: a subject is free text, and giving it the final slot
    /// means `maxSplits` hands it over whole however many separators it
    /// contains.
    static let format =
        [
            "%H", "%h", "%T", "%P", "%an", "%ae", "%at", "%cn", "%ce", "%ct", "%D", "%s",
        ].joined(separator: "\u{1f}") + "\u{1e}"

    private static let fieldCount = 12

    static func parse(_ bytes: [UInt8]) -> [CommitInfo] {
        let text = String(decoding: bytes, as: UTF8.self)

        return text.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap {
            record in
            // `git log` puts a newline between records; it is not part of the
            // first field.
            let trimmed = record.drop(while: { $0 == "\n" || $0 == "\r" })
            guard !trimmed.isEmpty else { return nil }

            let fields = trimmed.split(
                separator: "\u{1f}", maxSplits: fieldCount - 1, omittingEmptySubsequences: false)
            guard fields.count == fieldCount else { return nil }

            let parents = fields[3]
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)

            let refNames = fields[10]
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            return CommitInfo(
                oid: String(fields[0]),
                shortOID: String(fields[1]),
                treeOID: String(fields[2]),
                parents: parents,
                authorName: String(fields[4]),
                authorEmail: String(fields[5]),
                date: TimeInterval(fields[6]).map(Date.init(timeIntervalSince1970:)),
                committerName: String(fields[7]),
                committerEmail: String(fields[8]),
                committerDate: TimeInterval(fields[9]).map(Date.init(timeIntervalSince1970:)),
                subject: String(fields[11]),
                refNames: refNames
            )
        }
    }
}

nonisolated extension StringProtocol {
    /// The remainder after `prefix`, or `nil` when it does not start with one.
    ///
    /// `hasPrefix` followed by `dropFirst(prefix.count)` says the prefix twice
    /// and counts it in UTF-16, which is the wrong length for anything outside
    /// ASCII. Ref paths are ASCII, but the pattern outlives the assumption.
    func strippingPrefix(_ prefix: String) -> String? {
        starts(with: prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
