import Foundation

/// How much one commit changed, as the summary line above its file list reads
/// it: *"5 changed files with 118 additions and 59 deletions"*.
///
/// Counted by git rather than by walking the patch. The patch is the one thing
/// in a changeset that can be hundreds of megabytes, and a summary that has to
/// finish reading it before it can be drawn is a summary that arrives after the
/// thing it summarises.
nonisolated struct CommitStats: Sendable, Equatable {

    var fileCount = 0
    var additions = 0
    var deletions = 0

    /// Files git reported as binary — `-` in both numstat columns. They are
    /// counted in ``fileCount`` but contribute no lines, so a commit that only
    /// replaces an image reads as *"1 changed file"* with no line counts rather
    /// than as an empty change.
    var binaryCount = 0

    var isEmpty: Bool { fileCount == 0 }

    /// The summary line, already pluralised.
    var summary: String {
        guard fileCount > 0 else { return "No changed files" }

        let files = fileCount == 1 ? "1 changed file" : "\(fileCount) changed files"
        guard additions > 0 || deletions > 0 else {
            return binaryCount > 0 ? "\(files), binary" : files
        }

        let added = additions == 1 ? "1 addition" : "\(additions) additions"
        let removed = deletions == 1 ? "1 deletion" : "\(deletions) deletions"
        return "Showing \(files) with \(added) and \(removed)"
    }

    // MARK: Parsing

    /// Parses `git show --numstat` output.
    ///
    /// One line per file: additions, deletions and the path, tab separated. A
    /// binary file reports `-` for both counts. Renames are one line whose path
    /// column holds both names, which is why the split stops at two — the path
    /// is never read here and must not be allowed to produce extra fields.
    ///
    /// Deliberately **not** `-z`. Without it a path is quoted rather than raw,
    /// which is a problem only for a reader that cares about paths; this one
    /// reads two integers and throws the rest away, and `-z` would cost a
    /// three-record-per-rename state machine for nothing.
    static func parseNumstat(_ text: String) -> CommitStats {
        var stats = CommitStats()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }

            stats.fileCount += 1

            if let added = Int(fields[0]), let removed = Int(fields[1]) {
                stats.additions += added
                stats.deletions += removed
            } else {
                stats.binaryCount += 1
            }
        }

        return stats
    }
}
