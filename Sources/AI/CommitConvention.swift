import Foundation

/// How a repository wants its commit messages written.
///
/// Two sources, because repositories say it in two ways. Some **enforce** it —
/// a commitlint config checked by a `commit-msg` hook, which rejects anything
/// else. Many more only **practise** it: every subject in the log starts with
/// `feat:`, or with a ticket key, or in lowercase. Recent subjects cover both —
/// an enforced convention shows up in the log too — and the config adds the
/// details a log cannot show, such as which scopes are allowed.
nonisolated struct CommitConvention: Sendable, Equatable {

    /// A rules file found at the repository root.
    struct RulesFile: Sendable, Equatable {
        var name: String
        var contents: String
    }

    var rules: [RulesFile] = []

    /// Newest first, merges excluded.
    var recentSubjects: [String] = []

    var isEmpty: Bool { rules.isEmpty && recentSubjects.isEmpty }

    // MARK: Finding the rules

    /// Every name commitlint looks for its configuration under.
    static let rulesFileNames = [
        "commitlint.config.js", "commitlint.config.cjs", "commitlint.config.mjs",
        "commitlint.config.ts", "commitlint.config.cts", "commitlint.config.mts",
        ".commitlintrc", ".commitlintrc.json", ".commitlintrc.yaml", ".commitlintrc.yml",
        ".commitlintrc.js", ".commitlintrc.cjs", ".commitlintrc.mjs",
        ".commitlintrc.ts", ".commitlintrc.cts", ".commitlintrc.mts",
    ]

    /// A config is a few dozen lines. Anything far past that is not one worth
    /// spending the prompt on.
    static let rulesFileLimit = 4 << 10

    /// Reads the commitlint configuration at `root`, if there is one — including
    /// the `commitlint` key of `package.json`, the other place it is allowed.
    ///
    /// The file is **read**, never run. A JavaScript config is shown to the
    /// model as text; executing someone's config to evaluate it would be running
    /// their code to write a sentence.
    static func rulesFiles(at root: URL) -> [RulesFile] {
        var found: [RulesFile] = []
        for name in rulesFileNames {
            if let contents = read(root.appending(path: name)) {
                found.append(RulesFile(name: name, contents: contents))
            }
        }
        if found.isEmpty, let embedded = packageJSONRules(at: root) {
            found.append(RulesFile(name: "package.json (\"commitlint\")", contents: embedded))
        }
        return found
    }

    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let text = String(decoding: data.prefix(rulesFileLimit), as: UTF8.self)
        return data.count > rulesFileLimit ? text + "\n… (truncated)" : text
    }

    private static func packageJSONRules(at root: URL) -> String? {
        guard
            let data = try? Data(contentsOf: root.appending(path: "package.json")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rules = object["commitlint"],
            let encoded = try? JSONSerialization.data(
                withJSONObject: rules, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(decoding: encoded.prefix(rulesFileLimit), as: UTF8.self)
    }

    // MARK: Prompt

    /// The convention as a section of the prompt, or an empty string.
    ///
    /// Fenced like the diff, and for the same reason: a config file is the
    /// repository's content, not Grove's instruction.
    func promptSection(subjectLimit: Int) -> String {
        var text = ""
        if !rules.isEmpty {
            text += "This repository checks commit messages with commitlint. "
            text += "The message must pass these rules:\n"
            for file in rules {
                text += "--- BEGIN \(file.name) ---\n\(file.contents)\n--- END \(file.name) ---\n"
            }
            text += "\n"
        }
        let subjects = recentSubjects.prefix(subjectLimit)
        if !subjects.isEmpty {
            text += "Recent commit subjects in this repository, newest first:\n"
            text += subjects.map { "- \($0)" }.joined(separator: "\n")
            text += "\n\n"
        }
        return text
    }
}
