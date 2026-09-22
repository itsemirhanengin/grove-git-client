import AppKit
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
        .frame(maxWidth: 140, alignment: .leading)
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

/// A non-selectable label row inside a list.
///
/// Used where a list genuinely has two kinds of thing in it — local and remote
/// branches, the files inside a stash. The working copy no longer has one: its
/// staged/unstaged split is carried by the checkboxes, not by group headers.
struct GroupLabelRow: View {
    let title: String
    /// The real number of items in this group.
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
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.groupLabelRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.headerFill.color)
        .hairline(.bottom)
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
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.fileRow)
        .help("Grove renders at most \(RepoViewModel.displayRowCap) rows per repository.")
    }
}

// MARK: - Staging

/// The checkbox that stages a file.
///
/// Drawn from symbols rather than using `Toggle(…).toggleStyle(.checkbox)`,
/// because AppKit's checkbox has a mixed state and SwiftUI's `Toggle` has no way
/// to reach it — and mixed is precisely the state worth drawing.
struct StageCheckbox: View {
    let state: StageState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .symbolRenderingMode(state == .off ? .monochrome : .palette)
                .foregroundStyle(
                    state == .off ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white),
                    AnyShapeStyle(Color.accentColor)
                )
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stage")
        .accessibilityValue(accessibilityValue)
        .help(help)
    }

    private var symbol: String {
        switch state {
        case .off: "square"
        case .on: "checkmark.square.fill"
        case .partial: "minus.square.fill"
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .off: "Not staged"
        case .on: "Staged"
        case .partial: "Partly staged"
        }
    }

    private var help: String {
        switch state {
        case .off: "Stage this file"
        case .on: "Unstage this file"
        case .partial: "Staged, and edited again — stage the rest"
        }
    }
}

/// The status letter, as a filled chip.
///
/// A bare coloured letter was legible but weightless; the chip gives the status
/// column an edge to align against, which is what turns a list of file names
/// into a table you can scan down.
struct StatusBadge: View {
    let letter: String
    let tint: Color

    var body: some View {
        Text(letter)
            .font(Typography.statusLetter)
            .foregroundStyle(Palette.diffCanvas.color)
            .frame(width: 16, height: 15)
            .background(tint, in: .rect(cornerRadius: Radius.xs))
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// One changed file, as a table row.
///
/// Square, full-bleed and separated by a hairline rather than floated on a
/// rounded capsule: rows are the densest thing in the window and the eye needs
/// a straight edge to run down. The only interactive element is the checkbox —
/// everything else a file can have done to it is on the context menu, where a
/// destructive action cannot be hit by a stray hover.
struct ChangeRow: View {
    let change: FileChange
    let staged: Bool

    /// `nil` in read-only lists — a commit's files, a stash's files, the
    /// Overview. Those have nothing to stage.
    var stageState: StageState?
    var onToggleStage: (() -> Void)?
    var onDiscard: (() -> Void)?

    /// Whether this row's diff is the one on screen.
    var isSelected = false
    var onSelect: (() -> Void)?

    /// Drawn under every row but the last, which the list suppresses.
    var showsSeparator = true

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: Space.sm) {
            if let stageState {
                StageCheckbox(state: stageState) { onToggleStage?() }
            }

            StatusBadge(
                letter: change.statusLetter(staged: staged),
                tint: change.tint(staged: staged)
            )

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

            if differentiateWithoutColor {
                Text(change.statusLetter(staged: staged))
                    .font(Typography.keyHint)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.fileRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .hairline(.bottom, color: showsSeparator ? Palette.rowSeparator.color : .clear)
        .contentShape(.rect)
        .opacity(change.worktreeStatus == .deleted && !staged ? 0.6 : 1)
        .onTapGesture { onSelect?() }
        .contextMenu {
            if let onToggleStage, let stageState {
                Button(stageState == .on ? "Unstage" : "Stage", action: onToggleStage)
            }
            if let onDiscard {
                Button("Discard Changes…", role: .destructive, action: onDiscard)
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.singleLineDisplayPath, forType: .string)
            }
        }
        .help("\(change.singleLineDisplayPath)\n\(change.statusDescription)")
    }
}
