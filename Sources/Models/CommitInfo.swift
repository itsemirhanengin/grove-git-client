import Foundation

/// One commit, as the history list shows it.
///
/// The body is deliberately absent. A page of history is a few hundred subjects
/// and a scroll view; carrying every message body would multiply the parse for
/// text nobody has asked to read yet. It is fetched for the one commit that is
/// selected.
nonisolated struct CommitInfo: Sendable, Hashable, Identifiable {

    let oid: String
    let shortOID: String

    /// Parent ids, first-parent first. Empty for a root commit; more than one
    /// for a merge.
    let parents: [String]

    let authorName: String
    let authorEmail: String
    let date: Date?

    /// First line of the message.
    let subject: String

    /// Branch, tag and HEAD names pointing at this commit, already stripped of
    /// their `refs/…` prefixes by `%D`.
    let refNames: [String]

    var id: String { oid }

    var isMerge: Bool { parents.count > 1 }
    var isRoot: Bool { parents.isEmpty }

    /// `%D` puts `HEAD -> main` first when HEAD is here.
    var isHead: Bool { refNames.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") } }

    /// What the row shows: `main` rather than `HEAD -> main`.
    var displayRefNames: [String] {
        refNames.map { name in
            name.hasPrefix("HEAD -> ") ? String(name.dropFirst("HEAD -> ".count)) : name
        }
    }

    // MARK: Parsing

    /// The fields, in order, that ``parse(_:)`` expects.
    ///
    /// Separated by **unit** and **record** separators rather than NUL. `git
    /// log` has no `-z` for `--format`, and a commit subject can legally
    /// contain almost anything — but not a control character git itself uses as
    /// a delimiter in its own porcelain. Parsing counts fields per record so a
    /// pathological subject truncates one row rather than desynchronising the
    /// rest.
    static let format =
        [
            "%H", "%h", "%P", "%an", "%ae", "%at", "%D", "%s",
        ].joined(separator: "\u{1f}") + "\u{1e}"

    private static let fieldCount = 8

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

            let parents = fields[2]
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)

            let refNames = fields[6]
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            return CommitInfo(
                oid: String(fields[0]),
                shortOID: String(fields[1]),
                parents: parents,
                authorName: String(fields[3]),
                authorEmail: String(fields[4]),
                date: TimeInterval(fields[5]).map(Date.init(timeIntervalSince1970:)),
                subject: String(fields[7]),
                refNames: refNames
            )
        }
    }
}
