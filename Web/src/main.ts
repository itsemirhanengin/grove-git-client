import './grove.css'
import { FileDiff, UnresolvedFile, processFile } from '@pierre/diffs'
import type { FileDiffMetadata, SelectedLineRange } from '@pierre/diffs'

import { ChangesetView, type ChangesetPayload } from './changeset'
import { DIFF_THEMES, SHADOW_CSS, applyChrome, type GroveAppearance } from './theme'

/// The page renders three documents, one at a time: a single file's diff, a
/// whole commit, and a conflicted file. Grove draws everything around them.

/// One file, as the working copy and the stash panes show it. `generation` is
/// the cache key: `@pierre/diffs` memoises rendered output per key, so it has to
/// change whenever the patch does.
interface RenderPayload {
  patch: string
  fileName: string
  diffStyle: 'unified' | 'split'
  generation: number
  appearance: GroveAppearance
}

/// A conflicted file, sent as the working-tree text *with its conflict markers
/// still in it*. That text is the thing git left behind and the thing the user
/// has to resolve, so it is what the page is given.
interface ConflictPayload {
  fileName: string
  contents: string
  generation: number
  appearance: GroveAppearance
}

interface GroveBridge {
  render(payload: string): void
  renderChangeset(payload: string): void
  renderConflict(payload: string): void
  setChangesetCollapsed(collapsed: boolean): void
  scrollToChangesetFile(id: string): void
  setAppearance(appearance: string): void
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
const changesetRoot = document.getElementById('changeset')
if (!container || !changesetRoot) throw new Error('missing renderer containers')

let component: FileDiff | undefined
let conflictComponent: UnresolvedFile | undefined
/// Which file the live `UnresolvedFile` was built for. See `renderConflict`.
let conflictKey: string | undefined
let changeset: ChangesetView | undefined
let appearance: GroveAppearance | undefined

/// Which of the three documents owns the page.
type Mode = 'diff' | 'changeset' | 'conflict'

/// Only one document may be visible at a time — each builds its own
/// `<diffs-container>`, and leaving another mounted stacks two files on top of
/// each other. The changeset is torn down rather than hidden: it is the one that
/// can be holding thousands of parsed files.
function activate(mode: Mode): void {
  container!.hidden = mode === 'changeset'
  changesetRoot!.hidden = mode !== 'changeset'

  if (mode !== 'diff' && component) {
    component.cleanUp()
    component = undefined
  }
  if (mode !== 'conflict' && conflictComponent) {
    conflictComponent.cleanUp()
    conflictComponent = undefined
    conflictKey = undefined
  }
  if (mode !== 'changeset') changeset?.clear()
}

function showNotice(text: string): void {
  container!.replaceChildren()
  const notice = document.createElement('p')
  notice.className = 'grove-notice'
  notice.textContent = text
  container!.append(notice)
}

function parse<T>(raw: string, what: string): T | undefined {
  try {
    return JSON.parse(raw) as T
  } catch (error) {
    send({ type: 'error', message: `bad ${what} payload: ${String(error)}` })
    return undefined
  }
}

// MARK: - One file

function render(raw: string): void {
  const payload = parse<RenderPayload>(raw, 'diff')
  if (payload == null) return

  appearance = payload.appearance
  applyChrome(payload.appearance)
  activate('diff')

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
    // real AppKit controls. Here the web layer renders the diff and nothing
    // else — unlike the changeset, where the header is the disclosure and has
    // to live beside the file it opens.
    disableFileHeader: true,
    diffStyle: payload.diffStyle,
    diffIndicators: 'classic' as const,
    hunkSeparators: 'line-info' as const,
    // A diff line is a unit; wrapping it breaks its correspondence with the
    // line number beside it.
    overflow: 'scroll' as const,
    themeType: payload.appearance.themeType,
    theme: DIFF_THEMES,
    unsafeCSS: SHADOW_CSS,
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

  // A selection means line numbers in *this* diff. Carrying one across a file
  // change would hand Swift a range that points into a document nobody is
  // looking at any more.
  component.setSelectedLines(null, { notify: false })

  send({ type: 'rendered', lines: metadata.hunks?.length ?? 0 })
}

// MARK: - One commit

function renderChangeset(raw: string): void {
  const payload = parse<ChangesetPayload>(raw, 'changeset')
  if (payload == null) return

  appearance = payload.appearance
  activate('changeset')

  changeset ??= new ChangesetView(changesetRoot!, send)
  changeset.render(payload)
}

function setChangesetCollapsed(collapsed: boolean): void {
  changeset?.setAllCollapsed(collapsed)
}

function scrollToChangesetFile(id: string): void {
  changeset?.scrollToFile(id)
}

// MARK: - One conflict

/// `UnresolvedFile` is the library's own: it parses the conflict markers, draws
/// each region with Accept Current / Incoming / Both buttons, and hands back the
/// **whole resolved file** when one is taken. Swift writes that to disk — the
/// page never touches the filesystem and never decides what "resolved" means.
function renderConflict(raw: string): void {
  const payload = parse<ConflictPayload>(raw, 'conflict')
  if (payload == null) return

  appearance = payload.appearance
  applyChrome(payload.appearance)
  activate('conflict')

  const options = {
    disableFileHeader: true,
    diffIndicators: 'classic' as const,
    hunkSeparators: 'line-info' as const,
    overflow: 'scroll' as const,
    themeType: payload.appearance.themeType,
    theme: DIFF_THEMES,
    unsafeCSS: SHADOW_CSS,
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

  send({ type: 'rendered', lines: 0 })
}

// MARK: - Appearance

/// A light/dark flip, applied without rebuilding any document. Rebuilding one
/// would throw away the scroll position at the exact moment the window is
/// already changing under the reader.
function setAppearance(raw: string): void {
  const next = parse<GroveAppearance>(raw, 'appearance')
  if (next == null) return

  appearance = next
  applyChrome(next)
  component?.setThemeType(next.themeType)
  conflictComponent?.setThemeType(next.themeType)
  changeset?.setAppearance(next)
}

/// Called after a staging operation, so the rows that were just consumed stop
/// looking selected. `notify: false` keeps it from echoing straight back.
function clearSelection(): void {
  component?.setSelectedLines(null, { notify: false })
}

window.grove = {
  render,
  renderChangeset,
  renderConflict,
  setChangesetCollapsed,
  scrollToChangesetFile,
  setAppearance,
  clearSelection,
}

// Swift holds its first payload until this lands: `loadFileURL` is asynchronous
// and evaluating into the page before the module has run does nothing.
send({ type: 'ready' })
