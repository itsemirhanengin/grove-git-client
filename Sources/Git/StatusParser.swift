import Foundation

/// Parses `git status --porcelain=v2 --branch -z`.
///
/// Works on raw bytes rather than `String` throughout, because git paths are
/// arbitrary byte sequences: they may contain spaces, newlines, or bytes that
/// are not valid UTF-8. Decoding early would corrupt those paths, and a corrupted
/// path means staging or discarding the wrong file.
///
/// Two details in this format cause most parser bugs:
///
/// - **A rename record spans two NUL records.** A `2 …` entry is followed
///   immediately by a separate record holding the original path, so the walk has
///   to advance by two. A parser that advances by one treats that path as the
///   next entry and loses sync for the rest of the output.
/// - **Paths may contain spaces**, so every record is split a fixed number of
///   times and the remainder is the path — never split on every space.
nonisolated enum StatusParser {

    static func parse(_ bytes: [UInt8]) -> RepoStatus {
        var status = RepoStatus()
        let records = splitOnNUL(bytes)

        var index = 0
        while index < records.count {
            let record = records[index]
            guard let first = record.first else {
                index += 1
                continue
            }

            switch first {
            case UInt8(ascii: "#"):
                parseHeader(record, into: &status)
                index += 1

            case UInt8(ascii: "1"):
                if let change = parseOrdinary(record) { status.changes.append(change) }
                index += 1

            case UInt8(ascii: "2"):
                // The original path is the NEXT record — consume both.
                let originalRecord = index + 1 < records.count ? records[index + 1] : nil
                if let change = parseRenamed(record, originalPath: originalRecord) {
                    status.changes.append(change)
                }
                index += 2

            case UInt8(ascii: "u"):
                if let change = parseUnmerged(record) { status.changes.append(change) }
                index += 1

            case UInt8(ascii: "?"):
                if let change = parseSimple(record, kind: .untracked) {
                    status.changes.append(change)
                }
                index += 1

            case UInt8(ascii: "!"):
                if let change = parseSimple(record, kind: .ignored) {
                    status.changes.append(change)
                }
                index += 1

            default:
                // Unknown record type. The format is explicitly extensible, so
                // skipping beats failing.
                index += 1
            }
        }

        return status
    }

    // MARK: - Headers

    private static func parseHeader(_ record: ArraySlice<UInt8>, into status: inout RepoStatus) {
        let fields = split(record, maxSplits: 2)
        guard fields.count >= 3 else { return }

        let key = decode(fields[1])
        let value = decode(fields[2])

        switch key {
        case "branch.oid":
            // A repository with no commits reports the literal "(initial)".
            status.headOID = value == "(initial)" ? nil : value

        case "branch.head":
            status.branch = value == "(detached)" ? nil : value

        case "branch.upstream":
            status.upstream = value

        case "branch.ab":
            // "+3 -1"
            let parts = value.split(separator: " ")
            for part in parts {
                let magnitude = Int(part.dropFirst()) ?? 0
                if part.hasPrefix("+") { status.ahead = magnitude }
                if part.hasPrefix("-") { status.behind = magnitude }
            }

        default:
            break  // Unknown headers are ignored by design.
        }
    }

    // MARK: - Entries

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ record: ArraySlice<UInt8>) -> FileChange? {
        let fields = split(record, maxSplits: 8)
        guard fields.count == 9 else { return nil }
        guard let (index, worktree) = parseXY(fields[1]) else { return nil }

        let path = Array(fields[8])
        return FileChange(
            pathBytes: path,
            displayPath: decode(fields[8]),
            indexStatus: index,
            worktreeStatus: worktree,
            kind: .tracked,
            submodule: parseSubmodule(fields[2])
        )
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>`, with the
    /// original path in the following record.
    private static func parseRenamed(
        _ record: ArraySlice<UInt8>,
        originalPath: ArraySlice<UInt8>?
    ) -> FileChange? {
        let fields = split(record, maxSplits: 9)
        guard fields.count == 10 else { return nil }
        guard let (index, worktree) = parseXY(fields[1]) else { return nil }

        // Field 8 is like "R100" or "C75": the operation letter then a score.
        let scoreField = decode(fields[8])
        let similarity = Int(scoreField.dropFirst())

        return FileChange(
            pathBytes: Array(fields[9]),
            displayPath: decode(fields[9]),
            originalPathBytes: originalPath.map(Array.init),
            originalDisplayPath: originalPath.map(decode),
            indexStatus: index,
            worktreeStatus: worktree,
            kind: .tracked,
            submodule: parseSubmodule(fields[2]),
            similarity: similarity
        )
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    ///
    /// The presence of any such record means the repository has conflicts.
    private static func parseUnmerged(_ record: ArraySlice<UInt8>) -> FileChange? {
        let fields = split(record, maxSplits: 10)
        guard fields.count == 11 else { return nil }
        guard let (index, worktree) = parseXY(fields[1]) else { return nil }

        return FileChange(
            pathBytes: Array(fields[10]),
            displayPath: decode(fields[10]),
            indexStatus: index,
            worktreeStatus: worktree,
            kind: .unmerged,
            submodule: parseSubmodule(fields[2]),
            unmergedStages: UnmergedStages(
                base: decode(fields[7]),
                ours: decode(fields[8]),
                theirs: decode(fields[9])
            )
        )
    }

    /// `? <path>` and `! <path>`
    private static func parseSimple(_ record: ArraySlice<UInt8>, kind: ChangeKind) -> FileChange? {
        let fields = split(record, maxSplits: 1)
        guard fields.count == 2 else { return nil }

        return FileChange(
            pathBytes: Array(fields[1]),
            displayPath: decode(fields[1]),
            indexStatus: .unchanged,
            worktreeStatus: .unchanged,
            kind: kind
        )
    }

    // MARK: - Fields

    /// `XY` — index status then worktree status, `.` meaning unchanged.
    private static func parseXY(_ field: ArraySlice<UInt8>) -> (StatusCode, StatusCode)? {
        guard field.count == 2 else { return nil }
        let first = field[field.startIndex]
        let second = field[field.index(after: field.startIndex)]
        guard let index = StatusCode(byte: first), let worktree = StatusCode(byte: second) else {
            return nil
        }
        return (index, worktree)
    }

    /// `N...` for an ordinary file, or `S<c><m><u>` for a submodule.
    private static func parseSubmodule(_ field: ArraySlice<UInt8>) -> SubmoduleState? {
        guard field.count == 4, field[field.startIndex] == UInt8(ascii: "S") else { return nil }
        let bytes = Array(field)
        return SubmoduleState(
            commitChanged: bytes[1] == UInt8(ascii: "C"),
            hasModifiedTrackedFiles: bytes[2] == UInt8(ascii: "M"),
            hasUntrackedFiles: bytes[3] == UInt8(ascii: "U")
        )
    }

    // MARK: - Byte helpers

    private static func splitOnNUL(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var records: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0 {
            if start < index { records.append(bytes[start..<index]) }
            start = bytes.index(after: index)
        }
        if start < bytes.endIndex { records.append(bytes[start...]) }
        return records
    }

    /// Splits on spaces at most `maxSplits` times; whatever remains — including
    /// any further spaces — becomes the final field. This is what keeps paths
    /// containing spaces intact.
    private static func split(_ record: ArraySlice<UInt8>, maxSplits: Int) -> [ArraySlice<UInt8>] {
        var fields: [ArraySlice<UInt8>] = []
        fields.reserveCapacity(maxSplits + 1)

        var start = record.startIndex
        var splits = 0
        var cursor = record.startIndex

        while cursor < record.endIndex, splits < maxSplits {
            if record[cursor] == UInt8(ascii: " ") {
                fields.append(record[start..<cursor])
                start = record.index(after: cursor)
                splits += 1
            }
            cursor = record.index(after: cursor)
        }
        fields.append(record[start...])
        return fields
    }

    /// Lossy on purpose — it must never fail, and it is only ever used for
    /// display or for fields git guarantees are ASCII.
    private static func decode(_ slice: ArraySlice<UInt8>) -> String {
        String(decoding: slice, as: UTF8.self)
    }
}
