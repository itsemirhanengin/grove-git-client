import SwiftUI

/// A ref pointing at a commit: `HEAD`, `main`, `v0.2.0`, `origin/main`.
///
/// Filled rather than outlined, and rounded — the one place in Grove that
/// rounds anything, together with the sidebar's selection. A badge is not a
/// surface: it is a token sitting *on* a row, and the whole reason four of them
/// in a line stay readable is that each is a shape rather than a word with a box
/// around it.
///
/// The colour carries the kind, which is why ``CommitInfo/refs`` classifies from
/// the full ref path instead of guessing from the name.
struct RefBadge: View {
    let ref: CommitRef
    var isSelected = false

    var body: some View {
        Text(ref.name)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(foreground)
            .background(fill, in: .rect(cornerRadius: Radius.xs))
            .help(help)
    }

    /// On a selected row every badge sits on the accent colour, where a blue
    /// `HEAD` would disappear into its own background. The two strong kinds keep
    /// their fill — gold and blue both still read against it — and the two quiet
    /// ones borrow the row's white instead of the window's grey.
    private var fill: some ShapeStyle {
        switch ref.kind {
        case .head: AnyShapeStyle(Palette.modified.color)
        case .tag: AnyShapeStyle(Palette.tag.color)
        case .branch:
            AnyShapeStyle(isSelected ? Color.white.opacity(0.28) : Color.secondary.opacity(0.28))
        case .remote:
            AnyShapeStyle(isSelected ? Color.white.opacity(0.16) : Color.secondary.opacity(0.16))
        }
    }

    private var foreground: some ShapeStyle {
        switch ref.kind {
        // `diffCanvas` is white in the light scheme and near-black in the dark
        // one, and both fills are the opposite way round — so one rule gives a
        // legible chip in either, without a second set of colours.
        case .head, .tag: AnyShapeStyle(Palette.diffCanvas.color)
        case .branch: AnyShapeStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        case .remote:
            AnyShapeStyle(
                isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
    }

    private var help: String {
        switch ref.kind {
        case .head: "HEAD is here"
        case .branch: "Branch \(ref.name)"
        case .tag: "Tag \(ref.name)"
        case .remote: "Remote branch \(ref.name)"
        }
    }
}

/// The badges on one row, collapsing from the right as the column narrows.
///
/// A commit can carry five refs and the column can be 340pt wide; something has
/// to give, and it must not be the author's name. So the badges are the thing
/// that yields: they drop one at a time into a single `⋯`, which keeps the fact
/// that *something* is here while giving the width back.
///
/// `ViewThatFits` rather than a measured layout: the candidates are laid out at
/// their ideal width and the first that fits wins, which is exactly the rule
/// wanted and needs no width plumbed through the row. The candidates have to be
/// written out — `ViewThatFits` reads its direct children, so a `ForEach` inside
/// it would count as one.
struct RefBadgeStrip: View {
    let refs: [CommitRef]
    var isSelected = false

    /// Never more than this many at once, however wide the column gets. Past
    /// four the row stops being a commit and starts being a legend.
    private static let cap = 4

    var body: some View {
        if !refs.isEmpty {
            ViewThatFits(in: .horizontal) {
                candidate(Self.cap)
                candidate(3)
                candidate(2)
                candidate(1)
                candidate(0)
            }
        }
    }

    private func candidate(_ count: Int) -> some View {
        let shown = min(count, refs.count)
        let hidden = Array(refs.dropFirst(shown))

        return HStack(spacing: 3) {
            ForEach(refs.prefix(shown)) { ref in
                RefBadge(ref: ref, isSelected: isSelected)
            }
            if !hidden.isEmpty {
                OverflowBadge(hidden: hidden, isSelected: isSelected)
            }
        }
        // Or the candidate reports a compressible width and the widest one
        // always "fits", which defeats the whole arrangement.
        .fixedSize()
    }
}

/// What is left when the badges do not fit.
private struct OverflowBadge: View {
    let hidden: [CommitRef]
    var isSelected = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4)
            .frame(height: 13)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(
                isSelected ? Color.white.opacity(0.28) : Color.secondary.opacity(0.28),
                in: .rect(cornerRadius: Radius.xs)
            )
            .help(hidden.map(\.name).joined(separator: "\n"))
            .accessibilityLabel("\(hidden.count) more refs")
    }
}

#if DEBUG
#Preview("Badges") {
    let refs = [
        CommitRef(kind: .head, name: "HEAD"),
        CommitRef(kind: .branch, name: "main"),
        CommitRef(kind: .tag, name: "v0.2.0"),
        CommitRef(kind: .remote, name: "origin/main"),
        CommitRef(kind: .remote, name: "origin/HEAD"),
    ]

    return VStack(alignment: .leading, spacing: Space.md) {
        ForEach([420.0, 300.0, 220.0, 140.0, 90.0], id: \.self) { width in
            HStack(spacing: Space.xs) {
                Text("Emirhan Engin").font(.caption.weight(.medium)).layoutPriority(1)
                RefBadgeStrip(refs: refs)
                Spacer(minLength: Space.xs)
            }
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 2)
            .background(Palette.contentFill.color)
        }
    }
    .padding()
}
#endif
