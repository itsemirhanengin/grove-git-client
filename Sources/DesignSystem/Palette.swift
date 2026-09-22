import AppKit
import SwiftUI

/// One semantic colour, defined for all four appearances Grove has to survive.
///
/// Keeping the four values together — rather than hiding them behind a resolved
/// `Color` — is what makes them reviewable: the design-system preview can render
/// every variant side by side, instead of requiring a trip through System
/// Settings to see the high-contrast ones.
nonisolated struct Swatch: Sendable, Equatable {

    nonisolated enum Appearance: String, CaseIterable, Sendable {
        case light = "Light"
        case lightHighContrast = "Light · HC"
        case dark = "Dark"
        case darkHighContrast = "Dark · HC"

        var appearanceName: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .lightHighContrast: .accessibilityHighContrastAqua
            case .dark: .darkAqua
            case .darkHighContrast: .accessibilityHighContrastDarkAqua
            }
        }

        var isDark: Bool { self == .dark || self == .darkHighContrast }
    }

    let light: UInt32
    let lightHighContrast: UInt32
    let dark: UInt32
    let darkHighContrast: UInt32

    func hex(for appearance: Appearance) -> UInt32 {
        switch appearance {
        case .light: light
        case .lightHighContrast: lightHighContrast
        case .dark: dark
        case .darkHighContrast: darkHighContrast
        }
    }

    /// The value for one specific appearance, for previews and tests.
    func resolved(_ appearance: Appearance) -> Color {
        Color(nsColor: NSColor(hex: hex(for: appearance)))
    }

    /// `#rrggbb` for one colour scheme.
    ///
    /// For handing a colour to something that is neither AppKit nor SwiftUI and
    /// therefore cannot resolve a dynamic colour itself — the diff renderer's
    /// web page, which has to match the window it sits in.
    func hexString(for scheme: ColorScheme) -> String {
        String(format: "#%06X", hex(for: scheme == .dark ? .dark : .light))
    }

    /// The live colour, which re-resolves itself as the appearance changes.
    ///
    /// `bestMatch(from:)` is what makes Increase Contrast work: the resolving
    /// appearance reports which of the four named appearances it is closest to.
    @MainActor var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua,
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let variant: Appearance =
                switch match {
                case .some(.accessibilityHighContrastDarkAqua): .darkHighContrast
                case .some(.accessibilityHighContrastAqua): .lightHighContrast
                case .some(.darkAqua): .dark
                default: .light
                }
            return NSColor(hex: self.hex(for: variant))
        }
    }

    @MainActor var color: Color { Color(nsColor: nsColor) }
}

/// Grove's semantic colours.
///
/// The plan called for an Asset Catalog here, on the grounds that the
/// high-contrast variant "cannot be resolved from computed colours". That turned
/// out to be wrong — `NSColor(name:dynamicProvider:)` receives the resolving
/// `NSAppearance`, and `NSAppearanceNameAccessibilityHighContrastAqua` /
/// `…DarkAqua` are both real appearance names — so all four are reachable from
/// code. One readable Swift file therefore beats twelve `.colorset` JSON blobs:
/// tuning a colour is a one-line edit rather than hand-editing float components.
///
/// Two deliberate choices in the palette itself:
///
/// - **Modified is blue and conflict is amber.** Using yellow for both, as some
///   clients do, makes a conflict indistinguishable from an ordinary edit.
/// - **Red is reserved** for deletions and destructive actions, so a failed
///   fetch never reads as "this file was deleted".
enum Palette {

    // MARK: Git status

    static let added = Swatch(
        light: 0x1A7F_37, lightHighContrast: 0x0B5D_24,
        dark: 0x3FB9_50, darkHighContrast: 0x56E0_6B)
    static let removed = Swatch(
        light: 0xCF22_2E, lightHighContrast: 0xA00E_1B,
        dark: 0xF851_49, darkHighContrast: 0xFF7B_72)
    static let modified = Swatch(
        light: 0x0969_DA, lightHighContrast: 0x0546_8F,
        dark: 0x58A6_FF, darkHighContrast: 0x79C0_FF)
    static let untracked = Swatch(
        light: 0x0E74_90, lightHighContrast: 0x0A52_66,
        dark: 0x2DD4_BF, darkHighContrast: 0x5EEA_D4)
    static let renamed = Swatch(
        light: 0x8250_DF, lightHighContrast: 0x6135_B8,
        dark: 0xBC8C_FF, darkHighContrast: 0xD2B3_FF)

    /// Conflicts, warnings and recoverable errors. Never red.
    static let attention = Swatch(
        light: 0xBC4C_00, lightHighContrast: 0x8F39_00,
        dark: 0xF088_3E, darkHighContrast: 0xFFA6_57)

    // MARK: Diff surface

    /// Opaque by design — glass behind scrolling code is a readability and
    /// performance mistake.
    static let diffCanvas = Swatch(
        light: 0xFFFF_FF, lightHighContrast: 0xFFFF_FF,
        dark: 0x0D11_17, darkHighContrast: 0x0107_0E)

    /// Line backgrounds are their own colours rather than `.opacity()` on the
    /// foreground: dark mode needs different *saturation*, not different alpha,
    /// and alpha over a material composites unpredictably.
    static let diffAddedBackground = Swatch(
        light: 0xE6FF_EC, lightHighContrast: 0xCEFF_DA,
        dark: 0x0F26_1A, darkHighContrast: 0x0733_18)
    static let diffRemovedBackground = Swatch(
        light: 0xFFEB_E9, lightHighContrast: 0xFFD7_D5,
        dark: 0x2617_1C, darkHighContrast: 0x3A0D_12)

    /// Stronger tint for the characters that actually changed within a line.
    static let diffAddedEmphasis = Swatch(
        light: 0xABF2_BC, lightHighContrast: 0x7CE5_94,
        dark: 0x1F61_2C, darkHighContrast: 0x2C84_3D)
    static let diffRemovedEmphasis = Swatch(
        light: 0xFFC1_C0, lightHighContrast: 0xFF9A_98,
        dark: 0x6B20_27, darkHighContrast: 0x8F2B_33)

    /// Gutter, one step from the canvas so line numbers stay legible.
    static let diffGutter = Swatch(
        light: 0xF6F8_FA, lightHighContrast: 0xEDF1_F5,
        dark: 0x1117_1D, darkHighContrast: 0x0A0F_16)

    // MARK: Chrome

    /// Opaque stand-in wherever glass is suppressed by Reduce Transparency.
    static let surfaceElevated = Swatch(
        light: 0xF6F8_FA, lightHighContrast: 0xFFFF_FF,
        dark: 0x161B_22, darkHighContrast: 0x1C22_2B)

    /// The reading surface the file list and its tables sit on. Opaque, not a
    /// material: a table of file names is content, and content that samples
    /// what is behind the window is content you have to work to read.
    static let contentFill = Swatch(
        light: 0xFFFF_FF, lightHighContrast: 0xFFFF_FF,
        dark: 0x1C1C_1F, darkHighContrast: 0x0E0E_10)

    /// Every pane header, column header, status bar — and the strip behind the
    /// title bar, which is the same band seen from above.
    ///
    /// **Neutral, not blue.** The first version of these greys carried a slight
    /// blue cast, which put them at odds with the one surface in the window we
    /// do not control: macOS's own sidebar material, which is neutral. Two
    /// almost-but-not-quite matching greys across a column divider is worse than
    /// an honest contrast, so the palette follows the sidebar rather than
    /// fighting it. The dark value is measured from that material.
    static let headerFill = Swatch(
        light: 0xF2F2_F3, lightHighContrast: 0xE8E8_E9,
        dark: 0x2525_28, darkHighContrast: 0x1717_1A)

    /// The hairline that does the actual work of this design: it closes every
    /// header, separates every row, and divides every column. `separatorColor`
    /// is deliberately not used — it is tuned for list views over vibrancy and
    /// all but vanishes against ``headerFill``.
    static let border = Swatch(
        light: 0xD8D8_DA, lightHighContrast: 0xA0A0_A3,
        dark: 0x3434_37, darkHighContrast: 0x4E4E_52)

    /// The row separator inside a table. A quieter ``border`` — a full-strength
    /// rule under every file name turns a list into a spreadsheet.
    static let rowSeparator = Swatch(
        light: 0xECEC_EE, lightHighContrast: 0xD4D4_D6,
        dark: 0x2A2A_2D, darkHighContrast: 0x3A3A_3E)

    /// Everything that appears in the design-system preview, in display order.
    static let statusSwatches: [(name: String, letter: String, swatch: Swatch)] = [
        ("Added", "A", added),
        ("Removed", "D", removed),
        ("Modified", "M", modified),
        ("Untracked / new", "A", untracked),
        ("Renamed", "R", renamed),
        ("Conflict / warning", "U", attention),
    ]
}

nonisolated extension NSColor {
    /// `0xRRGGBB` in sRGB, which is what the hex values above assume.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Status mapping

extension StatusCode {
    @MainActor var tint: Color {
        switch self {
        case .added: Palette.added.color
        case .deleted: Palette.removed.color
        case .renamed, .copied: Palette.renamed.color
        case .unmerged: Palette.attention.color
        case .modified, .typeChanged: Palette.modified.color
        case .unchanged: .secondary
        }
    }
}

extension FileChange {
    /// The colour of this change's status letter, taking untracked and
    /// conflicted into account — neither of which is expressible as a plain
    /// `StatusCode`.
    @MainActor func tint(staged: Bool) -> Color {
        if isConflicted { return Palette.attention.color }
        if kind == .untracked { return Palette.untracked.color }
        return (staged ? indexStatus : worktreeStatus).tint
    }

    /// The letter shown in the status column.
    ///
    /// An untracked file is `A`, not git's own `?`. The question mark is
    /// porcelain shorthand for "git has never heard of this path", which is true
    /// but reads in a UI as *Grove* not knowing what the file is — it was
    /// reported as a bug on sight. `A` says the thing that is actually true of
    /// it: ticking its box adds it. The distinction from a staged addition
    /// survives in the colour, which is ``Palette/untracked`` rather than
    /// ``Palette/added``, and in the row's tooltip.
    func statusLetter(staged: Bool) -> String {
        if isConflicted { return "U" }
        if kind == .untracked { return "A" }
        return (staged ? indexStatus : worktreeStatus).letter
    }

    /// What the status letter means, spelled out for the row's tooltip.
    var statusDescription: String {
        if isConflicted { return "Conflicted" }
        if kind == .untracked { return "New file, not yet tracked" }
        switch worktreeStatus.isChanged ? worktreeStatus : indexStatus {
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return originalDisplayPath.map { "Renamed from \($0)" } ?? "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        default: return "Modified"
        }
    }
}
