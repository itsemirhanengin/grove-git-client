import CoreServices
import Foundation

/// One repository as the watcher sees it.
///
/// Both paths are **resolved through symlinks**, because that is how FSEvents
/// reports them: a workspace under `/var/folders/…` arrives as
/// `/private/var/folders/…`, and a prefix match against the unresolved path
/// silently never fires.
nonisolated struct WatchedRepository: Sendable, Equatable {

    var id: RepoID

    /// Working-tree root, without a trailing slash.
    var root: String

    /// Resolved `.git` location, without a trailing slash. For a linked
    /// worktree or a submodule this is **not** under `root`, which is why it is
    /// watched separately rather than assumed to be inside it.
    var gitPath: String

    init(_ repository: Repository) {
        self.id = repository.id
        self.root = Self.resolve(repository.root)
        self.gitPath = Self.resolve(repository.gitPath)
    }

    init(id: RepoID, root: String, gitPath: String) {
        self.id = id
        self.root = root
        self.gitPath = gitPath
    }

    /// The **physical** path, through `realpath(3)`.
    ///
    /// Not `URL.resolvingSymlinksInPath()`, which resolves symlinks and then
    /// *strips* a leading `/private` — the exact opposite of what is needed
    /// here. FSEvents reports `/private/var/…`; a root normalised to `/var/…`
    /// never matches a single event, and the failure is completely silent.
    private static func resolve(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if let physical = realpath(path, nil) {
            path = String(cString: physical)
            free(physical)
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The paths this repository needs FSEvents to cover.
    ///
    /// Overlapping paths are fine — the stream folds a child into its parent —
    /// so a standard repository harmlessly contributes its root twice over.
    var watchPaths: [String] { [root, gitPath] }
}

/// Decides whether a changed file is something `git status` would notice.
///
/// Split out from the stream so it can be tested as what it is: a pure function
/// over paths. The stream itself cannot be tested without a filesystem race.
nonisolated enum RepoEventFilter {

    /// Which repository should refresh because of this path, if any.
    ///
    /// Attribution is **longest prefix wins**, and `.git` directories are
    /// matched before working trees. Repositories nest — a submodule's root
    /// lives inside its parent's — so the shortest match is almost always the
    /// wrong one.
    static func affected(by path: String, in repositories: [WatchedRepository]) -> RepoID? {
        var best: WatchedRepository?
        var bestLength = -1

        for repository in repositories {
            for candidate in [repository.gitPath, repository.root]
            where isUnder(path, candidate) && candidate.count > bestLength {
                best = repository
                bestLength = candidate.count
            }
        }

        guard let best else { return nil }
        return matters(path, in: best) ? best.id : nil
    }

    /// Whether a path inside a known repository is worth a refresh.
    static func matters(_ path: String, in repository: WatchedRepository) -> Bool {
        // Every lock file git writes is churn by definition — it exists only
        // while a command runs. `index.lock` alone appears and disappears
        // several times per command and is the single noisiest source there is.
        if path.hasSuffix(".lock") { return false }

        if isUnder(path, repository.gitPath) {
            return mattersInsideGitDirectory(
                String(path.dropFirst(repository.gitPath.count).drop(while: { $0 == "/" }))
            )
        }

        guard isUnder(path, repository.root) else { return false }

        // A `.git` that is not *this* repository's belongs to a nested one, or
        // is the pointer file of a linked worktree. Either way it says nothing
        // about this repository's status.
        return !containsGitDirectory(String(path.dropFirst(repository.root.count)))
    }

    /// The allow-list inside `.git`.
    ///
    /// Deliberately an allow-list rather than a deny-list: git rewrites its own
    /// bookkeeping constantly — objects, logs, `FETCH_HEAD`, `COMMIT_EDITMSG` —
    /// and none of it changes what the sidebar shows. Only these do.
    private static func mattersInsideGitDirectory(_ relative: String) -> Bool {
        switch relative {
        case "HEAD", "index", "packed-refs",
            "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG":
            return true
        default:
            break
        }

        // Grove's own backup refs. Writing one is part of a destructive
        // operation that refreshes on its own; hearing about it again would be
        // a second refresh for the same event.
        if relative.hasPrefix("refs/grove/") { return false }

        return relative.hasPrefix("refs/")
            || relative == "rebase-merge" || relative.hasPrefix("rebase-merge/")
            || relative == "rebase-apply" || relative.hasPrefix("rebase-apply/")
    }

    /// `path` is `prefix` itself, or lives beneath it.
    private static func isUnder(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func containsGitDirectory(_ relative: String) -> Bool {
        relative == "/.git" || relative.hasPrefix("/.git/") || relative.contains("/.git/")
    }
}

/// Live refresh: one FSEvents stream over every repository in the workspace.
///
/// One stream rather than one per repository. FSEvents folds overlapping paths
/// together, and ten streams would mean ten wake-ups for one `git checkout` in
/// a workspace where the repositories sit side by side.
///
/// `@unchecked Sendable` because the state below is reached from two places that
/// cannot share an actor: the caller, and a `@convention(c)` callback delivered
/// on `queue`. `lock` is what actually protects it.
nonisolated final class RepoWatcher: @unchecked Sendable {

    /// FSEvents' own coalescing window. Its job is to turn the burst of writes
    /// one git command makes into a handful of wake-ups instead of hundreds.
    private static let latency: CFTimeInterval = 0.2

    /// Quiet time before a refresh actually goes out.
    private static let debounce: UInt64 = 300_000_000

    /// …and the longest a refresh will be held back while writes keep arriving.
    /// Without this, a running build never leaves 300 ms of quiet and the
    /// sidebar would stay stale for as long as it ran.
    private static let maximumDelay: UInt64 = 2_000_000_000

    private let onChange: @MainActor @Sendable (Set<RepoID>) -> Void
    private let queue = DispatchQueue(label: "com.emirhanengin.grove.fsevents")
    private let lock = NSLock()

    private var stream: FSEventStreamRef?
    private var repositories: [WatchedRepository] = []
    private var pending: Set<RepoID> = []
    private var firstPendingAt: UInt64?
    private var flush: DispatchWorkItem?

    init(onChange: @escaping @MainActor @Sendable (Set<RepoID>) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    // MARK: Lifecycle

    /// Starts watching exactly these repositories, replacing whatever was being
    /// watched before.
    func watch(_ repositories: [Repository]) {
        let watched = repositories.map(WatchedRepository.init)

        lock.lock()
        let unchanged = watched == self.repositories && stream != nil
        lock.unlock()
        guard !unchanged else { return }

        stop()
        guard !watched.isEmpty else { return }

        lock.lock()
        self.repositories = watched
        lock.unlock()

        var paths: [String] = []
        for repository in watched {
            for candidate in repository.watchPaths where !paths.contains(candidate) {
                paths.append(candidate)
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // `FileEvents` is what makes the `.lock` filtering possible at all —
        // without it FSEvents reports the *directory*, and `.git` changing tells
        // us nothing about whether it was `index` or `index.lock`.
        let flags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                repoWatcherCallback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.latency,
                flags
            )
        else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }

        lock.lock()
        stream = created
        lock.unlock()
    }

    /// Tears the stream down so that no callback can still be in flight.
    ///
    /// Stop, invalidate, release — and **not** `FSEventStreamSetDispatchQueue(…,
    /// nil)` first. Detaching the queue unschedules the stream, and invalidating
    /// an unscheduled stream trips a client assertion inside FSEvents:
    /// *"Must call FSEventStreamScheduleWithRunLoop() before calling
    /// FSEventStreamInvalidate()"*. Draining `queue` afterwards is what actually
    /// guarantees no callback is still running, which is what makes the
    /// unretained `info` pointer above safe.
    func stop() {
        lock.lock()
        let existing = stream
        stream = nil
        repositories = []
        pending = []
        firstPendingAt = nil
        let scheduled = flush
        flush = nil
        lock.unlock()

        scheduled?.cancel()

        guard let existing else { return }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)

        // `queue` is serial, so once an empty block has run on it, whatever
        // callback was in flight when we invalidated has finished.
        queue.sync {}
    }

    // MARK: Events

    /// Called on `queue` for every batch FSEvents delivers.
    ///
    /// - Parameter mustRescan: FSEvents dropped events rather than queue them,
    ///   so what changed is unknowable and everything is suspect.
    fileprivate func receive(paths: [String], mustRescan: Bool) {
        lock.lock()
        let repositories = self.repositories
        lock.unlock()
        guard !repositories.isEmpty else { return }

        var affected: Set<RepoID> = []
        if mustRescan {
            affected = Set(repositories.map(\.id))
        } else {
            for path in paths {
                if let id = RepoEventFilter.affected(by: path, in: repositories) {
                    affected.insert(id)
                }
            }
        }
        guard !affected.isEmpty else { return }

        lock.lock()
        pending.formUnion(affected)
        let now = DispatchTime.now().uptimeNanoseconds
        if firstPendingAt == nil { firstPendingAt = now }
        let deadline = min(now + Self.debounce, (firstPendingAt ?? now) + Self.maximumDelay)
        flush?.cancel()

        let work = DispatchWorkItem { [weak self] in self?.deliver() }
        flush = work
        lock.unlock()

        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: work)
    }

    private func deliver() {
        lock.lock()
        let ready = pending
        pending = []
        firstPendingAt = nil
        flush = nil
        lock.unlock()

        guard !ready.isEmpty else { return }
        let callback = onChange
        Task { @MainActor in callback(ready) }
    }
}

/// The C callback. A `@convention(c)` function captures nothing, so the watcher
/// arrives through the stream context's `info` pointer.
///
/// `nonisolated` is not decoration: this module defaults to `MainActor`
/// isolation, and an isolated function cannot be converted to a C function
/// pointer at all.
private nonisolated func repoWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, count > 0 else { return }
    let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()

    guard let reported = unsafeBitCast(paths, to: CFArray.self) as? [String] else { return }

    var mustRescan = false
    for index in 0..<count {
        let flag = flags[index]
        if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            || flag & UInt32(kFSEventStreamEventFlagUserDropped) != 0
            || flag & UInt32(kFSEventStreamEventFlagKernelDropped) != 0
            || flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0
        {
            mustRescan = true
            break
        }
    }

    watcher.receive(paths: reported, mustRescan: mustRescan)
}
