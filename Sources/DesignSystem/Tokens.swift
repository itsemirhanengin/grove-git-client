import SwiftUI

/// 4pt spacing scale. Plain constants, no protocol layer — this is a design
/// system for one app, not a framework.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

/// Corner radii, and the deliberate absence of them.
///
/// Grove's panes are **square**: a header, a row, a table and a diff all run
/// edge to edge and meet their neighbours on a hairline. Rounding is reserved
/// for things that genuinely float free of the grid — a menu, a popover, a
/// badge — which is why the scale stops at `md`.
enum Radius {
    static let xs: CGFloat = 3
    static let sm: CGFloat = 5
    static let md: CGFloat = 8
}

/// Fixed row and bar heights.
///
/// The one that matters most is ``paneHeader``. Every column — sidebar, file
/// list, diff — opens with a header of exactly that height, so their bottom
/// borders meet the vertical column dividers at the same y and the window reads
/// as one grid rather than three stacked panes that happen to be adjacent.
enum Metrics {
    static let fileRow: CGFloat = 26
    static let groupLabelRow: CGFloat = 22

    /// A commit in the history list. Taller than a file row because it carries
    /// two lines: who and when above, what and which id below. One line forced
    /// author, date, subject and hash into a single run of text where nothing
    /// had a column of its own and everything competed for the same width.
    ///
    /// Two lines need room to read as two lines. 38pt fitted them and nothing
    /// else: the avatar came out smaller than the text beside it, the rail had
    /// no gutter of its own, and the identity line sat on the subject. Density
    /// is not the goal here — a commit is the unit being scanned, and it has to
    /// look like one thing rather than four stacked ones.
    static let commitRow: CGFloat = 48

    /// The header band shared by every column. Nothing else may be this tall.
    static let paneHeader: CGFloat = 38

    /// The thin summary rule above a table.
    static let columnHeader: CGFloat = 22

    /// The band that separates one repository's rows from the next one's in the
    /// Overview. Between a column header and a pane header on purpose: it has to
    /// win against a list of rows without competing with the pane's own header.
    static let sectionBand: CGFloat = 28

    /// The bar pinned to the bottom of a pane.
    static let statusBar: CGFloat = 28

    static let sidebarMinWidth: CGFloat = 240
    static let sidebarIdealWidth: CGFloat = 264
    static let sidebarMaxWidth: CGFloat = 380

    static let listMinWidth: CGFloat = 340
    static let listIdealWidth: CGFloat = 400
    static let listMaxWidth: CGFloat = 560
}

/// Motion, funnelled through one place so Reduce Motion cannot be forgotten.
///
/// Nothing uses `morph` at present. The workspace switcher did, until it became
/// a plain dropdown on 2026-09-16 — the owner wanted it to float over the list
/// rather than push it down, and a much quieter animation than a matched
/// geometry morph. It is kept for the next thing that earns an entrance.
enum Motion {
    static func morph(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : .smooth(duration: 0.32, extraBounce: 0.02)
    }

    static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : .smooth(duration: 0.22)
    }

    /// Row moves animate only in small batches; above this count the animation
    /// costs more than it communicates.
    static let bulkAnimationThreshold = 25
}

/// Typography. `.monospacedDigit()` belongs on every count, badge and line number
/// — without it numbers jitter as they change and the UI reads as unstable.
enum Typography {
    static let repoName = Font.headline
    static let fileName = Font.body
    static let secondaryDetail = Font.caption
    static let keyHint = Font.caption2.monospaced()

    /// Monospaced so M / A / D / U / ? all share an advance width and the status
    /// column stays flush.
    static let statusLetter = Font.system(size: 11, weight: .semibold, design: .monospaced)

    static let diffSize: CGFloat = 11.5
    static let diffLineHeightMultiple: CGFloat = 1.45
}
