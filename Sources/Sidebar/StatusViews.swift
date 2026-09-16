import SwiftUI

/// The branch name next to a repository.
struct BranchPill: View {
    let label: String
    var isDetached = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isDetached ? "arrow.triangle.branch.circle" : "arrow.triangle.branch")
                .font(.system(size: 9))
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                // Truncating in the middle keeps both ends readable, which is
                // what matters for names like `feature/…/fix-login`.
                .truncationMode(.middle)
        }
        .foregroundStyle(isDetached ? Palette.attention.color : Color.secondary)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 1)
        .background(.quaternary, in: .capsule)
        .frame(maxWidth: 130, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Ahead/behind arrows.
///
/// Renders only the non-zero half, and nothing at all when in sync — "↑0 ↓0" is
/// noise. Diverged (both non-zero) is the state that actually needs attention,
/// so it gets its own colour.
struct AheadBehindBadge: View {
    let ahead: Int
    let behind: Int

    private var hasDiverged: Bool { ahead > 0 && behind > 0 }

    var body: some View {
        if ahead > 0 || behind > 0 {
            HStack(spacing: 2) {
                if ahead > 0 {
                    Label("\(ahead)", systemImage: "arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                if behind > 0 {
                    Label("\(behind)", systemImage: "arrow.down")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(hasDiverged ? Palette.attention.color : Color.secondary)
            .help(helpText)
        }
    }

    private var helpText: String {
        if hasDiverged { return "Diverged: \(ahead) ahead, \(behind) behind" }
        if ahead > 0 { return "\(ahead) to push" }
        return "\(behind) to pull"
    }
}

/// A non-selectable "Staged" / "Changes" divider inside a repository section.
///
/// `List` does not support nested sections, so the staged/unstaged split is an
/// inline label row rather than a real subsection.
struct GroupLabelRow: View {
    let title: String
    /// The real number of changes in this group.
    let count: Int
    /// How many are actually rendered, when the display cap is in effect.
    var shown: Int?

    private var isTruncated: Bool { shown.map { $0 < count } ?? false }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(isTruncated ? "\(shown ?? 0) of \(count)" : "\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: Metrics.groupLabelRow)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

/// The row shown when a repository has more changes than the list will render.
///
/// Explicit rather than silent: a truncated list that says nothing is worse than
/// a slow one, because the user has no way to know something is missing.
struct OverflowRow: View {
    let hidden: Int

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
            Text("\(hidden) more not shown")
                .font(Typography.secondaryDetail.monospacedDigit())
            Spacer()
        }
        .foregroundStyle(.secondary)
        .frame(height: Metrics.fileRow)
        .help("Grove renders at most \(RepoViewModel.displayRowCap) rows per group.")
    }
}

/// A change as it appears in one particular group.
///
/// A file that is staged *and* modified again appears in two groups at once, so
/// the change's own id is not unique within the list. Two sibling `ForEach`es
/// sharing an id makes SwiftUI treat them as the same element and drop one — it
/// renders as a blank row. Qualifying the id with the group fixes it.
struct ChangeRowItem: Identifiable {
    let change: FileChange
    let staged: Bool
    var id: String { (staged ? "staged:" : "unstaged:") + change.displayPath }
}

/// One changed file.
struct ChangeRow: View {
    let change: FileChange
    let staged: Bool
    var onStage: (() -> Void)?
    var onDiscard: (() -> Void)?

    /// Hover state is **local to the row** on purpose. Hoisting it into a
    /// list-level `hoveredID` invalidates every row on every mouse move, which
    /// is the most common way a SwiftUI sidebar becomes laggy.
    @State private var isHovered = false

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Width shared by the status letter and the hover buttons.
    ///
    /// Reserved up front so revealing the buttons swaps content in a fixed slot
    /// rather than resizing the row — otherwise the filename shifts under the
    /// cursor as you move down the list.
    private var trailingSlotWidth: CGFloat { hasActions ? 46 : 14 }

    private var hasActions: Bool { onStage != nil || onDiscard != nil }

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(change.singleLineFileName)
                .font(Typography.fileName)
                .lineLimit(1)

            if !change.directoryPrefix.isEmpty {
                Text(FileChange.sanitizeForSingleLine(change.directoryPrefix))
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Head truncation keeps the useful half — `…/Features/Auth`.
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }

            Spacer(minLength: Space.xs)

            // Status is encoded redundantly — letter, colour, and (in the diff)
            // the +/- sign — so it survives both colour blindness and the
            // Differentiate Without Color setting.
            if differentiateWithoutColor {
                Rectangle()
                    .fill(change.tint(staged: staged))
                    .frame(width: 2, height: 12)
            }

            trailingSlot
        }
        .frame(height: Metrics.fileRow)
        .contentShape(.rect)
        .opacity(change.worktreeStatus == .deleted && !staged ? 0.6 : 1)
        .onHover { isHovered = $0 }
        .help(change.singleLineDisplayPath)
    }

    @ViewBuilder
    private var trailingSlot: some View {
        ZStack(alignment: .trailing) {
            Text(change.statusLetter(staged: staged))
                .font(Typography.statusLetter)
                .foregroundStyle(change.tint(staged: staged))
                .opacity(showActions ? 0 : 1)

            if showActions {
                HStack(spacing: Space.xs) {
                    if let onDiscard {
                        RowActionButton(
                            symbol: "arrow.uturn.backward",
                            help: "Discard changes",
                            action: onDiscard
                        )
                    }
                    if let onStage {
                        RowActionButton(
                            symbol: staged ? "minus" : "plus",
                            help: staged ? "Unstage" : "Stage",
                            action: onStage
                        )
                    }
                }
            }
        }
        // Opacity only — never position. The slot keeps its width either way.
        .animation(.easeOut(duration: 0.12), value: showActions)
        .frame(width: trailingSlotWidth, alignment: .trailing)
    }

    private var showActions: Bool { isHovered && hasActions }
}

private struct RowActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
