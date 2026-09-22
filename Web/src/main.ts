import './grove.css'
import { FileDiff, UnresolvedFile, processFile } from '@pierre/diffs'
import type { FileDiffMetadata, SelectedLineRange } from '@pierre/diffs'

/// What Swift sends when the selected file, the staged side, or the context
/// width changes. `generation` is the cache key: `@pierre/diffs` memoises
/// rendered output per key, so it has to change whenever the patch does.
interface RenderPayload {
  patch: string
  fileName: string
  diffStyle: 'unified' | 'split'
  themeType: 'light' | 'dark'
  fontSize: number
  canvas: string
  generation: number
}

/// A conflicted file, sent as the working-tree text *with its conflict markers
/// still in it*. That text is the thing git left behind and the thing the user
/// has to resolve, so it is what the page is given.
interface ConflictPayload {
  fileName: string
  contents: string
  themeType: 'light' | 'dark'
  fontSize: number
  canvas: string
  generation: number
}

interface GroveBridge {
  render(payload: string): void
  renderConflict(payload: string): void
  setThemeType(themeType: 'light' | 'dark', canvas: string): void
  clearSelection(): void
}

declare global {
  interface Window {
    grove: GroveBridge
    webkit?: {
      messageHandlers?: Record<string, { postMessage(body: unknown): void }>
    }
  }
}

/// Everything the page tells Swift goes through here. Swift is the only thing
/// listening, and it is not there when the page is opened in a browser for
/// debugging, so this must stay optional.
function send(message: Record<string, unknown>): void {
  window.webkit?.messageHandlers?.grove?.postMessage(message)
}

const container = document.getElementById('diff')
if (!container) throw new Error('missing #diff container')

let component: FileDiff | undefined
let conflictComponent: UnresolvedFile | undefined
/// Which file the live `UnresolvedFile` was built for. See `renderConflict`.
let conflictKey: string | undefined
let lastPayload: RenderPayload | undefined

/// Only one of the two components may own the container at a time — they both
/// create their own `<diffs-container>`, and leaving the other one mounted
/// stacks two files on top of each other.
function tearDownOthers(keep: 'diff' | 'conflict'): void {
  if (keep !== 'diff' && component) {
    component.cleanUp()
    component = undefined
  }
  if (keep !== 'conflict' && conflictComponent) {
    conflictComponent.cleanUp()
    conflictComponent = undefined
    conflictKey = undefined
  }
}

/// The library styles itself from `--diffs-*` custom properties declared on
/// `:host` inside its shadow root. Custom properties inherit *through* a shadow
/// boundary, so setting them on the document element is enough to drive the
/// component without reaching into its shadow DOM.
function applyChrome(payload: Pick<RenderPayload, 'canvas' | 'fontSize'>): void {
  const root = document.documentElement
  const lineHeight = Math.round(payload.fontSize * 1.6)

  root.style.setProperty('--grove-canvas', payload.canvas)
  root.style.setProperty('--diffs-font-size', `${payload.fontSize}px`)
  root.style.setProperty('--diffs-line-height', `${lineHeight}px`)
  root.style.setProperty('--diffs-light-bg', payload.canvas)
  root.style.setProperty('--diffs-dark-bg', payload.canvas)

  // Full bleed. The library pads its diff on all four sides, which inside a
  // native pane reads as the diff being a card floating in the column rather
  // than the column's content — line numbers start in mid-air, and the
  // highlighted background of a changed line stops short of both edges. Zeroing
  // both gaps lands the gutter on the pane's left border and lets an added line
  // run the full width, which is what every native diff viewer does.
  root.style.setProperty('--diffs-gap-inline', '0px')
  root.style.setProperty('--diffs-gap-block', '0px')
}

/// Squares off the corners the library rounds inside its own shadow root.
///
/// Two of them: the "N unmodified lines" separator and the word-level highlight
/// within a changed line. Both are hardcoded pixel radii rather than custom
/// properties, so there is no variable to set — and a shadow root is opaque to
/// the document's stylesheet, so `grove.css` cannot reach them either.
///
/// The gutter's `+` button keeps its radius on purpose. Everything else here is
/// a *surface*, and surfaces in Grove are square; that is a control, and a
/// control that looks pressable is doing its job.
///
/// It can still be done cleanly because the component attaches its shadow root
/// `open` and styles itself through `adoptedStyleSheets`: appending one more
/// sheet to that array is the supported way to extend it, and it survives the
/// library restyling itself.
const SQUARE_CORNERS = `
  [data-separator="line-info"] [data-separator-content],
  [data-separator="line-info-basic"] [data-separator-content] { border-radius: 0; }
  [data-diff-span] { border-radius: 0; }
  [data-code]::-webkit-scrollbar-thumb { border-radius: 0; }
`

let squareSheet: CSSStyleSheet | undefined

function applySquareCorners(attempt = 0): void {
  const host = container!.querySelector('diffs-container')
  const root = host?.shadowRoot
  if (!root) {
    // The custom element attaches its shadow root when it connects, which is
    // synchronous — but only once the element definition has been upgraded. On
    // the very first render that can land a frame late, and giving up silently
    // would leave exactly one diff per launch with rounded corners.
    if (attempt < 10) requestAnimationFrame(() => applySquareCorners(attempt + 1))
    return
  }

  if (!squareSheet) {
    squareSheet = new CSSStyleSheet()
    squareSheet.replaceSync(SQUARE_CORNERS)
  }
  if (!root.adoptedStyleSheets.includes(squareSheet)) {
    // Appended, never assigned: the library's own sheet is already in there and
    // replacing the array would render the diff unstyled.
    root.adoptedStyleSheets = [...root.adoptedStyleSheets, squareSheet]
  }
}

function showNotice(text: string): void {
  container!.replaceChildren()
  const notice = document.createElement('p')
  notice.className = 'grove-notice'
  notice.textContent = text
  container!.append(notice)
}

function render(raw: string): void {
  let payload: RenderPayload
  try {
    payload = JSON.parse(raw) as RenderPayload
  } catch (error) {
    send({ type: 'error', message: `bad payload: ${String(error)}` })
    return
  }

  lastPayload = payload
  applyChrome(payload)
  tearDownOthers('diff')

  if (payload.patch.trim().length === 0) {
    component?.cleanUp()
    component = undefined
    showNotice('No textual changes.')
    send({ type: 'rendered', lines: 0 })
    return
  }

  let metadata: FileDiffMetadata | undefined
  try {
    // `isGitDiff` tells the parser the input is `git diff` output — with its
    // `diff --git`, `index`, rename and mode lines — rather than a bare
    // unified diff. Getting that wrong loses renames entirely.
    metadata = processFile(payload.patch, {
      isGitDiff: true,
      cacheKey: `${payload.fileName}:${payload.generation}`,
    })
  } catch (error) {
    send({ type: 'error', message: `parse failed: ${String(error)}` })
    showNotice('Could not parse this diff.')
    return
  }

  if (!metadata) {
    showNotice('No textual changes.')
    send({ type: 'rendered', lines: 0 })
    return
  }

  const options = {
    // Grove draws the file name, the staged switch and the counts itself, in
    // real AppKit controls. The web layer renders the diff and nothing else.
    disableFileHeader: true,
    diffStyle: payload.diffStyle,
    diffIndicators: 'classic' as const,
    hunkSeparators: 'line-info' as const,
    // A diff line is a unit; wrapping it breaks its correspondence with the
    // line number beside it.
    overflow: 'scroll' as const,
    themeType: payload.themeType,
    theme: {
      light: 'github-light-default',
      dark: 'github-dark-default',
    },
    // Line staging starts here and ends here: the page reports which rows were
    // picked and does nothing else with them. Turning a selection into a patch
    // is git's business, and git lives on the Swift side of the bridge.
    enableLineSelection: true,
    onLineSelected: (range: SelectedLineRange | null) => {
      send({ type: 'selection', range })
    },
    // The hover affordance in the line-number column. Its whole job is to say,
    // without a legend anywhere, that rows here can be picked at all — nothing
    // else on screen advertises line staging until you have already tried it.
    // The library draws and styles the button; Grove only turns it on.
    enableGutterUtility: true,
    // Deliberately empty, and required. `enableGutterUtility` on its own is
    // inert: the drag the button starts is gated on this callback existing. The
    // range it produces is committed through `onLineSelected` on the same
    // pointer-up, so reporting it from here would send Swift the same selection
    // twice.
    onGutterUtilityClick: () => {},
  }

  if (!component) {
    component = new FileDiff(options)
  } else {
    component.setOptions(options)
  }

  // `containerWrapper` is the *parent*, not the container. Passing our own
  // element as `fileContainer` is what broke the first attempt: the library
  // then never creates its `<diffs-container>` custom element, whose shadow
  // root is where all of its `:host` styling lives — so the diff renders with
  // no grid, no colours and no alignment at all.
  component.render({ fileDiff: metadata, containerWrapper: container! })
  applySquareCorners()

  // A selection means line numbers in *this* diff. Carrying one across a file
  // change would hand Swift a range that points into a document nobody is
  // looking at any more.
  component.setSelectedLines(null, { notify: false })

  send({ type: 'rendered', lines: metadata.hunks?.length ?? 0 })
}

/// The conflict resolver.
///
/// `UnresolvedFile` is the library's own: it parses the conflict markers, draws
/// each region with Accept Current / Incoming / Both buttons, and hands back the
/// **whole resolved file** when one is taken. Swift writes that to disk — the
/// page never touches the filesystem and never decides what "resolved" means.
function renderConflict(raw: string): void {
  let payload: ConflictPayload
  try {
    payload = JSON.parse(raw) as ConflictPayload
  } catch (error) {
    send({ type: 'error', message: `bad conflict payload: ${String(error)}` })
    return
  }

  applyChrome(payload)
  tearDownOthers('conflict')

  const options = {
    disableFileHeader: true,
    diffIndicators: 'classic' as const,
    hunkSeparators: 'line-info' as const,
    overflow: 'scroll' as const,
    themeType: payload.themeType,
    theme: {
      light: 'github-light-default',
      dark: 'github-dark-default',
    },
    // The library's own buttons, in the gutter of each conflict region. Drawing
    // our own would mean re-deriving where every region starts, which is the
    // one thing it has already done.
    mergeConflictActionsType: 'default' as const,
    onMergeConflictResolve: (file: { contents: string }) => {
      send({ type: 'conflictResolved', contents: file.contents })
    },
  }

  // `UnresolvedFile` parses a file exactly once and owns the resolved state
  // from then on: re-rendering it with different contents throws
  // *"uncontrolled unresolved files parse the file only once"*. Swift does send
  // new contents — after a resolution is written and staged, and whenever the
  // file is reselected — so a changed file gets a **new component** rather than
  // a second `render` on the old one.
  const key = `${payload.fileName}:${payload.generation}`
  if (conflictComponent && conflictKey !== key) {
    conflictComponent.cleanUp()
    conflictComponent = undefined
  }
  conflictKey = key

  if (!conflictComponent) {
    conflictComponent = new UnresolvedFile(options)
  } else {
    conflictComponent.setOptions(options)
  }

  try {
    conflictComponent.render({
      file: {
        name: payload.fileName,
        contents: payload.contents,
        cacheKey: key,
      },
      containerWrapper: container!,
    })
  } catch (error) {
    send({ type: 'error', message: `conflict render failed: ${String(error)}` })
    showNotice('Could not read the conflict markers in this file.')
    return
  }

  applySquareCorners()

  send({ type: 'rendered', lines: 0 })
}

function setThemeType(themeType: 'light' | 'dark', canvas: string): void {
  if (lastPayload) {
    lastPayload.themeType = themeType
    lastPayload.canvas = canvas
    applyChrome(lastPayload)
  }
  component?.setThemeType(themeType)
  conflictComponent?.setThemeType(themeType)
}

/// Called after a staging operation, so the rows that were just consumed stop
/// looking selected. `notify: false` keeps it from echoing straight back.
function clearSelection(): void {
  component?.setSelectedLines(null, { notify: false })
}

window.grove = { render, renderConflict, setThemeType, clearSelection }

// Swift holds its first payload until this lands: `loadFileURL` is asynchronous
// and evaluating into the page before the module has run does nothing.
send({ type: 'ready' })
