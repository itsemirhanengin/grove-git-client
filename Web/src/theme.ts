/// Appearance, shared by every renderer in the page.
///
/// Swift owns all of it. `Palette` resolves each colour for the window's current
/// appearance — including the two high-contrast ones, which CSS cannot see — and
/// hands the page hex strings. Nothing here invents a colour, so the diff can
/// never drift a shade away from the pane it sits in.

/// Grove's palette, resolved for one appearance.
export interface GroveChrome {
  canvas: string
  headerFill: string
  border: string
  rowSeparator: string
  added: string
  removed: string
  modified: string
  renamed: string
  attention: string
}

/// The half of every payload that describes how things look rather than what
/// they say. Split out because a light/dark flip can be applied on its own,
/// without rebuilding the document underneath it.
export interface GroveAppearance {
  themeType: 'light' | 'dark'
  fontSize: number
  chrome: GroveChrome
}

/// Shiki themes. Grove's own palette dresses everything around the code; these
/// only colour the code itself, where matching GitHub is a feature — it is the
/// syntax colouring every developer already reads diffs in.
export const DIFF_THEMES = {
  light: 'github-light-default',
  dark: 'github-dark-default',
} as const

/// Pushes the appearance onto the document element.
///
/// The library styles itself from `--diffs-*` custom properties declared on
/// `:host` inside its shadow root. Custom properties inherit *through* a shadow
/// boundary, so setting them here is enough to drive every component in the page
/// without reaching into anyone's shadow DOM.
export function applyChrome(appearance: GroveAppearance): void {
  const root = document.documentElement
  const { chrome, fontSize } = appearance
  const lineHeight = Math.round(fontSize * 1.6)

  root.style.setProperty('--grove-canvas', chrome.canvas)
  root.style.setProperty('--grove-header-fill', chrome.headerFill)
  root.style.setProperty('--grove-border', chrome.border)
  root.style.setProperty('--grove-row-separator', chrome.rowSeparator)
  root.style.setProperty('--grove-added', chrome.added)
  root.style.setProperty('--grove-removed', chrome.removed)
  root.style.setProperty('--grove-modified', chrome.modified)
  root.style.setProperty('--grove-renamed', chrome.renamed)
  root.style.setProperty('--grove-attention', chrome.attention)
  root.style.setProperty('--grove-font-size', `${fontSize}px`)

  root.style.setProperty('--diffs-font-size', `${fontSize}px`)
  root.style.setProperty('--diffs-line-height', `${lineHeight}px`)
  root.style.setProperty('--diffs-light-bg', chrome.canvas)
  root.style.setProperty('--diffs-dark-bg', chrome.canvas)

  // Full bleed. The library pads its diff on all four sides, which inside a
  // native pane reads as the diff being a card floating in the column rather
  // than the column's content — line numbers start in mid-air, and the
  // highlighted background of a changed line stops short of both edges. Zeroing
  // both gaps lands the gutter on the pane's left border and lets an added line
  // run the full width, which is what every native diff viewer does.
  root.style.setProperty('--diffs-gap-inline', '0px')
  root.style.setProperty('--diffs-gap-block', '0px')
}

/// CSS injected **into** each component's shadow root, through the library's
/// own `unsafeCSS` option.
///
/// This is the supported way in. A shadow root is opaque to `grove.css`, and the
/// rounded corners below are hardcoded pixel radii rather than custom
/// properties, so there is no variable to set and no selector that can reach
/// them from outside. `unsafeCSS` lands in an `@layer unsafe` that the library
/// declares last, so these win without `!important` anywhere.
///
/// Everything here is a **surface**, and surfaces in Grove are square. The
/// gutter's `+` button keeps its radius on purpose: that is a control, and a
/// control that looks pressable is doing its job.
export const SHADOW_CSS = `
  [data-separator="line-info"] [data-separator-content],
  [data-separator="line-info-basic"] [data-separator-content] { border-radius: 0; }
  [data-diff-span] { border-radius: 0; }
  [data-code]::-webkit-scrollbar-thumb { border-radius: 0; }

  /* The custom file header is drawn entirely by Grove, so the library's own
     header box has to stop contributing a height and a padding of its own. It
     keeps its sticky positioning, which is the one thing worth having. */
  [data-diffs-header="custom"] {
    padding: 0;
    height: auto;
    min-height: 0;
    border: 0;
    background: transparent;
  }
`
