import DiffCore
import SwiftUI

/// Which version of a file a diff is of.
///
/// One pane for all three, because the difference between them is entirely in
/// which two blobs git is asked about — everything above and below is the same
/// header, the same renderer and the same scroll position.
enum DiffOrigin: Equatable, Sendable {
    case workingCopy
    case commit(String)
    case stash(StashEntry)

    /// Part of the reload key, so switching between two commits reloads.
    var key: String {
        switch self {
        case .workingCopy: ""
        case .commit(let oid): "commit:\(oid)"
        case .stash(let stash): "stash:\(stash.oid)"
        }
    }

    /// What replaces the Staged / Unstaged switch, which only the working copy
    /// has two sides to offer.
    var sideLabel: String? {
        switch self {
        case .workingCopy: nil
        case .commit: "In commit"
        case .stash: "In stash"
        }
    }
}

/// The diff column.
///
/// Laid out after Tower, top to bottom: a tight title row with the file name and
/// a Staged / Unstaged switch, one line of information about the change, and
/// then the diff, which takes everything that is left.
///
/// Everything except the diff body is real AppKit, through SwiftUI. Only the
/// middle is a web view, and it renders the diff and nothing else — no header,
/// no chrome, no controls it would have to fake.
///
/// The title and information rows go in a **`safeAreaBar(edge: .top)`** rather
/// than at the top of a `VStack`. A detail column's content extends under the
/// window's toolbar, so a plain stack puts its first rows behind the glass,
/// where they are invisible.
struct DiffPane: View {
    let repo: RepoViewModel
    let selection: SelectedChange

    /// Where the diff comes from. Anything but the working copy is read-only:
    /// there is no staged side to switch to and nothing to stage, so both of
    /// those controls disappear.
    var origin: DiffOrigin = .workingCopy

    @State private var patch = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var generation = 0

    /// The patch, parsed once per load rather than on every body evaluation —
    /// a 50k-line diff is not something to walk while laying out a toolbar.
    @State private var parsed: PatchFile?

    /// What the user has picked in the diff, already matched against `parsed`.
    @State private var picked = ResolvedDiffSelection()

    /// Bumped to ask the page to drop its highlight once a pick is consumed.
    @State private var clearToken = 0

    /// How much unchanged code surrounds each change, and whether the diff is
    /// stacked or side by side.
    ///
    /// Fixed here on purpose. Both belong in Settings, where they are set once
    /// for every diff, rather than as controls in a bar under each one.
    private let contextLines = 3
    private let diffStyle: DiffPayload.Style = .unified

    @Environment(\.colorScheme) private var colorScheme

    private var change: FileChange { selection.change }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .diffBackground()
            // `spacing: 0`, or the bar floats a gap below the toolbar and the
            // file name sits noticeably lower than the list beside it.
            .safeAreaBar(edge: .top, spacing: 0) { headerBar }
            // One bar, always there. It used to appear only while rows were
            // picked, which meant the diff shifted under the cursor at the exact
            // moment you were pointing at a line. Now it states what the file
            // changed, and grows actions on the right when there is a selection
            // for them to act on.
            .safeAreaBar(edge: .bottom, spacing: 0) { footerBar }
            .task(id: taskKey) { await load() }
    }

    private var taskKey: String {
        [
            repo.id.path, origin.key, change.displayPath,
            "\(selection.staged)", "\(contextLines)",
        ].joined(separator: "|")
    }

    // MARK: Header

    private var headerBar: some View {
        PaneHeader {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(change.tint(staged: selection.staged))

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

            // Both sides of a file that is staged *and* modified again are worth
            // looking at, so this is a switch rather than a label. A file that
            // exists on only one side gets a label instead of a dead control.
            if let label = origin.sideLabel {
                Text(label)
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
            } else if change.isStaged && change.isUnstaged {
                Picker("", selection: stagedBinding) {
                    Text("Staged").tag(true)
                    Text("Unstaged").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            } else {
                Text(selection.staged ? "Staged" : "Unstaged")
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stagedBinding: Binding<Bool> {
        Binding(
            get: { selection.staged },
            set: { repo.selectedChange = SelectedChange(change: change, staged: $0) }
        )
    }

    private var symbol: String {
        if change.isConflicted { return "exclamationmark.triangle" }
        switch (selection.staged ? change.indexStatus : change.worktreeStatus) {
        case .deleted: return "trash"
        case .renamed, .copied: return "arrow.triangle.turn.up.right.diamond"
        default: return "doc.text"
        }
    }

    /// Counted from the patch text rather than parsed into a model.
    ///
    /// It is a header line and a running total — the two things that do not
    /// need structure. Everything that does need structure is the renderer's
    /// job, and a parser in Swift would only be a second opinion about it.
    private var informationItems: [String] {
        if loadError != nil { return ["Could not load the diff"] }
        if patch.isEmpty { return [isLoading ? "Loading…" : "No changes"] }

        var added = 0
        var removed = 0
        var hunks = 0
        var isBinary = false

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                hunks += 1
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                continue
            } else if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                removed += 1
            } else if line.hasPrefix("Binary files") {
                isBinary = true
            }
        }

        var items = [statusDescription]
        if isBinary { return items }
        if hunks > 0 { items.append(hunks == 1 ? "1 chunk" : "\(hunks) chunks") }
        items.append("+\(added)  −\(removed)")
        return items
    }

    private var statusDescription: String {
        if change.isConflicted { return "Conflicted" }
        if change.kind == .untracked { return "New file" }
        switch selection.staged ? change.indexStatus : change.worktreeStatus {
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed:
            return change.originalDisplayPath.map { "Renamed from \($0)" } ?? "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        default: return "Modified"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Could not load the diff",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if patch.isEmpty && isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffWebView(
                content: .diff(payload),
                onError: { loadError = $0 },
                onSelection: { range in
                    guard let parsed, let range else {
                        picked = ResolvedDiffSelection()
                        return
                    }
                    picked = range.resolve(in: parsed)
                },
                clearSelectionToken: clearToken
            )
        }
    }

    private var payload: DiffPayload {
        DiffPayload(
            patch: patch,
            fileName: change.displayPath,
            diffStyle: diffStyle,
            generation: generation,
            appearance: .resolved(for: colorScheme)
        )
    }

    // MARK: - Footer

    /// The one bar under a diff: what the file changed, and — while rows are
    /// picked — what to do with them.
    ///
    /// Everything here is real AppKit: the page reports what was selected and
    /// stops there, because turning a selection into a patch is git's job and
    /// git is on this side of the bridge.
    private var footerBar: some View {
        StatusBar {
            Text(picked.isEmpty ? informationSummary : countLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: Space.md)

            if !picked.isEmpty, origin == .workingCopy {
                if canDiscard {
                    Button("Discard", role: .destructive) { apply(picked.lines, .discard) }
                        .controlSize(.small)
                }

                Button(chunkTitle) { apply(picked.chunks, primaryOperation) }
                    .controlSize(.small)
                    .disabled(repo.isBusy)

                Button(lineTitle) { apply(picked.lines, primaryOperation) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(repo.isBusy)
            }
        }
    }

    /// The header line and the running total, as one string.
    private var informationSummary: String {
        informationItems.joined(separator: "  ·  ")
    }

    /// Which way the picked lines move. The staged side can only send work
    /// back; the unstaged side can only send it forward.
    private var primaryOperation: RepoEngine.PartialOperation {
        selection.staged ? .unstage : .stage
    }

    private var countLabel: String {
        let lines = picked.lineCount == 1 ? "1 line" : "\(picked.lineCount) lines"
        return picked.chunkCount > 1
            ? "\(lines) across \(picked.chunkCount) chunks"
            : lines
    }

    private var lineTitle: String {
        selection.staged ? "Unstage Lines" : "Stage Lines"
    }

    private var chunkTitle: String {
        let noun = picked.chunkCount > 1 ? "Chunks" : "Chunk"
        return selection.staged ? "Unstage \(noun)" : "Stage \(noun)"
    }

    /// Untracked files are never patched in place — git has no record of them,
    /// so a backup ref cannot bring one back and the whole file goes to the
    /// Trash instead. That rule does not bend for a line.
    private var canDiscard: Bool {
        !selection.staged && change.kind != .untracked
    }

    private func apply(_ lines: PatchSelection, _ operation: RepoEngine.PartialOperation) {
        repo.applyPartial(to: change, diff: patch, selection: lines, operation: operation)
        picked = ResolvedDiffSelection()
        clearToken += 1
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        loadError = nil
        picked = ResolvedDiffSelection()
        defer { isLoading = false }

        do {
            switch origin {
            case .workingCopy:
                patch = try await repo.diff(
                    for: change, staged: selection.staged, contextLines: contextLines)
            case .commit(let oid):
                patch = try await repo.commitDiff(
                    for: change, in: oid, contextLines: contextLines)
            case .stash(let stash):
                patch = try await repo.stashFileDiff(
                    for: change, in: stash, contextLines: contextLines)
            }
            // A file with no hunks is a pure rename or a binary — nothing to
            // pick from, and the bar never appears.
            parsed = UnifiedPatchParser.parse(patch).first { !$0.hunks.isEmpty }
            generation += 1
        } catch {
            loadError = "\(error)"
            patch = ""
            parsed = nil
        }
    }
}
