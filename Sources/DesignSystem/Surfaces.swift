import SwiftUI

/// The chrome primitives every pane is built from.
///
/// Grove's window is a grid, not a stack of floating cards. Three columns, one
/// header band across all of them, hairlines where surfaces meet. Getting that
/// to hold together needs exactly three shapes — a header, a column rule and a
/// status bar — and they live here so no pane can invent its own height,
/// padding or border and quietly break the alignment.
///
/// The rule the whole file exists to enforce: **a band is opaque, full-bleed
/// and closed by a hairline.** No corner radius, no inset, no material.

// MARK: - Hairlines

/// A one-device-pixel rule in Grove's border colour.
///
/// `Divider()` is deliberately not used for structural borders: it picks up the
/// enclosing stack's axis, inherits list insets, and resolves to
/// `separatorColor`, which is tuned for vibrancy and disappears against an
/// opaque header.
struct Hairline: View {
    var axis: Axis = .horizontal
    var color: Color?

    var body: some View {
        Rectangle()
            .fill(color ?? Palette.border.color)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

extension View {
    /// Closes a band with a hairline on one edge, without changing its layout.
    func hairline(_ edge: Edge, color: Color? = nil) -> some View {
        overlay(alignment: edge.alignment) {
            Hairline(axis: edge.isVertical ? .vertical : .horizontal, color: color)
        }
    }
}

extension Edge {
    fileprivate var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// Whether a rule drawn on this edge runs vertically.
    fileprivate var isVertical: Bool { self == .leading || self == .trailing }
}

// MARK: - Header

/// The band at the top of a column.
///
/// Every column opens with one of these at exactly ``Metrics/paneHeader``, so
/// the sidebar's, the list's and the diff's bottom borders land on the same y
/// and run into the column dividers. That single shared number is what makes
/// the window read as one piece — it is the difference between "three panes"
/// and "one layout".
struct PaneHeader<Content: View>: View {
    var height: CGFloat = Metrics.paneHeader
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Space.md) {
            content
        }
        .padding(.horizontal, Space.lg)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.headerFill.color)
        .hairline(.bottom)
    }
}

/// The thin rule above a table that names its columns.
///
/// Smaller, quieter and structurally distinct from ``PaneHeader``: a header
/// says what pane you are in, a column header says what the rows mean.
struct ColumnHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Space.md) {
            content
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.columnHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.headerFill.color)
        .hairline(.bottom)
    }
}

/// The band at the bottom of a pane: what is on screen, and what can be done to
/// the part of it that is selected.
///
/// Always present rather than appearing with a selection. A bar that comes and
/// goes shifts the content above it every time, which in a diff means the line
/// you were reading moves as you pick it.
struct StatusBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Space.md) {
            content
        }
        .font(Typography.secondaryDetail.monospacedDigit())
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.statusBar)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.headerFill.color)
        .hairline(.top)
    }
}

// MARK: - Content surface

extension View {
    /// The opaque ground a column's content sits on, stopping at the title bar.
    ///
    /// `ignoresSafeAreaEdges` is the whole point. A plain `.background(_:)`
    /// ignores the safe area on every edge, so a column's fill ran up *behind
    /// the title bar* — and because the title bar's material is translucent, it
    /// took its tone from whatever each column happened to be painting there.
    /// The file list showed ``Palette/contentFill`` and the diff showed the much
    /// darker ``Palette/diffCanvas``, so the one bar across the top of the window
    /// arrived in two different colours with a seam at the column divider.
    ///
    /// Stopping every content fill at the safe area leaves that strip to
    /// ``chromeBackground()``, which is the same colour in every column.
    func paneBackground() -> some View {
        background(Palette.contentFill.color, ignoresSafeAreaEdges: [.horizontal, .bottom])
    }

    /// The diff's own darker ground. Stops at the title bar for the same reason.
    func diffBackground() -> some View {
        background(Palette.diffCanvas.color, ignoresSafeAreaEdges: [.horizontal, .bottom])
    }

    /// What fills the strip behind the title bar: the header band's own colour,
    /// so the bar reads as the top of the header rather than as a fourth surface.
    /// Applied outermost, and deliberately *not* safe-area-limited.
    func chromeBackground() -> some View {
        background(Palette.headerFill.color)
    }
}

// MARK: - Buttons

/// A quiet icon button for a header band.
///
/// Bordered controls are what made the old bars read as clutter: six rounded
/// rectangles in a 380pt column is six competing shapes. Here the icon *is* the
/// button, and the affordance appears under the cursor.
struct HeaderButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(width: 24, height: 22)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
            .background {
                if isHovered && isEnabled {
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09))
                }
            }
            .contentShape(.rect)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == HeaderButtonStyle {
    static var header: HeaderButtonStyle { HeaderButtonStyle() }
}

#if DEBUG
#Preview("Bands") {
    VStack(spacing: 0) {
        PaneHeader {
            Text("pulse").font(.headline)
            Text("origin/pulse").font(Typography.secondaryDetail).foregroundStyle(.secondary)
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") {}
                .labelStyle(.iconOnly)
                .buttonStyle(.header)
        }
        ColumnHeader {
            Text("Status").frame(width: 52, alignment: .leading)
            Text("Filename")
        }
        Color.clear
            .frame(height: 120)
            .paneBackground()
        StatusBar {
            Text("2 chunks · +6 −0").foregroundStyle(.secondary)
            Spacer()
        }
    }
    .frame(width: 420)
}
#endif
