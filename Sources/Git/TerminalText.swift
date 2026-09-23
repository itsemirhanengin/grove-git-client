import Foundation

/// Turns output meant for a terminal into text meant for a window.
///
/// git runs under `color.ui=false`, but its **hooks** do not: lefthook, husky,
/// turbo and friends draw colours, gradients and progress spinners whatever git
/// is told. Shown raw, that is `[38;2;52;52;52m─` repeated a few hundred times.
nonisolated enum TerminalText {

    /// Removes escape sequences, collapses carriage-return redraws and drops
    /// the remaining control characters, keeping newlines and tabs.
    static func clean(_ text: String) -> String {
        var result = text
        for pattern in escapePatterns {
            result = result.replacing(pattern, with: "")
        }

        // A spinner redraws its line with `\r`; only the last drawing is what
        // the terminal ended up showing.
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let drawn = line.split(separator: "\r", omittingEmptySubsequences: false)
                .last(where: { !$0.isEmpty }) ?? ""
            return String(drawn.unicodeScalars.filter { $0 == "\t" || !isControl($0) })
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated(unsafe) private static let escapePatterns: [Regex<Substring>] = [
        // CSI: colours, cursor movement, erase — `ESC [ … final`.
        #/\x{1B}\[[0-?]*[ -\/]*[@-~]/#,
        // OSC: window titles and hyperlinks — `ESC ] … BEL` or `ESC ] … ESC \`.
        #/\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)?/#,
        // Any other two-byte escape.
        #/\x{1B}[@-Z\\-_]/#,
    ]

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    // MARK: Excerpt

    /// A few lines of a long failure that are worth putting in an alert.
    ///
    /// Returns the output whole when it is already short. Otherwise, the **last**
    /// few lines that read as an error — a hook usually prints pages of passing
    /// steps before the one that failed, and the failure is at the end — or,
    /// when nothing looks like one, simply the last few lines. A heuristic: the
    /// full log is always one click away, so being wrong here costs a click,
    /// never the information.
    static func excerpt(of text: String, lineLimit: Int = 3) -> String {
        let lines = text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !isRule($0) }

        if lines.count <= lineLimit + 2, text.count <= 500 {
            return lines.joined(separator: "\n")
        }

        let errors = lines.filter { $0.contains(errorPattern) }
        let chosen = (errors.isEmpty ? lines : errors).suffix(lineLimit)
        return chosen.map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }
            .joined(separator: "\n")
    }

    /// `error`, but not `0 errors` — linters report their clean runs that way.
    nonisolated(unsafe) private static let errorPattern =
        #/(?i)\berror\b|\bfatal\b|\bfailed\b|✖|✗|×|❌/#

    /// A line of box-drawing or dashes, drawn as decoration.
    private static func isRule(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy {
            (0x2500...0x257F).contains($0.value) || $0 == "-" || $0 == "=" || $0 == " "
        }
    }
}
