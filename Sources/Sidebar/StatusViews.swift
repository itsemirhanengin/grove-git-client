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
        .foregroundStyle(isDetached ? .orange : .secondary)
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
            .foregroundStyle(hasDiverged ? .orange : .secondary)
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
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: Metrics.groupLabelRow)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

/// One changed file.
struct ChangeRow: View {
    let change: FileChange
    let staged: Bool

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

            Text(statusLetter)
                .font(Typography.statusLetter)
                .foregroundStyle(statusColor)
                .frame(width: 14, alignment: .trailing)
        }
        .frame(height: Metrics.fileRow)
        .opacity(change.worktreeStatus == .deleted && !staged ? 0.6 : 1)
        .help(change.singleLineDisplayPath)
    }

    private var statusLetter: String {
        if change.isConflicted { return "U" }
        if change.kind == .untracked { return "?" }
        let code = staged ? change.indexStatus : change.worktreeStatus
        return code.letter
    }

    /// Modified is blue and conflict is amber on purpose. Using yellow for both,
    /// as some clients do, makes a conflict indistinguishable from an ordinary
    /// edit — and red stays reserved for deletions and destructive actions.
    private var statusColor: Color {
        if change.isConflicted { return .orange }
        switch statusLetter {
        case "A": return .green
        case "D": return .red
        case "R", "C": return .purple
        case "?": return .teal
        default: return .blue
        }
    }
}
