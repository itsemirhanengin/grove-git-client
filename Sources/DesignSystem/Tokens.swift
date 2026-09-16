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

/// Corner radii. Nesting rule: an inner radius is the outer radius minus the
/// padding between them, so a chip inside the 16pt panel with 8pt padding gets 8.
enum Radius {
    static let sm: CGFloat = 5
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
}

/// Fixed row and bar heights. Uniform heights are not a cosmetic choice — they
/// are what lets the diff renderer turn scroll position into integer arithmetic.
enum Metrics {
    static let fileRow: CGFloat = 24
    static let groupLabelRow: CGFloat = 20
    static let sectionHeader: CGFloat = 28
    static let accessoryBar: CGFloat = 32
    static let switcherPill: CGFloat = 32
    static let bar: CGFloat = 36

    static let sidebarMinWidth: CGFloat = 260
    static let sidebarIdealWidth: CGFloat = 300
    static let sidebarMaxWidth: CGFloat = 420

    static let listMinWidth: CGFloat = 320
    static let listIdealWidth: CGFloat = 380
    static let listMaxWidth: CGFloat = 520
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
