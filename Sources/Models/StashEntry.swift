import Foundation

/// One entry from `git stash list`.
nonisolated struct StashEntry: Sendable, Hashable, Identifiable {

    /// The reflog selector, e.g. `stash@{0}`.
    ///
    /// **Positional, and it moves.** Dropping `stash@{0}` renumbers everything
    /// below it, so this is safe to pass to git only while the list it came
    /// from is still current — which is why every mutation here refreshes.
    let selector: String

    /// The stash commit. Unlike the selector this is stable, and it is what the
    /// UI compares to decide which row is which.
    let oid: String

    /// The message, with git's `WIP on main:` / `On main:` prefix removed.
    let message: String

    /// Branch the stash was made on, from that same prefix.
    let branch: String?

    let date: Date?

    var id: String { oid }

    static let format = ["%gd", "%H", "%at", "%gs"].joined(separator: "\u{1f}") + "\u{1e}"

    static func parse(_ bytes: [UInt8]) -> [StashEntry] {
        let text = String(decoding: bytes, as: UTF8.self)

        return text.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap {
            record in
            let trimmed = record.drop(while: { $0 == "\n" || $0 == "\r" })
            guard !trimmed.isEmpty else { return nil }

            let fields = trimmed.split(
                separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }

            let (branch, message) = splitSubject(String(fields[3]))
            return StashEntry(
                selector: String(fields[0]),
                oid: String(fields[1]),
                message: message,
                branch: branch,
                date: TimeInterval(fields[2]).map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    /// `%gs` reads `WIP on main: 1a2b3c4 Subject` for an automatic stash, and
    /// `On main: my message` for one with a message. Both carry the branch, and
    /// neither is worth showing raw.
    private static func splitSubject(_ subject: String) -> (branch: String?, message: String) {
        for prefix in ["WIP on ", "On "] where subject.hasPrefix(prefix) {
            let rest = subject.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { break }
            let branch = String(rest[rest.startIndex..<colon])
            let message = rest[rest.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            return (branch.isEmpty ? nil : branch, message)
        }
        return (nil, subject)
    }
}

/// A snapshot Grove took before doing something destructive.
///
/// These are real commits anchored under `refs/grove/backup/`, made by
/// `git stash create` — which captures the worktree *and* the index without
/// touching either. They are invisible to `git branch` and `git stash list`,
/// which is why they need a window of their own to be recoverable at all.
nonisolated struct BackupRef: Sendable, Hashable, Identifiable {

    let refName: String
    let oid: String
    let date: Date?

    /// Why it was taken — `discard`, `pull`, `merge` — from the ref name.
    let reason: String

    var id: String { refName }

    /// What to type to get the work back. Shown verbatim, because a recovery
    /// path the user cannot run themselves is one they have to trust.
    var recoveryCommand: String { "git stash apply \(refName)" }

    static let prefix = "refs/grove/backup/"

    /// `refs/grove/backup/1758000000-discard` → epoch and reason.
    ///
    /// The reason lives in the **ref name** because the object is a stash commit
    /// whose own subject says `WIP on main`, and `update-ref -m` writes only to
    /// the reflog, which is not what `for-each-ref` reads.
    static func name(epoch: Int, reason: String) -> String {
        let slug = reason.lowercased().map { $0.isLetter ? $0 : "-" }
        return "\(prefix)\(epoch)-\(String(slug))"
    }

    /// Fields are NUL-separated, records newline-separated.
    ///
    /// **`for-each-ref` does not expand `%x1f`.** Unlike `git log --format` it
    /// prints it literally, which produced a list that parsed to nothing and
    /// looked exactly like "no snapshots were ever taken". `%00` it does expand,
    /// and a ref name cannot contain a NUL — or a newline.
    static func parse(_ bytes: [UInt8]) -> [BackupRef] {
        let text = String(decoding: bytes, as: UTF8.self)

        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }

            let refName = String(fields[0])
            let tail = refName.dropFirst(prefix.count)
            let epoch = tail.prefix(while: \.isNumber)
            let reason = tail.dropFirst(epoch.count).drop(while: { $0 == "-" })

            return BackupRef(
                refName: refName,
                oid: String(fields[1]),
                date: TimeInterval(epoch).map(Date.init(timeIntervalSince1970:)),
                reason: reason.isEmpty ? "operation" : String(reason)
            )
        }
    }
}
