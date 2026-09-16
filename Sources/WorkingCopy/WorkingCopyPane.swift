import SwiftUI

/// The Working Copy view: compose a commit above, review what goes into it below.
///
/// Follows Tower's arrangement — composer on top, file list beneath — rather
/// than VS Code's box-per-repository. The practical reason is that a `TextField`
/// inside a recycling `List` loses focus as rows scroll, and every keystroke
/// invalidates a row inside a virtualised container. Here the composer lives
/// outside the scrolling area entirely, so ⌘⏎ works no matter where the list is
/// scrolled to.
struct WorkingCopyPane: View {
    @Bindable var repo: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            CommitComposer(repo: repo)
            Divider()
            ChangeList(repo: repo)
        }
        .confirmationDialog(
            discardTitle,
            isPresented: discardPresented,
            titleVisibility: .visible,
            presenting: repo.pendingDiscard
        ) { pending in
            Button("Discard \(pending.changes.count) file(s)", role: .destructive) {
                repo.confirmPendingDiscard()
            }
            Button("Cancel", role: .cancel) { repo.cancelPendingDiscard() }
        } message: { pending in
            Text(discardMessage(for: pending))
        }
        .alert(
            "Changes discarded",
            isPresented: receiptPresented,
            presenting: repo.lastDiscard
        ) { _ in
            Button("OK") { repo.lastDiscard = nil }
        } message: { receipt in
            Text(receiptMessage(for: receipt.outcome))
        }
        .alert(
            "Operation failed",
            isPresented: errorPresented,
            presenting: repo.operationError
        ) { _ in
            Button("OK") { repo.operationError = nil }
        } message: { error in
            Text(message(for: error))
        }
    }

    // MARK: Confirmation wording

    private var discardTitle: String {
        guard let pending = repo.pendingDiscard else { return "Discard changes?" }
        return pending.changes.count == 1
            ? "Discard changes to \(pending.changes[0].singleLineFileName)?"
            : "Discard changes to \(pending.changes.count) files?"
    }

    /// Spells out exactly what happens and how to get it back. A confirmation
    /// that does not say where the work goes is just a speed bump.
    private func discardMessage(for pending: RepoViewModel.PendingDiscard) -> String {
        var lines: [String] = []
        if pending.trackedCount > 0 {
            lines.append(
                """
                \(pending.trackedCount) tracked file(s) will be restored. Grove saves a \
                snapshot first, so this can be undone.
                """)
        }
        if pending.untrackedCount > 0 {
            lines.append(
                """
                \(pending.untrackedCount) untracked file(s) will be moved to the Trash, \
                where you can recover them from Finder.
                """)
        }
        let names = pending.changes.prefix(8).map(\.singleLineDisplayPath).joined(separator: "\n")
        lines.append(names)
        if pending.changes.count > 8 {
            lines.append("…and \(pending.changes.count - 8) more")
        }
        return lines.joined(separator: "\n\n")
    }

    private func receiptMessage(for outcome: RepoEngine.DiscardOutcome) -> String {
        var lines: [String] = []
        if !outcome.restoredPaths.isEmpty {
            lines.append("\(outcome.restoredPaths.count) file(s) restored.")
        }
        if !outcome.trashedPaths.isEmpty {
            lines.append("\(outcome.trashedPaths.count) file(s) moved to the Trash.")
        }
        if let ref = outcome.backupRef {
            lines.append("Recover everything with:\ngit stash apply \(ref)")
        }
        if !outcome.failures.isEmpty {
            lines.append(
                "Could not remove: " + outcome.failures.map(\.path).joined(separator: ", "))
        }
        return lines.joined(separator: "\n\n")
    }

    private func message(for error: GitError) -> String {
        switch error {
        case .commandFailed(let command, _, let stderr):
            stderr.isEmpty ? command : stderr
        default:
            repo.errorMessage ?? "\(error)"
        }
    }

    // MARK: Presentation bindings

    private var discardPresented: Binding<Bool> {
        Binding(
            get: { repo.pendingDiscard != nil }, set: { if !$0 { repo.cancelPendingDiscard() } })
    }

    private var receiptPresented: Binding<Bool> {
        Binding(get: { repo.lastDiscard != nil }, set: { if !$0 { repo.lastDiscard = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { repo.operationError != nil }, set: { if !$0 { repo.operationError = nil } })
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
            .padding(Space.md)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Radius.md))

            HStack(spacing: Space.md) {
                Button("Stage All") { repo.stageAll() }
                    .disabled(repo.status.unstaged.isEmpty && repo.status.untracked.isEmpty)
                    .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Unstage All") { repo.unstageAll() }
                    .disabled(repo.status.staged.isEmpty)

                Spacer()

                if repo.isBusy {
                    ProgressView().controlSize(.small)
                }

                Button {
                    repo.commit()
                } label: {
                    Label("Commit", systemImage: "checkmark")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!repo.canCommit)
                .help(commitHelp)
            }
        }
        .padding(Space.lg)
    }

    private var commitHelp: String {
        if repo.status.staged.isEmpty { return "Stage something first" }
        if repo.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write a commit message first"
        }
        return "Commit \(repo.status.staged.count) staged file(s) on \(repo.branchLabel)"
    }
}

// MARK: - Change list

private struct ChangeList: View {
    let repo: RepoViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                group(
                    "Conflicts", repo.displayedConflicted,
                    total: repo.status.conflicted.count, staged: false)
                group(
                    "Staged", repo.displayedStaged,
                    total: repo.status.staged.count, staged: true)
                group(
                    "Changes", repo.displayedUnstaged,
                    total: repo.status.unstaged.count + repo.status.untracked.count,
                    staged: false)

                if repo.hasMoreThanDisplayed {
                    OverflowRow(hidden: repo.hiddenRowCount)
                        .padding(.horizontal, Space.lg)
                }

                if repo.status.changes.isEmpty {
                    ContentUnavailableView(
                        "Nothing to commit",
                        systemImage: "checkmark.seal",
                        description: Text("The working copy is clean.")
                    )
                    .padding(.top, Space.xxxl)
                }
            }
            .padding(.bottom, Space.xl)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
    }

    @ViewBuilder
    private func group(
        _ title: String, _ changes: [FileChange], total: Int, staged: Bool
    ) -> some View {
        if !changes.isEmpty {
            Section {
                ForEach(changes.map { ChangeRowItem(change: $0, staged: staged) }) { item in
                    let change = item.change
                    ChangeRow(
                        change: change,
                        staged: staged,
                        onStage: { staged ? repo.unstage([change]) : repo.stage([change]) },
                        // Staged rows offer no discard: unstaging is the
                        // reversible step, and discarding from here would throw
                        // away work in one click.
                        onDiscard: staged ? nil : { repo.requestDiscard([change]) },
                        isSelected: repo.selectedChange
                            == SelectedChange(change: change, staged: staged),
                        onSelect: {
                            repo.selectedChange = SelectedChange(
                                change: change, staged: staged)
                        }
                    )
                    .padding(.horizontal, Space.lg)
                }
            } header: {
                GroupLabelRow(title: title, count: total, shown: changes.count)
                    .padding(.horizontal, Space.lg)
                    .background(.bar)
            }
        }
    }
}
