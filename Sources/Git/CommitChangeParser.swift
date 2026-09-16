import Foundation

/// Parses `git show --name-status -z` into the same ``FileChange`` rows the
/// working copy uses.
///
/// Reusing `FileChange` rather than inventing a commit-only row type is what
/// lets the history pane draw its file list with `ChangeRow` — the status
/// letter, the tint and the rename arrow all already mean the right thing.
nonisolated enum CommitChangeParser {

    /// Records are NUL-separated, and a **rename or copy consumes three** of
    /// them: the status, the old path and the new one. Advancing by two there
    /// would read the new path as the next status and lose sync for the rest of
    /// the commit — the same trap porcelain v2 sets with its two-record renames.
    static func parse(_ bytes: [UInt8]) -> [FileChange] {
        var records: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0 {
            records.append(bytes[start..<index])
            start = bytes.index(after: index)
        }
        if start < bytes.endIndex { records.append(bytes[start...]) }

        var changes: [FileChange] = []
        var index = 0

        while index < records.count {
            let token = records[index]
            guard let letter = token.first, letter != 0 else {
                index += 1
                continue
            }

            // `R100` / `C75` carry a similarity score after the letter.
            let similarity = Int(String(decoding: token.dropFirst(), as: UTF8.self))
            let isPair = letter == UInt8(ascii: "R") || letter == UInt8(ascii: "C")
            let needed = isPair ? 2 : 1
            guard index + needed < records.count else { break }

            let status = StatusCode(byte: letter) ?? .modified

            if isPair {
                let original = Array(records[index + 1])
                let path = Array(records[index + 2])
                changes.append(
                    FileChange(
                        pathBytes: path,
                        displayPath: String(decoding: path, as: UTF8.self),
                        originalPathBytes: original,
                        originalDisplayPath: String(decoding: original, as: UTF8.self),
                        indexStatus: status,
                        worktreeStatus: .unchanged,
                        kind: .tracked,
                        similarity: similarity
                    ))
                index += 3
            } else {
                let path = Array(records[index + 1])
                changes.append(
                    FileChange(
                        pathBytes: path,
                        displayPath: String(decoding: path, as: UTF8.self),
                        indexStatus: status,
                        worktreeStatus: .unchanged,
                        kind: .tracked
                    ))
                index += 2
            }
        }

        return changes
    }
}
