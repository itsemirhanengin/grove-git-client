import SwiftUI

/// The Working Copy view: compose a commit above, tick what goes into it below.
///
/// The arrangement is Tower's — composer on top, file table beneath — for a
/// practical reason: a `TextField` inside a recycling `List` loses focus as rows
/// scroll, and every keystroke invalidates a row inside a virtualised container.
/// Here the composer lives outside the scrolling area entirely, so ⌘⏎ works no
/// matter where the table is scrolled to.
///
/// What changed in the redesign is underneath. There is no Staged group and no
/// Changes group any more: one table, one row per file, and a **checkbox** that
/// says whether that file is in the next commit. "Stage All" is then exactly
/// what it sounds like — tick every box — and ticking three boxes by hand
/// commits those three files and nothing else.
struct WorkingCopyPane: View {
    @Bindable var repo: RepoViewModel

    /// Needed only to route selection through ``WorkspaceModel/select(_:in:)``,
    /// so that a file opened here and a file opened in the Overview are the
    /// same kind of event.
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            CommitComposer(repo: repo)

            if repo.status.inProgress != nil {
                InProgressBanner(repo: repo)
            }

            ChangeTable(repo: repo, workspace: workspace)
        }
        .paneBackground()
    }
}

// MARK: - Composer

private struct CommitComposer: View {
    @Bindable var repo: RepoViewModel
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            TextField(
                "Message (⌘⏎ to commit on \"\(repo.branchLabel)\")",
                text: $repo.draftMessage,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(2...6)
            .focused($isMessageFocused)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(Palette.headerFill.color)
            // Square, and bordered rather than filled-and-rounded: the field is
            // the same shape as the table below it, so the composer reads as
            // part of the pane instead of a card sitting on it.
            .border(Palette.border.color, width: 1)

            if let generated = repo.lastGeneratedMessage {
                provenance(generated)
            }

            HStack(spacing: Space.md) {
                // One button, not two. "Stage All" next to a permanently dimmed
                // "Unstage All" spent a control on saying nothing; this one says
                // what the next click will do.
                Button(repo.isEverythingStaged ? "Unstage All" : "Stage All") {
                    repo.toggleStageAll()
                }
                .disabled(repo.status.changes.isEmpty)
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Spacer()

                if repo.isBusy || repo.isGeneratingMessage {
                    ProgressView().controlSize(.small)
                }

                // Writes into the draft and stops there. Grove never commits on
                // its own, so every generated message is read by a person first.
                Button {
                    repo.generateCommitMessage()
                } label: {
                    Image(systemName: "sparkles")
                        .symbolEffect(.pulse, isActive: repo.isGeneratingMessage)
                }
                .buttonStyle(.header)
                .disabled(!repo.canGenerateMessage)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help(generateHelp)

                Button("Commit") { repo.commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!repo.canCommit)
                    .help(commitHelp)
            }
        }
        .padding(Space.lg)
        .background(Palette.contentFill.color)
        .hairline(.bottom)
    }

    /// Says where a generated message came from, and admits when the model was
    /// only shown part of the diff.
    private func provenance(_ generated: GeneratedCommitMessage) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "sparkles")
            Text(
                generated.wasTruncated
                    ? "Written by \(generated.source.title) from part of the diff"
                    : "Written by \(generated.source.title)"
            )
            Spacer(minLength: 0)
            Button("Clear") {
                repo.draftMessage = ""
                repo.lastGeneratedMessage = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .font(Typography.secondaryDetail)
        .foregroundStyle(.secondary)
    }

    private var generateHelp: String {
        if repo.status.staged.isEmpty { return "Stage something first" }
        if !repo.canGenerateMessage {
            return OnDeviceWriter.unavailableReason
                ?? "No `claude` command was found, and the on-device model is unavailable"
        }
        return "Write a commit message from the staged diff (⇧⌘G)"
    }

    private var commitHelp: String {
        if repo.status.staged.isEmpty { return "Tick a file first" }
        if repo.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write a commit message first"
        }
        return "Commit \(repo.status.staged.count) staged file(s) on \(repo.branchLabel)"
    }
}

// MARK: - Table

private struct ChangeTable: View {
    let repo: RepoViewModel
    let workspace: WorkspaceModel

    private var changes: [FileChange] { repo.displayedChanges }

    private var stagedCount: Int { repo.status.staged.count }

    private var fileSummary: String {
        let total = repo.orderedChanges.count
        if total == 0 { return "No changes" }
        return total == 1 ? "1 changed file" : "\(total) changed files"
    }

    var body: some View {
        VStack(spacing: 0) {
            // A rule that says what the table holds, rather than one that names
            // its columns: "Status" over a 16pt badge and "Filename" over a
            // path are labels for two things nobody has ever needed labelled,
            // and the count is the thing actually worth knowing before you
            // scroll.
            ColumnHeader {
                Text(fileSummary)
                Spacer()
                if stagedCount > 0 {
                    Text("\(stagedCount) staged")
                        .foregroundStyle(.tint)
                        .contentTransition(.numericText())
                }
            }

            if changes.isEmpty {
                ContentUnavailableView(
                    "Nothing to commit",
                    systemImage: "checkmark.seal",
                    description: Text("The working copy is clean.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    ChangeRow(
                        change: change,
                        staged: !change.isUnstaged,
                        stageState: StageState(change),
                        onToggleStage: { repo.toggleStage(change) },
                        // Only what is still in the working tree can be thrown
                        // away; a staged file's escape hatch is the checkbox.
                        onDiscard: change.isUnstaged ? { repo.requestDiscard([change]) } : nil,
                        isSelected: repo.selectedChange?.change.pathBytes == change.pathBytes,
                        onSelect: { workspace.select(change, in: repo) },
                        showsSeparator: index < changes.count - 1
                    )
                }

                if repo.hasMoreThanDisplayed {
                    OverflowRow(hidden: repo.hiddenRowCount)
                }
            }
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
    }
}

// MARK: - In-progress banner

/// A merge, rebase, cherry-pick or revert that has stopped half way.
///
/// This used to be three controls living permanently in the repository's action
/// bar, visible in the 99% of the time no merge was running. It is an
/// exceptional state, so it gets an exceptional row — and nothing at all
/// otherwise.
struct InProgressBanner: View {
    let repo: RepoViewModel

    var body: some View {
        if let operation = repo.status.inProgress {
            HStack(spacing: Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(operation.label) in progress")
                    .font(Typography.secondaryDetail.weight(.medium))

                Spacer(minLength: Space.md)

                Button("Abort") { repo.abortInProgress() }
                    .controlSize(.small)
                    .disabled(repo.isBusy)

                Button("Continue") { repo.continueMerge() }
                    .controlSize(.small)
                    .disabled(!repo.canContinueMerge)
                    .help("Commit the \(operation.label.lowercased()) with git's own message")
            }
            .foregroundStyle(Palette.attention.color)
            .padding(.horizontal, Space.lg)
            .frame(height: Metrics.paneHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.attention.color.opacity(0.12))
            .hairline(.bottom)
        }
    }
}
