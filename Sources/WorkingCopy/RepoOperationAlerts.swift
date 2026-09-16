import SwiftUI

/// The confirmation, the receipt and the failure for a repository's mutations.
///
/// Applied **once**, on the window's root, rather than inside a pane. A discard
/// can now be asked for from two places — the file list and the diff — and only
/// one of those is guaranteed to be on screen at a time. Attaching the sheet to
/// a pane meant a discard started from the other one waited for a dialog that
/// was never mounted.
struct RepoOperationAlerts: ViewModifier {
    let repo: RepoViewModel?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                discardTitle,
                isPresented: discardPresented,
                titleVisibility: .visible,
                presenting: repo?.pendingDiscard
            ) { pending in
                Button(confirmTitle(for: pending), role: .destructive) {
                    repo?.confirmPendingDiscard()
                }
                Button("Cancel", role: .cancel) { repo?.cancelPendingDiscard() }
            } message: { pending in
                Text(discardMessage(for: pending))
            }
            .alert(
                "Changes discarded",
                isPresented: receiptPresented,
                presenting: repo?.lastDiscard
            ) { _ in
                Button("OK") { repo?.lastDiscard = nil }
            } message: { receipt in
                Text(receiptMessage(for: receipt.outcome))
            }
            .alert(
                "Operation failed",
                isPresented: errorPresented,
                presenting: repo?.operationError
            ) { _ in
                Button("OK") { repo?.operationError = nil }
            } message: { error in
                Text(message(for: error))
            }
    }

    // MARK: Confirmation wording

    private var discardTitle: String {
        guard let pending = repo?.pendingDiscard else { return "Discard changes?" }
        let name = pending.changes.first?.singleLineFileName ?? "this file"

        if pending.partial != nil {
            let lines = pending.lineCount == 1 ? "1 line" : "\(pending.lineCount) lines"
            return "Discard \(lines) in \(name)?"
        }
        return pending.changes.count == 1
            ? "Discard changes to \(name)?"
            : "Discard changes to \(pending.changes.count) files?"
    }

    private func confirmTitle(for pending: RepoViewModel.PendingDiscard) -> String {
        if pending.partial != nil {
            return pending.lineCount == 1 ? "Discard 1 line" : "Discard \(pending.lineCount) lines"
        }
        return "Discard \(pending.changes.count) file(s)"
    }

    /// Spells out exactly what happens and how to get it back. A confirmation
    /// that does not say where the work goes is just a speed bump.
    private func discardMessage(for pending: RepoViewModel.PendingDiscard) -> String {
        var lines: [String] = []

        if pending.partial != nil {
            lines.append(
                """
                Those lines will be removed from the working copy. Grove saves a \
                snapshot of everything first, so this can be undone.
                """)
            lines.append(pending.changes.first?.singleLineDisplayPath ?? "")
            return lines.joined(separator: "\n\n")
        }

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
            RepoViewModel.message(for: error)
        }
    }

    // MARK: Presentation bindings

    private var discardPresented: Binding<Bool> {
        Binding(
            get: { repo?.pendingDiscard != nil }, set: { if !$0 { repo?.cancelPendingDiscard() } })
    }

    private var receiptPresented: Binding<Bool> {
        Binding(get: { repo?.lastDiscard != nil }, set: { if !$0 { repo?.lastDiscard = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { repo?.operationError != nil }, set: { if !$0 { repo?.operationError = nil } })
    }
}

extension View {
    /// See ``RepoOperationAlerts`` — apply this once, at the window root.
    func repoOperationAlerts(for repo: RepoViewModel?) -> some View {
        modifier(RepoOperationAlerts(repo: repo))
    }
}
