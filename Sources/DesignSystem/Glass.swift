import SwiftUI

/// Forces an accessibility setting on, for previews and tests.
///
/// `accessibilityReduceTransparency` and `colorSchemeContrast` are **read-only**
/// environment values — SwiftUI does not let you write them — so there is
/// otherwise no way to see the Reduce Transparency path without changing System
/// Settings. That is exactly the kind of check that quietly stops happening, so
/// the design system reads this override first and the real setting second.
nonisolated struct AccessibilityOverride: Equatable, Sendable {
    var reduceTransparency: Bool?
    var increaseContrast: Bool?

    static let none = AccessibilityOverride()
}

extension EnvironmentValues {
    @Entry var accessibilityOverride = AccessibilityOverride.none
}

/// The **only** file in Grove allowed to call `glassEffect`. `scripts/test.sh`
/// fails the build if that call appears anywhere else.
///
/// The rule this enforces: *glass floats, content sits.* Chrome that hovers over
/// scrolling content may be glass — the workspace switcher, the commit composer,
/// the hunk navigator, the global action bar. Anything the user reads or scrubs
/// stays opaque and flat. In particular glass never appears inside a `ForEach`,
/// because each glass surface is its own backdrop-sampling pass and a list of
/// them is both unreadable and slow.
///
/// Routing every site through one modifier is also what makes the accessibility
/// contract impossible to forget: under Reduce Transparency `glassEffect` is not
/// called at all, and under Increase Contrast the surface gains a real border.
struct AppGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var glass: Glass = .regular

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityOverride) private var override

    private var reduceTransparency: Bool {
        override.reduceTransparency ?? systemReduceTransparency
    }

    private var increaseContrast: Bool {
        override.increaseContrast ?? (systemContrast == .increased)
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            // Not "glass with less blur" — a genuinely opaque surface.
            content
                .background(Palette.surfaceElevated.color, in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        } else if increaseContrast {
            content
                .glassEffect(glass, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.28), lineWidth: 1))
        } else {
            content
                .glassEffect(glass, in: shape)
        }
    }
}

extension View {
    /// Apply Grove's glass treatment, with the accessibility fallbacks built in.
    ///
    /// Apply it *after* layout modifiers (`padding`, `frame`), and keep the shape
    /// consistent within a feature — glass cannot sample other glass, so grouped
    /// elements belong in a single `GlassEffectContainer`.
    func appGlass<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        modifier(AppGlassModifier(shape: shape, glass: glass))
    }

}
