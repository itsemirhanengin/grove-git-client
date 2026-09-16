import Foundation

nonisolated struct DiscoveryConfig: Sendable {

    /// How far below the workspace root to look.
    ///
    /// Four covers `workspace/project`, `workspace/group/project` and
    /// `workspace/packages/*/project`, which is the realistic range. Going
    /// deeper mostly finds vendored dependencies.
    var maxDepth = 4

    /// Whether to keep descending after finding a repository. Off by default:
    /// what lies below a repository is usually vendored code or submodules, and
    /// submodules are better enumerated per repository on demand.
    var includeNestedRepos = false

    /// Directory names never descended into. Pruning by name *before* reading a
    /// directory is what keeps a scan fast — `node_modules` alone can hold tens
    /// of thousands of entries.
    var prunedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage",
        "vendor", "target", ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache",
        ".tox", "dist", "build", "out", ".next", ".nuxt", ".svelte-kit", ".turbo",
        ".gradle", ".cargo", ".terraform", ".direnv", ".cache", "coverage", "Library",
        ".Trash", ".idea", ".vscode",
    ]

    /// Extra names to skip, from a workspace's own settings.
    var extraIgnores: Set<String> = []

    /// Widest fan-out of concurrent directory reads.
    var maxConcurrentReads = 8

    func shouldPrune(_ name: String) -> Bool {
        prunedDirectoryNames.contains(name) || extraIgnores.contains(name)
    }
}

/// Finds the git repositories under a workspace folder.
///
/// Deliberately runs **no git processes**: the presence of `.git` is sufficient
/// evidence, and spawning a `git rev-parse` per candidate would dominate the
/// cost. Validation happens later, once, per confirmed repository.
nonisolated enum RepoDiscovery {

    static func scan(root: URL, config: DiscoveryConfig = DiscoveryConfig()) async -> [Repository] {
        var found: [Repository] = []
        var frontier = [root]
        var depth = 0

        while !frontier.isEmpty, depth <= config.maxDepth {
            var nextFrontier: [URL] = []
            // Captured by the child tasks below, so it must be an immutable copy
            // rather than the loop's mutable `depth`.
            let currentDepth = depth

            // Bounded fan-out: a level can be wide, and letting it run
            // unbounded would spawn a task per directory on a big workspace.
            for batch in frontier.chunked(into: config.maxConcurrentReads) {
                let results = await withTaskGroup(of: Inspection.self) { group in
                    for directory in batch {
                        group.addTask { inspect(directory, depth: currentDepth, config: config) }
                    }
                    var collected: [Inspection] = []
                    for await result in group { collected.append(result) }
                    return collected
                }

                for result in results {
                    if let repository = result.repository { found.append(repository) }
                    nextFrontier.append(contentsOf: result.children)
                }
            }

            frontier = nextFrontier
            depth += 1
        }

        // Stable order so the sidebar never reshuffles between scans.
        return found.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - One directory

    private struct Inspection: Sendable {
        var repository: Repository?
        var children: [URL]
    }

    private static func inspect(
        _ directory: URL, depth: Int, config: DiscoveryConfig
    )
        -> Inspection
    {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]

        // Prefetching these keys means one bulk attribute fetch for the whole
        // directory rather than a stat() per child.
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            )
        else {
            return Inspection(repository: nil, children: [])
        }

        var children: [URL] = []
        var gitEntry: URL?

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))

            // Symlinks are skipped outright. Not following them removes cycle
            // detection, infinite loops and duplicate repositories in one go.
            if values?.isSymbolicLink == true { continue }

            let name = entry.lastPathComponent
            if name == ".git" {
                gitEntry = entry
                continue
            }

            guard values?.isDirectory == true else { continue }
            if config.shouldPrune(name) { continue }
            children.append(entry)
        }

        guard let gitEntry else {
            return Inspection(repository: nil, children: children)
        }

        let repository = makeRepository(root: directory, gitEntry: gitEntry, depth: depth)

        return Inspection(
            repository: repository,
            // Below a repository is normally vendored code, so stop unless asked.
            children: config.includeNestedRepos ? children : []
        )
    }

    /// Resolves what a `.git` entry actually points at.
    ///
    /// A `.git` **file** rather than a directory means a linked worktree or a
    /// submodule; it holds `gitdir: <path>`, which may be relative. Getting this
    /// wrong matters beyond classification: the in-progress-merge marker files
    /// live at that resolved location, not at `root/.git`.
    private static func makeRepository(root: URL, gitEntry: URL, depth: Int) -> Repository {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: gitEntry.path(), isDirectory: &isDirectory)

        guard !isDirectory.boolValue else {
            return Repository(root: root, gitPath: gitEntry, kind: .standard, depth: depth)
        }

        guard
            let contents = try? String(contentsOf: gitEntry, encoding: .utf8),
            let line = contents.split(separator: "\n").first(where: {
                $0.hasPrefix("gitdir:")
            })
        else {
            // A `.git` file we cannot read still marks a repository; let git
            // itself report the problem later rather than hiding the folder.
            return Repository(root: root, gitPath: gitEntry, kind: .standard, depth: depth)
        }

        let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let resolved =
            rawPath.hasPrefix("/")
            ? URL(filePath: rawPath)
            : URL(filePath: rawPath, relativeTo: gitEntry.deletingLastPathComponent())
                .standardizedFileURL

        let kind: RepositoryKind =
            resolved.path().contains("/worktrees/")
            ? .worktree
            : resolved.path().contains("/modules/") ? .submodule : .standard

        return Repository(root: root, gitPath: resolved, kind: kind, depth: depth)
    }
}

nonisolated extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [Array(self)] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
