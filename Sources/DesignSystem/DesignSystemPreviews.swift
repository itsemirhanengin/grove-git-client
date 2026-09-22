import SwiftUI

#if DEBUG

/// Every palette colour in all four appearances at once.
///
/// SwiftUI will not let a preview write `colorSchemeContrast`, so there is no
/// way to *simulate* Increase Contrast. Instead each swatch resolves its four
/// variants explicitly and shows them side by side — which is better anyway,
/// because the comparison that matters is between the variants.
struct PalettePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            header

            ForEach(Palette.statusSwatches, id: \.name) { entry in
                row(name: entry.name, letter: entry.letter, swatch: entry.swatch)
            }

            Divider()

            ForEach(Self.diffSwatches, id: \.name) { entry in
                row(name: entry.name, letter: "", swatch: entry.swatch)
            }
        }
        .padding(Space.xxl)
        .frame(width: 560)
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Text("").frame(width: 150, alignment: .leading)
            ForEach(Swatch.Appearance.allCases, id: \.self) { appearance in
                Text(appearance.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 84)
            }
        }
    }

    private func row(name: String, letter: String, swatch: Swatch) -> some View {
        HStack(spacing: Space.md) {
            Text(name)
                .font(.callout)
                .frame(width: 150, alignment: .leading)

            ForEach(Swatch.Appearance.allCases, id: \.self) { appearance in
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(swatch.resolved(appearance))
                    if !letter.isEmpty {
                        // Drawn on the appearance's own ground, so the
                        // contrast you see is the contrast you get.
                        Text(letter)
                            .font(Typography.statusLetter)
                            .foregroundStyle(
                                Palette.diffCanvas.resolved(appearance))
                    }
                }
                .frame(width: 84, height: 26)
            }
        }
    }

    private static let diffSwatches: [(name: String, swatch: Swatch)] = [
        ("Diff canvas", Palette.diffCanvas),
        ("Diff gutter", Palette.diffGutter),
        ("Added line", Palette.diffAddedBackground),
        ("Removed line", Palette.diffRemovedBackground),
        ("Added emphasis", Palette.diffAddedEmphasis),
        ("Removed emphasis", Palette.diffRemovedEmphasis),
        ("Elevated surface", Palette.surfaceElevated),
    ]
}

/// A diff fragment rendered with the real palette, which is the only way to
/// judge whether the line backgrounds are too loud.
struct DiffSurfacePreview: View {
    let appearance: Swatch.Appearance

    var body: some View {
        VStack(spacing: 0) {
            line("  context line stays quiet", nil)
            line("- const ttl = 12;", Palette.diffRemovedBackground)
            line("+ const ttl = 48;", Palette.diffAddedBackground)
            line("- emphasised removal", Palette.diffRemovedEmphasis)
            line("+ emphasised addition", Palette.diffAddedEmphasis)
            line("  context line stays quiet", nil)
        }
        .background(Palette.diffCanvas.resolved(appearance))
        .clipShape(.rect(cornerRadius: Radius.md))
        .padding(Space.xl)
        .background(Palette.surfaceElevated.resolved(appearance))
        .frame(width: 420)
    }

    private func line(_ text: String, _ background: Swatch?) -> some View {
        Text(text)
            .font(.system(size: Typography.diffSize, design: .monospaced))
            .foregroundStyle(appearance.isDark ? Color.white : Color.black)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md)
            .padding(.vertical, 2)
            .background(background?.resolved(appearance) ?? .clear)
    }
}

/// Glass in its three states. The two accessibility variants are forced with
/// `AccessibilityOverride`, since their environment values are read-only.
struct GlassPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            sample("Default", override: .none)
            sample(
                "Increase Contrast",
                override: AccessibilityOverride(increaseContrast: true))
            sample(
                "Reduce Transparency — no glass at all",
                override: AccessibilityOverride(reduceTransparency: true))
        }
        .padding(Space.xxl)
        .frame(width: 460)
    }

    private func sample(_ title: String, override: AccessibilityOverride) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            GlassEffectContainer(spacing: Space.lg) {
                HStack(spacing: Space.lg) {
                    Label("Fixtures", systemImage: "folder.fill")
                        .padding(.horizontal, Space.lg)
                        .frame(height: Metrics.paneHeader)
                        .appGlass(in: .capsule)

                    Button("Commit") {}
                        .buttonStyle(.glassProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.lg)
            // A patterned ground, so the glass has something to refract.
            .background(
                LinearGradient(
                    colors: [
                        Palette.modified.color, Palette.renamed.color, Palette.added.color,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.5)
            )
            .clipShape(.rect(cornerRadius: Radius.md))
        }
        .environment(\.accessibilityOverride, override)
    }
}

#Preview("Palette — all appearances") {
    PalettePreview()
}

#Preview("Diff · Light") { DiffSurfacePreview(appearance: .light) }
#Preview("Diff · Light HC") { DiffSurfacePreview(appearance: .lightHighContrast) }
#Preview("Diff · Dark") { DiffSurfacePreview(appearance: .dark) }
#Preview("Diff · Dark HC") { DiffSurfacePreview(appearance: .darkHighContrast) }

#Preview("Glass · Light") { GlassPreview() }
#Preview("Glass · Dark") { GlassPreview().preferredColorScheme(.dark) }

#endif
