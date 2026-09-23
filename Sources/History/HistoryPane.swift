import AppKit
import DiffCore
import SwiftUI

/// The History section: the commit graph.
///
/// Just the graph now. The files of the selected commit used to live in a drawer
/// clamped to 280pt under this list, which meant a commit's file list and its
/// diff were in two different columns and neither had room. Both moved to the
/// detail column, where they are one changeset — see ``CommitChangesetPane``.
///
/// `ScrollView` + `LazyVStack`, like the Overview and Branches: rows arrive a
/// page at a time and the count changes after the view is on screen, which is
/// the thing an `NSTableView` objects to.
struct HistoryPane: View {
    let repo: RepoViewModel

    var body: some View {
        commitList
            // Reloaded when HEAD moves: a commit, a merge or a branch switch all
            // change what the top of this list is.
            .task(id: repo.status.headOID) { await repo.reloadHistory() }
    }

    private var commitList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(repo.commits.enumerated()), id: \.element.id) { index, commit in
                    if let month = monthLabel(at: index) {
                        MonthHeader(title: month)
                    }

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

    /// The month band to draw above row `index`, or `nil` when it belongs to the
    /// same month as the row before it.
    ///
    /// Computed against the previous row rather than by grouping the list, so a
    /// page arriving underneath does not re-bucket everything above it.
    ///
    /// The list is in **topological** order, not date order — that is what keeps
    /// a branch's commits together instead of interleaving them with whatever
    /// else was happening that week. So a month can legitimately appear more
    /// than once, and the band means "this run is from September" rather than
    /// "September starts here". That is the honest reading of a graph, and the
    /// alternative is sorting by date and drawing a graph nobody can follow.
    private func monthLabel(at index: Int) -> String? {
        guard let date = repo.commits[index].date else { return nil }
        guard index > 0 else { return Self.month.string(from: date) }

        guard let previous = repo.commits[index - 1].date else { return nil }
        let calendar = Calendar.current
        if calendar.isDate(date, equalTo: previous, toGranularity: .month) { return nil }

        return Self.month.string(from: date)
    }

    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        return formatter
    }()
}

// MARK: - Month band

/// The band between one month's commits and the next.
///
/// No fill and no rule, unlike every other band in Grove. Those are *structure*
/// — a header closing a pane, a column rule over a table — and this is a label
/// inside a list that is already ruled row by row. Filling it made the list read
/// as a stack of little tables.
///
/// Indented to the avatar column rather than to the pane's edge, so the rail
/// keeps a clear gutter all the way down and the label lines up with the names
/// it is grouping.
struct MonthHeader: View {
    let title: String

    var body: some View {
        Text(title.localizedUppercase)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, Space.md + CommitRail.gutterWidth + Space.md)
            .padding(.trailing, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row

/// One commit, on two lines.
///
/// Line one is the identity — who, which refs, when. Line two is the content —
/// the id and what they said. Splitting them is what lets each have a column
/// instead of a share of one line: the subject now gets the whole width it needs
/// and truncates last, where before it was the first thing squeezed out by a
/// long author name.
struct CommitRow: View {
    let commit: CommitInfo
    let row: CommitGraphRow?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            CommitRail(
                row: row, isHead: commit.isHead, isMerge: commit.isMerge, isSelected: isSelected)

            Avatar(name: commit.authorName, email: commit.authorEmail, size: 26)

            VStack(alignment: .leading, spacing: 3) {
                identityLine
                subjectLine
            }
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.lg)
        .frame(height: Metrics.commitRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The accent colour, filled and full bleed — not `.selection`, which
        // renders as a pale grey the moment the column loses focus and left the
        // selected commit indistinguishable from a hover. Which row you are
        // reading is the one thing this list must never be vague about.
        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        .hairline(.bottom, color: isSelected ? .clear : Palette.rowSeparator.color)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.oid, forType: .string)
            }
            Button("Copy Subject") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.subject, forType: .string)
            }
        }
        .help(helpText)
    }

    /// Who, which refs, and when.
    ///
    /// The priorities are the layout. The date is fixed and never yields; the
    /// name comes next and truncates to `Uzun isi…` only once there is genuinely
    /// no room; the badges are last and collapse into a `⋯` long before either.
    /// Before this, a commit with five refs pushed the author's name out of the
    /// row entirely — the badges were unbreakable and the name was not.
    private var identityLine: some View {
        HStack(spacing: Space.xs) {
            Text(commit.authorName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .layoutPriority(1)

            RefBadgeStrip(refs: commit.refs, isSelected: isSelected)

            Spacer(minLength: Space.xs)

            if let date = commit.date {
                Text(date, format: .dateTime.day(.twoDigits).month(.twoDigits).year())
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary)
                    )
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
            }
        }
    }

    private var subjectLine: some View {
        HStack(spacing: Space.sm) {
            Text(commit.shortOID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary)
                )
                .fixedSize()
                .layoutPriority(1)

            Text(commit.subject)
                // The same size as the author's name above it. A larger subject
                // made the second line the loud one and the row read as a
                // heading with a caption over it, rather than as two facts about
                // one commit.
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    private var helpText: String {
        var lines = [commit.subject, "\(commit.authorName) <\(commit.authorEmail)>"]
        if let date = commit.date {
            lines.append(date.formatted(date: .long, time: .shortened))
        }
        lines.append(commit.oid)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Rail

/// The graph rail for one row: its own gutter, a continuous line, a ring per
/// commit.
///
/// It **is** coloured, which reverses the rule this drawing used to follow.
/// Monochrome was defended on the grounds that Grove spends colour on meaning
/// and a tinted rail would spend it on decoration — but drawn in greys at one
/// point it did not read as a line at all, just as flecks beside the avatars.
/// The blue is not decoration: it is what makes the list legible as a graph
/// rather than as a stack, and it is the accent colour, so it says the same
/// thing as every other structural blue in the window.
///
/// Rings rather than discs, and the line runs *through* them. A filled dot per
/// row turns the rail into a dotted line and buries the one thing it is drawn
/// to show — where a branch leaves and rejoins.
private struct CommitRail: View {
    let row: CommitGraphRow?
    let isHead: Bool
    let isMerge: Bool
    var isSelected = false

    private static let laneWidth: CGFloat = 14
    private static let dotRadius: CGFloat = 5

    /// How wide the rail is when there is only one lane, which is the usual
    /// case and the one the month band aligns against.
    static let gutterWidth: CGFloat = laneWidth + Space.lg

    private var laneCount: Int { max(row?.width ?? 1, 1) }

    /// The rail sits inside the row, so on a selected one it is drawing *on* the
    /// accent colour — where an accent-coloured line would vanish.
    private var line: Color { isSelected ? .white : .accentColor }

    /// The ring around each commit. Deliberately not the line's colour: the line
    /// is the branch and the ring is the commit, and giving them one colour made
    /// the rail read as a string of beads.
    private var ring: Color { isSelected ? .white : .secondary }

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
                    with: .color(line.opacity(link.touchesCommit ? 0.9 : 0.4)),
                    lineWidth: 2
                )
            }

            let centre = CGPoint(x: x(row.lane), y: height / 2)
            let radius = Self.dotRadius
            let dot = Path(
                ellipseIn: CGRect(
                    x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2))

            // Punched out of the line rather than laid over it, so the ring has
            // a clean inside however many lanes pass behind it. It has to be
            // the row's *own* background — on a selected row that is the accent
            // colour, and filling with the list's grey would leave a pale disc
            // sitting on the blue.
            context.fill(
                dot,
                with: .color(isSelected ? .accentColor : Palette.contentFill.color))

            // A merge is filled: it is a join rather than a change of its own,
            // and it is the exception worth spotting.
            if isMerge {
                let core = Path(
                    ellipseIn: CGRect(
                        x: centre.x - radius + 2, y: centre.y - radius + 2,
                        width: (radius - 2) * 2, height: (radius - 2) * 2))
                context.fill(core, with: .color(ring))
            }

            context.stroke(
                dot,
                with: .color(isHead && !isSelected ? .accentColor : ring),
                lineWidth: isHead ? 2.5 : 1.5
            )
        }
        .frame(width: CGFloat(laneCount) * Self.laneWidth + Space.lg)
        .accessibilityHidden(true)
    }

    private func x(_ lane: Int) -> CGFloat {
        Space.lg / 2 + (CGFloat(lane) + 0.5) * Self.laneWidth
    }
}
