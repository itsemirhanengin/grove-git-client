import SwiftUI

/// A conflicted file, and the three ways out of it.
///
/// The page shows the working-tree text with its conflict markers and draws
/// Accept Current / Incoming / Both in the gutter of each region; taking one
/// hands the **whole** resolved file back over the bridge, which Swift writes to
/// disk — and stages, once nothing is left to resolve. Everything else — take
/// one side wholesale, mark it settled, abandon the merge — is native, because
/// those are decisions about the repository rather than about the text.
struct ConflictPane: View {
    let repo: RepoViewModel
    let change: FileChange

    /// The text sent to the page. Written **only** by ``load()``.
    @State private var contents = ""

    /// What the page last handed back. Deliberately kept out of ``contents``:
    /// writing it there would change the payload, re-render the page, and hand
    /// `UnresolvedFile` a second parse of a file it has already taken ownership
    /// of — which is an error, not a refresh.
    @State private var resolved: String?

    @State private var isLoading = false
    @State private var loadError: String?
    @State private var generation = 0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .diffBackground()
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .safeAreaBar(edge: .bottom, spacing: 0) { actions }
            .task(id: taskKey) { await load() }
    }

    /// Reloaded when the file's index stages change — taking a side rewrites
    /// the file on disk, and the old text is then a lie.
    private var taskKey: String {
        let stages = change.unmergedStages
        return [
            repo.id.path, change.displayPath,
            stages?.base ?? "", stages?.ours ?? "", stages?.theirs ?? "",
        ].joined(separator: "|")
    }

    // MARK: Header

    private var header: some View {
        PaneHeader {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Palette.attention.color)

            Text(change.singleLineFileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if !change.directoryPrefix.isEmpty {
                Text(FileChange.sanitizeForSingleLine(change.directoryPrefix))
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }

            Spacer(minLength: Space.md)

            Text("Conflicted")
                .font(Typography.secondaryDetail)
                .foregroundStyle(Palette.attention.color)
        }
    }

    private var subtitle: String {
        if loadError != nil { return "Could not show this conflict" }
        if isLoading { return "Loading…" }
        let operation = repo.status.inProgress?.label ?? "Conflicted"
        // An add/add conflict has no common ancestor, which is worth saying:
        // there is no "what it used to be" to compare against.
        let hasBase = !(change.unmergedStages?.base.isEmpty ?? true)
        return hasBase ? operation : "\(operation) · added on both sides, no common ancestor"
    }

    // MARK: Actions

    private var actions: some View {
        StatusBar {
            Text(subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: Space.md)

            if let operation = repo.status.inProgress {
                Button("Abort \(operation.label)", role: .destructive) {
                    repo.abortInProgress()
                }
                .controlSize(.small)
                .disabled(repo.isBusy)
            }

            Button(RepoEngine.ConflictSide.ours.title) {
                repo.resolve(change, using: .ours)
            }
            .controlSize(.small)
            .disabled(repo.isBusy)
            .help("Discard the incoming version of this file entirely")

            Button(RepoEngine.ConflictSide.theirs.title) {
                repo.resolve(change, using: .theirs)
            }
            .controlSize(.small)
            .disabled(repo.isBusy)
            .help("Discard your version of this file entirely")

            Button("Mark Resolved") { repo.markResolved(change) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(repo.isBusy || hasMarkers)
                .help(
                    hasMarkers
                        ? "Conflict markers are still in the file"
                        : "Stage this file as resolved"
                )
        }
    }

    /// Refuses to let a file be marked resolved while `<<<<<<<` is still in it.
    ///
    /// Committing conflict markers is the single most common way a merge goes
    /// wrong, and it is trivially detectable. The same check gates staging
    /// inside ``RepoEngine/applyResolution(_:to:)``.
    private var hasMarkers: Bool {
        RepoEngine.containsConflictMarkers(resolved ?? contents)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Could not open this conflict",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if contents.isEmpty && isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffWebView(
                content: .conflict(payload),
                onError: { loadError = $0 },
                onConflictResolved: { text in
                    // The page owns the document from here on — it fires once
                    // per region, and each time hands back the whole file. This
                    // is the only thing that puts it on disk.
                    resolved = text
                    repo.applyResolution(text, to: change)
                }
            )
        }
    }

    private var payload: ConflictPayload {
        ConflictPayload(
            fileName: change.displayPath,
            contents: contents,
            generation: generation,
            appearance: .resolved(for: colorScheme)
        )
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        resolved = nil
        do {
            contents = try await repo.conflictedContents(for: change)
            // Part of the page's cache key, so a genuinely new document gets a
            // new `UnresolvedFile` rather than a second parse of the old one.
            generation += 1
        } catch let error as GitError {
            loadError = RepoViewModel.message(for: error)
            contents = ""
        } catch {
            loadError = "\(error)"
            contents = ""
        }
    }
}
