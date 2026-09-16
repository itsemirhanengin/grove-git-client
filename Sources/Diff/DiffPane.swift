import SwiftUI

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

    @State private var patch = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var generation = 0

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
            .background(Palette.diffCanvas.color)
            // `spacing: 0`, or the bar floats a gap below the toolbar and the
            // file name sits noticeably lower than the list beside it.
            .safeAreaBar(edge: .top, spacing: 0) { headerBar }
            .task(id: taskKey) { await load() }
    }

    private var taskKey: String {
        "\(repo.id.path)|\(change.displayPath)|\(selection.staged)|\(contextLines)"
    }

    // MARK: Header

    private var headerBar: some View {
        VStack(spacing: 0) {
            titleRow
            informationRow
            Divider()
        }
        .background(.bar)
    }

    private var titleRow: some View {
        HStack(spacing: Space.sm) {
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
            if change.isStaged && change.isUnstaged {
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
        .padding(.horizontal, Space.lg)
        .frame(height: 26)
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

    /// One dense line under the file name, the way Tower puts it: what happened,
    /// and how much of it.
    private var informationRow: some View {
        HStack(spacing: Space.xs) {
            Text(informationItems.joined(separator: "  ·  "))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(Typography.secondaryDetail.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            DiffWebView(payload: payload, onError: { loadError = $0 })
        }
    }

    private var payload: DiffPayload {
        DiffPayload(
            patch: patch,
            fileName: change.displayPath,
            diffStyle: diffStyle,
            themeType: colorScheme == .dark ? .dark : .light,
            fontSize: Typography.diffSize,
            canvas: Palette.diffCanvas.hexString(for: colorScheme),
            generation: generation
        )
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            patch = try await repo.diff(
                for: change, staged: selection.staged, contextLines: contextLines)
            generation += 1
        } catch {
            loadError = "\(error)"
            patch = ""
        }
    }
}
