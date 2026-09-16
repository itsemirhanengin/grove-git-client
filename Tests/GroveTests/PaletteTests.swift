import Foundation
import Testing

@testable import Grove

/// Contrast checks for the palette.
///
/// A colour that looks fine in dark mode can be unreadable in light mode, and
/// nobody notices until they switch. Measuring the ratio here turns that into a
/// build failure instead of a complaint.
@Suite("Palette contrast")
struct PaletteTests {

    /// WCAG relative luminance.
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let value = Double(raw) / 255
            return value <= 0.03928
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        let red = channel((hex >> 16) & 0xFF)
        let green = channel((hex >> 8) & 0xFF)
        let blue = channel(hex & 0xFF)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// WCAG contrast ratio, 1...21.
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    /// Status letters are 11pt semibold — small text, so WCAG AA asks for 4.5:1.
    private let minimumTextContrast = 4.5

    @Test(
        "every status colour is readable on the canvas in all four appearances",
        arguments: Swatch.Appearance.allCases
    )
    func statusContrast(appearance: Swatch.Appearance) {
        let canvas = Palette.diffCanvas.hex(for: appearance)

        for entry in Palette.statusSwatches {
            let ratio = contrast(entry.swatch.hex(for: appearance), canvas)
            #expect(
                ratio >= minimumTextContrast,
                """
                \(entry.name) on the canvas in \(appearance.rawValue) is \
                \(String(format: "%.2f", ratio)):1, below the \(minimumTextContrast):1 minimum.
                """
            )
        }
    }

    @Test(
        "status colours are readable on the elevated surface too",
        arguments: Swatch.Appearance.allCases
    )
    func statusOnChrome(appearance: Swatch.Appearance) {
        let surface = Palette.surfaceElevated.hex(for: appearance)

        for entry in Palette.statusSwatches {
            let ratio = contrast(entry.swatch.hex(for: appearance), surface)
            #expect(
                ratio >= minimumTextContrast,
                """
                \(entry.name) on the elevated surface in \(appearance.rawValue) is \
                \(String(format: "%.2f", ratio)):1.
                """
            )
        }
    }

    /// Diff line backgrounds must be visible against the canvas but must not
    /// swamp the code sitting on them — a tint that is too strong is as bad as
    /// one that is invisible.
    @Test(
        "diff line backgrounds are a visible but gentle step from the canvas",
        arguments: Swatch.Appearance.allCases
    )
    func diffBackgroundContrast(appearance: Swatch.Appearance) {
        let canvas = Palette.diffCanvas.hex(for: appearance)

        for (name, swatch) in [
            ("added", Palette.diffAddedBackground),
            ("removed", Palette.diffRemovedBackground),
        ] {
            let ratio = contrast(swatch.hex(for: appearance), canvas)
            #expect(ratio > 1.02, "\(name) background is invisible in \(appearance.rawValue)")
            #expect(
                ratio < 3.0,
                "\(name) background is too loud in \(appearance.rawValue) (\(ratio):1)"
            )
        }
    }

    /// Emphasis marks the characters that actually changed, so it has to be a
    /// clear step beyond the plain line background.
    @Test("emphasis is stronger than the plain line background", arguments: Swatch.Appearance.allCases)
    func emphasisIsStronger(appearance: Swatch.Appearance) {
        let canvas = Palette.diffCanvas.hex(for: appearance)

        let addedPlain = contrast(Palette.diffAddedBackground.hex(for: appearance), canvas)
        let addedEmphasis = contrast(Palette.diffAddedEmphasis.hex(for: appearance), canvas)
        #expect(addedEmphasis > addedPlain)

        let removedPlain = contrast(Palette.diffRemovedBackground.hex(for: appearance), canvas)
        let removedEmphasis = contrast(Palette.diffRemovedEmphasis.hex(for: appearance), canvas)
        #expect(removedEmphasis > removedPlain)
    }

    @Test("high-contrast variants really do increase contrast")
    func highContrastIsStronger() {
        for entry in Palette.statusSwatches {
            let light = contrast(
                entry.swatch.hex(for: .light), Palette.diffCanvas.hex(for: .light))
            let lightHC = contrast(
                entry.swatch.hex(for: .lightHighContrast),
                Palette.diffCanvas.hex(for: .lightHighContrast))
            #expect(lightHC >= light, "\(entry.name): light HC is not stronger than light")

            let dark = contrast(entry.swatch.hex(for: .dark), Palette.diffCanvas.hex(for: .dark))
            let darkHC = contrast(
                entry.swatch.hex(for: .darkHighContrast),
                Palette.diffCanvas.hex(for: .darkHighContrast))
            #expect(darkHC >= dark, "\(entry.name): dark HC is not stronger than dark")
        }
    }

    @Test("light and dark variants are actually different")
    func variantsDiffer() {
        for entry in Palette.statusSwatches {
            #expect(
                entry.swatch.light != entry.swatch.dark,
                "\(entry.name) uses the same colour in light and dark"
            )
        }
    }

    /// Red is reserved for deletion and destructive actions; conflicts and
    /// warnings are amber. If those two ever converge the distinction is lost.
    @Test("attention is clearly distinct from removed")
    func attentionIsNotRed() {
        for appearance in Swatch.Appearance.allCases {
            let removed = Palette.removed.hex(for: appearance)
            let attention = Palette.attention.hex(for: appearance)
            #expect(removed != attention)

            // Compare hue by channel ordering: amber must be visibly greener
            // than red, or the two read as the same colour.
            let removedGreen = (removed >> 8) & 0xFF
            let attentionGreen = (attention >> 8) & 0xFF
            #expect(
                attentionGreen > removedGreen,
                "attention is not distinguishable from removed in \(appearance.rawValue)"
            )
        }
    }
}
