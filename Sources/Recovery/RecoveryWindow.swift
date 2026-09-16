import SwiftUI

/// Where the safety net becomes reachable.
///
/// Every destructive operation snapshots the worktree and index into
/// `refs/grove/backup/` first — a real commit, GC-proof, and invisible to
/// `git branch` and `git stash list`. That invisibility is the point for the
/// repository and the problem for the user: until this window there was no way
/// to see one, let alone put it back.
///
/// A separate window rather than a sheet: it is opened *because* something went
/// wrong, which is exactly when being unable to look at the repository
/// underneath would be worst.
struct RecoveryWindow: View {
    let model: AppModel

    @State private var selectedRepoID: RepoID?

    private var repos: [RepoViewModel] { model.workspace?.repos ?? [] }

    private var repo: RepoViewModel? {
        repos.first { $0.id == selectedRepoID } ?? repos.first
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()

            if let repo {
                HSplitView {
                    snapshots(repo)
                        .frame(minWidth: 360)
                    OperationLogList(log: model.workspace?.operationLog)
                        .frame(minWidth: 300)
                }
            } else {
                ContentUnavailableView(
                    "No Workspace",
                    systemImage: "folder.badge.plus",
                    description: Text("Open a workspace to see what Grove has saved.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 420)
        .task(id: repo?.id) { await repo?.reloadBackups() }
    }

    private var picker: some View {
        HStack(spacing: Space.md) {
            Picker("Repository", selection: $selectedRepoID) {
                ForEach(repos) { candidate in
                    Text(candidate.name).tag(Optional(candidate.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(repos.count < 2)

            Spacer(minLength: Space.md)

            if let repo {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await repo.reloadBackups() }
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.bar)
        .background(.bar)
    }

    // MARK: Snapshots

    private func snapshots(_ repo: RepoViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabelRow(
                title: "Snapshots", count: repo.backups.count, shown: repo.backups.count
            )
            .padding(.horizontal, Space.lg)
            .background(.bar)

            if repo.backups.isEmpty {
                ContentUnavailableView(
                    "Nothing to recover",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "Grove takes a snapshot before anything that can lose work.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(repo.backups) { backup in
                            SnapshotRow(
                                backup: backup,
                                isBusy: repo.isBusy,
                                onRestore: { repo.restore(backup) },
                                onForget: { repo.forget(backup) }
                            )
                            .padding(.horizontal, Space.lg)
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
            }
        }
    }
}

private struct SnapshotRow: View {
    let backup: BackupRef
    let isBusy: Bool
    let onRestore: () -> Void
    let onForget: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.xs) {
                    Text("Before \(backup.reason)")
                        .font(Typography.fileName)
                    if let date = backup.date {
                        Text(date, format: .dateTime.day().month().hour().minute())
                            .font(Typography.secondaryDetail.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                // Shown verbatim, and selectable. A recovery path the user
                // cannot run themselves is one they have to take on trust.
                Text(backup.recoveryCommand)
                    .font(Typography.keyHint)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Space.sm)

            if isHovered {
                Button("Restore", action: onRestore).disabled(isBusy)
                Button("Forget", role: .destructive, action: onForget).disabled(isBusy)
            }
        }
        .font(Typography.secondaryDetail)
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.xs)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .help(backup.refName)
    }
}

// MARK: - Log

private struct OperationLogList: View {
    let log: OperationLog?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                GroupLabelRow(
                    title: "This session",
                    count: log?.entries.count ?? 0,
                    shown: log?.entries.count ?? 0
                )
                Spacer(minLength: 0)
                if let log, !log.entries.isEmpty {
                    Button("Clear") { log.clear() }
                        .buttonStyle(.plain)
                        .font(Typography.secondaryDetail)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, Space.lg)
            .background(.bar)

            if let log, !log.entries.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.entries) { entry in
                            row(entry)
                                .padding(.horizontal, Space.lg)
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
            } else {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "list.bullet",
                    description: Text("Everything Grove does this session is listed here.")
                )
            }
        }
    }

    private func row(_ entry: OperationLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            icon(entry)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.summary)
                    .font(Typography.secondaryDetail)
                    .lineLimit(1)
                if case .failed(let reason) = entry.outcome {
                    Text(reason)
                        .font(Typography.secondaryDetail)
                        .foregroundStyle(Palette.attention.color)
                        .lineLimit(2)
                }
                if let ref = entry.backupRef {
                    Text("git stash apply \(ref)")
                        .font(Typography.keyHint)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: Space.xs)

            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(Typography.keyHint)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Space.xxs)
        .help(entry.repoName)
    }

    @ViewBuilder
    private func icon(_ entry: OperationLog.Entry) -> some View {
        switch entry.outcome {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: entry.isDestructive ? "exclamationmark.shield" : "checkmark")
                .font(.caption2)
                .foregroundStyle(entry.isDestructive ? Palette.attention.color : .secondary)
        case .failed:
            Image(systemName: "xmark.octagon")
                .font(.caption2)
                .foregroundStyle(Palette.removed.color)
        }
    }
}
