import AppKit
import SwiftUI

/// One commit, whole: who made it, what it says, and every file it touched in a
/// single scroll.
///
/// This replaces the old three-step read — pick a commit, *then* pick a file,
/// *then* see a diff — which made the one question anybody actually opens
/// history to ask ("what changed here?") take two clicks and a mental note of
/// which file you were on. A changeset answers it by scrolling.
///
/// The split is deliberate. Everything above the diff is real AppKit: it holds
/// hashes worth selecting, dates worth reading in the system's own format, and a
/// disclosure worth having behave like every other one on the machine. The diff
/// below it is the web renderer, because `CodeView` virtualizes per line and is
/// the reason a ten-thousand-file commit opens at all.
struct CommitChangesetPane: View {
    let repo: RepoViewModel
    let commit: CommitInfo

    /// Collapsed state for the metadata table, remembered across commits. The
    /// table is eight fixed rows; someone who does not want them should not have
    /// to close them again for every commit they look at.
    @AppStorage("commitMetadataExpanded") private var isMetadataExpanded = true

    /// What the page reports back once it has parsed the patch.
    @State private var files: [ChangesetFile] = []
    @State private var collapsedCount = 0
    @State private var renderError: String?

    @State private var command: ChangesetCommand?
    @State private var commandCounter = 0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        diff
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .diffBackground()
            // `spacing: 0`, or the bar floats a gap below the toolbar and the
            // header sits noticeably lower than the list beside it.
            .safeAreaBar(edge: .top, spacing: 0) { header }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            identityBar

            if isMetadataExpanded {
                metadata
            }

            message
            summaryBar
        }
        .background(Palette.headerFill.color)
    }

    /// The one row that is always there: which commit this is, and the control
    /// that opens the rest.
    private var identityBar: some View {
        PaneHeader {
            Text(commit.shortOID)
                .font(Typography.keyHint)
                .textSelection(.enabled)

            Spacer(minLength: Space.md)

            Button {
                withAnimation(.smooth(duration: 0.2)) { isMetadataExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isMetadataExpanded ? 0 : -90))
            }
            .buttonStyle(.header)
            .help(isMetadataExpanded ? "Hide commit details" : "Show commit details")
            .accessibilityLabel("Commit details")
        }
    }

    /// Author, committer and the three ids.
    ///
    /// A table rather than a paragraph, because every value in it is something
    /// you came here to copy or to compare against another commit — and a
    /// right-aligned label column gives the values a single left edge to be read
    /// down.
    private var metadata: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Grid(
                alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.lg,
                verticalSpacing: 3
            ) {
                row("Author", "\(commit.authorName) <\(commit.authorEmail)>")
                if let date = commit.date { row("Author Date", Self.long(date)) }

                // Always shown, even when it repeats the author. Its absence
                // would be the only thing distinguishing an ordinary commit from
                // a rebased one, and an absence is not something anybody reads.
                // It is dimmed instead when it says nothing new.
                row(
                    "Committer", "\(commit.committerName) <\(commit.committerEmail)>",
                    isNotable: commit.wasRecommitted)
                if let date = commit.committerDate {
                    row("Commit Date", Self.long(date), isNotable: commit.wasRecommitted)
                }

                if !commit.refs.isEmpty {
                    GridRow {
                        Text("Refs")
                            .font(Typography.secondaryDetail)
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(.trailing)

                        HStack(spacing: 3) {
                            ForEach(commit.refs) { RefBadge(ref: $0) }
                        }
                        .gridColumnAlignment(.leading)
                    }
                }

                row("Commit Hash", commit.oid, isMonospaced: true)
                if !commit.parents.isEmpty {
                    row(
                        commit.parents.count > 1 ? "Parent Hashes" : "Parent Hash",
                        commit.parents.joined(separator: "  "),
                        isMonospaced: true)
                }
                row("Tree Hash", commit.treeOID, isMonospaced: true)
            }

            Spacer(minLength: Space.md)

            Avatar(name: commit.authorName, email: commit.authorEmail, size: 44)
                .help(commit.authorEmail)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.bottom, color: Palette.rowSeparator.color)
    }

    @ViewBuilder
    private func row(
        _ label: String, _ value: String, isMonospaced: Bool = false, isNotable: Bool = true
    ) -> some View {
        GridRow {
            Text(label)
                .font(Typography.secondaryDetail)
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.trailing)

            Text(value)
                .font(isMonospaced ? Typography.keyHint : Typography.secondaryDetail)
                .foregroundStyle(isNotable ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .gridColumnAlignment(.leading)
        }
    }

    /// The message: subject, then body.
    ///
    /// Given real width and real line breaks, which is the whole reason the old
    /// layout's six-line clamp in a 280pt drawer was worth replacing. A commit
    /// message is the only prose in the repository and the one place its author
    /// explained themselves.
    @ViewBuilder
    private var message: some View {
        let text = repo.selectedCommitMessage.isEmpty ? commit.subject : repo.selectedCommitMessage
        let (subject, body) = Self.split(text)

        VStack(alignment: .leading, spacing: Space.sm) {
            Text(subject)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !body.isEmpty {
                Text(body)
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the commit changed, and the control over how much of it is open.
    private var summaryBar: some View {
        ColumnHeader {
            Button(isEverythingCollapsed ? "Expand All" : "Collapse All") {
                perform(.setCollapsed(!isEverythingCollapsed))
            }
            .buttonStyle(.link)
            .disabled(files.isEmpty)

            Spacer(minLength: Space.md)

            Text(repo.selectedCommitStats.summary)
                .lineLimit(1)
        }
    }

    private var isEverythingCollapsed: Bool {
        !files.isEmpty && collapsedCount == files.count
    }

    // MARK: Diff

    /// The diff, and whatever has to be said when there is not one yet.
    ///
    /// The web view is **always mounted**, and merely faded out while there is
    /// nothing to show. Swapping it in and out of the hierarchy instead — the
    /// obvious `if patch.isEmpty` — would tear down the `WKWebView` and build a
    /// new one for every commit clicked, which means loading and parsing the
    /// renderer again each time. Kept mounted, moving between commits is one
    /// message across the bridge.
    private var diff: some View {
        ZStack {
            DiffWebView(
                content: .changeset(payload),
                onError: { renderError = $0 },
                onChangeset: { rendered, collapsed in
                    files = rendered
                    collapsedCount = collapsed
                },
                command: command
            )
            .opacity(hasPatch ? 1 : 0)
            .accessibilityHidden(!hasPatch)

            placeholder
        }
        // The page reports the file list; a stale error from the previous commit
        // would otherwise sit over the new one's diff forever.
        .onChange(of: commit.oid) {
            renderError = nil
            files = []
            collapsedCount = 0
        }
    }

    private var hasPatch: Bool { !repo.selectedCommitPatch.isEmpty }

    @ViewBuilder
    private var placeholder: some View {
        if let error = renderError ?? repo.commitPatchError {
            ContentUnavailableView(
                "Could not load this commit",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if !hasPatch {
            if repo.isLoadingCommitPatch {
                ProgressView()
                    .controlSize(.small)
            } else {
                ContentUnavailableView(
                    commit.isMerge ? "Nothing against the first parent" : "No changes",
                    systemImage: commit.isMerge ? "arrow.triangle.merge" : "doc",
                    description: Text(
                        commit.isMerge
                            ? "This merge resolved cleanly, so it has no changes of its own."
                            : "This commit touched no files.")
                )
            }
        }
    }

    private var payload: ChangesetPayload {
        ChangesetPayload(
            patch: repo.selectedCommitPatch,
            // The commit's own id. Two commits can then never share an item id
            // in the page, and reopening one reuses everything it highlighted
            // the first time.
            key: commit.oid,
            diffStyle: .unified,
            generation: 0,
            appearance: .resolved(for: colorScheme)
        )
    }

    private func perform(_ kind: ChangesetCommand.Kind) {
        commandCounter += 1
        command = ChangesetCommand(id: commandCounter, kind: kind)
    }

    // MARK: Formatting

    /// `22 September 2026 at 13:11:33 GMT+3` — the full thing, because this is
    /// the one place in Grove that is not a relative date. "6 days ago" is what
    /// the list is for; the detail is where you check whether two commits were
    /// minutes or months apart.
    private static func long(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .day().month(.wide).year()
                .hour().minute().second()
                .timeZone(.specificName(.short))
        )
    }

    /// Splits a message into its subject and the rest.
    ///
    /// git's own convention: the first line, then a blank line, then the body.
    /// A message that never blank-lines is all subject, which is what `-m` with
    /// one argument produces and by far the most common case.
    private static func split(_ message: String) -> (subject: String, body: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.firstIndex(of: "\n") else { return (trimmed, "") }

        return (
            String(trimmed[trimmed.startIndex..<newline]),
            String(trimmed[trimmed.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
