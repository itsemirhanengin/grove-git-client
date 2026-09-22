import DiffCore
import SwiftUI

/// The History section: the commit graph, and the files of whichever commit is
/// selected.
///
/// `ScrollView` + `LazyVStack`, like the Overview and Branches: rows arrive a
/// page at a time and the count changes after the view is on screen, which is
/// the thing an `NSTableView` objects to.
struct HistoryPane: View {
    let repo: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            commitList

            if repo.selectedCommit != nil {
                CommitDetail(repo: repo)
                    .frame(maxHeight: 280)
            }
        }
        // Reloaded when HEAD moves: a commit, a merge or a branch switch all
        // change what the top of this list is.
        .task(id: repo.status.headOID) { await repo.reloadHistory() }
    }

    private var commitList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(repo.commits.enumerated()), id: \.element.id) { index, commit in
                    CommitRow(
                        commit: commit,
                        row: index < repo.graphRows.count ? repo.graphRows[index] : nil,
                        isSelected: repo.selectedCommit?.oid == commit.oid,
                        onSelect: { Task { await repo.selectCommit(commit) } }
                    )
                    .onAppear {
                        // Paging off the last row rather than a scroll offset:
                        // an offset has to be measured against a content height
                        // that is still changing while rows are being built.
                        if index == repo.commits.count - 1 {
                            Task { await repo.loadMoreHistory() }
                        }
                    }
                }

                if repo.isLoadingHistory {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(Space.lg)
                } else if repo.commits.isEmpty {
                    ContentUnavailableView(
                        "No commits",
                        systemImage: "clock",
                        description: Text("This repository has no history yet.")
                    )
                    .padding(.top, Space.xxxl)
                }
            }
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
    }
}

// MARK: - Row

private struct CommitRow: View {
    let commit: CommitInfo
    let row: CommitGraphRow?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            CommitRail(row: row, isHead: commit.isHead, isMerge: commit.isMerge)

            Text(commit.subject)
                .font(Typography.fileName)
                .lineLimit(1)
                .truncationMode(.tail)

            ForEach(commit.displayRefNames, id: \.self) { name in
                BranchPill(label: name, isDetached: false)
            }

            Spacer(minLength: Space.sm)

            Text(commit.authorName)
                .font(Typography.secondaryDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)

            if let date = commit.date {
                Text(date, format: .relative(presentation: .numeric))
                    .font(Typography.secondaryDetail.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(commit.shortOID)
                .font(Typography.keyHint)
                .foregroundStyle(.tertiary)
        }
        .padding(.trailing, Space.lg)
        .frame(height: Metrics.fileRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .hairline(.bottom, color: Palette.rowSeparator.color)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .help(commit.oid)
    }
}

/// The graph rail for one row.
///
/// Deliberately monochrome. Grove's palette gives colour a meaning — red is
/// removed and destructive, amber is a warning, blue is modified — and a rail
/// that tints lanes for decoration would spend all of it at once. Position
/// carries the branch; weight carries whether a line concerns this commit.
private struct CommitRail: View {
    let row: CommitGraphRow?
    let isHead: Bool
    let isMerge: Bool

    private static let laneWidth: CGFloat = 12
    private static let dotRadius: CGFloat = 3.5

    private var laneCount: Int { max(row?.width ?? 1, 1) }

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let height = size.height

            for link in row.links {
                var path = Path()
                let start = CGPoint(x: x(link.from), y: 0)
                let end = CGPoint(x: x(link.to), y: height)
                path.move(to: start)
                if link.from == link.to {
                    path.addLine(to: end)
                } else {
                    // A gentle S rather than a diagonal, so a branch reads as
                    // leaving its lane rather than as a stray line across rows.
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: height * 0.5),
                        control2: CGPoint(x: end.x, y: height * 0.5)
                    )
                }
                context.stroke(
                    path,
                    with: .color(.secondary.opacity(link.touchesCommit ? 0.75 : 0.3)),
                    lineWidth: link.touchesCommit ? 1.4 : 1
                )
            }

            let centre = CGPoint(x: x(row.lane), y: height / 2)
            let dot = Path(
                ellipseIn: CGRect(
                    x: centre.x - Self.dotRadius, y: centre.y - Self.dotRadius,
                    width: Self.dotRadius * 2, height: Self.dotRadius * 2))

            // A merge is drawn hollow: it is a join, not a change of its own.
            if isMerge {
                context.fill(dot, with: .color(Palette.diffCanvas.color))
                context.stroke(dot, with: .color(isHead ? .accentColor : .primary), lineWidth: 1.5)
            } else {
                context.fill(dot, with: .color(isHead ? .accentColor : .primary))
            }
        }
        .frame(width: CGFloat(laneCount) * Self.laneWidth + Space.md)
        .accessibilityHidden(true)
    }

    private func x(_ lane: Int) -> CGFloat {
        Space.md / 2 + (CGFloat(lane) + 0.5) * Self.laneWidth
    }
}

// MARK: - Detail

/// The selected commit: its message, and what it touched.
private struct CommitDetail: View {
    let repo: RepoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let commit = repo.selectedCommit {
                header(commit)
                fileList
            }
        }
    }

    private func header(_ commit: CommitInfo) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(repo.selectedCommitMessage.isEmpty ? commit.subject : repo.selectedCommitMessage)
                .font(Typography.fileName)
                .textSelection(.enabled)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.sm) {
                Text(commit.authorName)
                Text(commit.authorEmail)
                    .foregroundStyle(.tertiary)
                if let date = commit.date {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                }
                Spacer(minLength: Space.sm)
                Text(commit.shortOID)
                    .font(Typography.keyHint)
                    .textSelection(.enabled)
            }
            .font(Typography.secondaryDetail)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.headerFill.color)
        .hairline(.bottom)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if repo.selectedCommitChanges.isEmpty {
                    Text(
                        repo.selectedCommit?.isMerge == true
                            ? "No changes against the first parent" : "No files"
                    )
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.lg)
                    .frame(height: Metrics.fileRow)
                } else {
                    ForEach(repo.selectedCommitChanges) { change in
                        ChangeRow(
                            change: change,
                            staged: true,
                            isSelected: repo.selectedCommitChange?.pathBytes == change.pathBytes,
                            onSelect: { repo.selectedCommitChange = change }
                        )
                    }
                }
            }
            .padding(.bottom, Space.md)
        }
    }
}
