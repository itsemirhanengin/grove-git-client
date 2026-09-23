import { CodeView, processPatch } from '@pierre/diffs'
import type {
  ChangeTypes,
  CodeViewDiffItem,
  CodeViewOptions,
  FileDiffMetadata,
} from '@pierre/diffs'

import { DIFF_THEMES, SHADOW_CSS, applyChrome, type GroveAppearance } from './theme'

/// Every file a commit touched, in one scroll.
///
/// Built on the library's `CodeView` rather than on a stack of `FileDiff`s, and
/// that is the whole performance story. `CodeView` owns the scroll container and
/// virtualizes **per line**: a ten-thousand-file commit mounts the handful of
/// files the viewport crosses and reserves measured space for the rest, so what
/// it costs to scroll is a function of the window's height rather than of the
/// commit's size. A stack of components would mount all ten thousand.
///
/// What Grove keeps for itself is the file header — see `renderCustomHeader`.
/// Everything else the library draws.

/// What Swift sends to open a commit.
export interface ChangesetPayload {
  /// The whole commit as one patch, straight from `git show`.
  patch: string
  /// The commit's id. Prefixes every item id and every cache key, so two
  /// commits can never be reconciled into each other — which is exactly what
  /// would happen if the first file of each were both called `0`.
  key: string
  diffStyle: 'unified' | 'split'
  generation: number
  appearance: GroveAppearance
}

/// One row of the file list, as Swift needs to know about it.
export interface ChangesetFile {
  id: string
  name: string
  prevName?: string
  changeType: ChangeTypes
  additions: number
  deletions: number
}

type Send = (message: Record<string, unknown>) => void

/// The status word at the head of each file row.
const STATUS_LABEL: Record<ChangeTypes, string> = {
  change: 'modified',
  new: 'added',
  deleted: 'deleted',
  'rename-pure': 'renamed',
  'rename-changed': 'renamed',
}

/// Height of the file header row, in CSS pixels.
///
/// It is a constant in two places at once: this value and `.grove-file`'s
/// `height` in `grove.css`. They must agree — `CodeView` reserves space for a
/// header it has not mounted yet from this number, so a header that turns out
/// taller makes the scrollbar shorten as you scroll past it.
const FILE_HEADER_HEIGHT = 32

export class ChangesetView {
  private view: CodeView | undefined
  private items: CodeViewDiffItem[] = []
  private byId = new Map<string, CodeViewDiffItem>()
  /// Kept so an appearance change can rebuild the options without being handed
  /// the patch a second time.
  private lastPayload: ChangesetPayload | undefined

  constructor(
    private readonly root: HTMLElement,
    private readonly send: Send
  ) {}

  // MARK: Rendering

  render(payload: ChangesetPayload): void {
    applyChrome(payload.appearance)
    this.lastPayload = payload

    // Swift keeps this view mounted while it waits on `git show`, so an empty
    // patch is the ordinary between-commits state rather than a mistake. It
    // empties the list and says so; it does not tear anything down.
    if (payload.patch.trim().length === 0) {
      this.clear()
      this.report()
      return
    }

    let files: FileDiffMetadata[]
    try {
      // `processPatch` and not `parsePatchFiles`: this is one commit, so it is
      // one patch, and the multi-patch form would only add a layer of arrays to
      // unwrap. The cache key prefix is what lets the library reuse highlighted
      // output when the same commit is opened twice.
      files = processPatch(payload.patch, `${payload.key}:${payload.generation}`).files ?? []
    } catch (error) {
      this.send({ type: 'error', message: `could not parse the commit: ${String(error)}` })
      this.clear()
      return
    }

    this.items = files.map((fileDiff, index) => ({
      id: `${payload.key}#${index}`,
      type: 'diff' as const,
      fileDiff,
      collapsed: false,
      version: 0,
    }))
    this.byId = new Map(this.items.map((item) => [item.id, item]))

    const options = this.options(payload)
    if (this.view == null) {
      this.view = new CodeView(options)
      this.view.setup(this.root)
    } else {
      this.view.setOptions(options)
    }

    this.view.setItems(this.items)
    this.report()
  }

  /// A light/dark flip, without re-parsing the patch.
  ///
  /// `themeType` is one of the options each item reads through, so the change
  /// is published by handing `CodeView` a fresh options object; `onThemeChange`
  /// then makes the mounted items re-highlight against the new theme.
  setAppearance(appearance: GroveAppearance): void {
    applyChrome(appearance)
    if (this.lastPayload == null || this.view == null) return

    this.lastPayload = { ...this.lastPayload, appearance }
    this.view.setOptions(this.options(this.lastPayload))
    this.view.onThemeChange()
  }

  /// Expand All / Collapse All.
  ///
  /// Every item's `version` is bumped, because `CodeView` reconciles a
  /// controlled list by id and keeps its existing record whenever the version
  /// matches — a collapsed flag that changed without one would simply not be
  /// noticed.
  setAllCollapsed(collapsed: boolean): void {
    if (this.view == null || this.items.length === 0) return

    this.items = this.items.map((item) =>
      item.collapsed === collapsed
        ? item
        : { ...item, collapsed, version: (item.version ?? 0) + 1 }
    )
    this.byId = new Map(this.items.map((item) => [item.id, item]))
    this.view.setItems(this.items)
    this.report()
  }

  scrollToFile(id: string): void {
    this.view?.scrollTo({ type: 'item', id, align: 'start' })
  }

  clear(): void {
    this.items = []
    this.byId.clear()
    this.view?.setItems([])
  }

  cleanUp(): void {
    this.view?.cleanUp()
    this.view = undefined
    this.items = []
    this.byId.clear()
    this.lastPayload = undefined
  }

  // MARK: Options

  private options(payload: ChangesetPayload): CodeViewOptions<undefined, undefined> {
    // Must match `--diffs-line-height`, which `applyChrome` derives the same
    // way. This is the number every unmounted file's height is estimated from.
    const lineHeight = Math.round(payload.appearance.fontSize * 1.6)

    return {
      theme: DIFF_THEMES,
      themeType: payload.appearance.themeType,
      diffStyle: payload.diffStyle,
      diffIndicators: 'classic',
      hunkSeparators: 'line-info',
      // A diff line is a unit; wrapping it breaks its correspondence with the
      // line number beside it.
      overflow: 'scroll',
      unsafeCSS: SHADOW_CSS,
      // The file name stays put while its own diff scrolls under it — with
      // every file in one column, it is the only thing saying which file the
      // lines on screen belong to.
      stickyHeaders: true,
      // Square and edge to edge, like every other surface in the window. The
      // separation between two files is a hairline drawn by `.grove-file`, not
      // a gap.
      layout: { paddingTop: 0, paddingBottom: 0, gap: 0 },
      itemMetrics: {
        lineHeight,
        diffHeaderHeight: FILE_HEADER_HEIGHT,
        // `applyChrome` zeroes `--diffs-gap-block`, so there is no block
        // padding around a file for these to account for. Left at their
        // defaults they would reserve eight pixels per file that nothing
        // draws, and a thousand files would end the scroll eight thousand
        // pixels early.
        spacing: 0,
        paddingTop: 0,
        paddingBottom: 0,
      },
      // Grove draws the whole header: the disclosure, the status word, the
      // path and the counts. See `fileHeader`.
      //
      // The callback is shared between file and diff items, so its first
      // argument arrives as the union of both. Narrowing on the context rather
      // than on that argument gets the item and its metadata together — and a
      // changeset holds nothing but diffs, so the other branch is unreachable.
      renderCustomHeader: (_fileOrDiff, context) =>
        context.type === 'diff'
          ? this.fileHeader(context.item.fileDiff, context.item)
          : undefined,
      // Hit testing every row while the wheel is moving is the one thing that
      // makes a long scroll feel heavy.
      pointerEventsOnScroll: false,
    }
  }

  // MARK: The file header

  /// One file's header row, drawn by Grove rather than by the library.
  ///
  /// It is a `<button>` because it is the disclosure: clicking anywhere along
  /// the row collapses the file. Nothing else in the row is interactive, so
  /// making the row itself the control is both the largest target and the
  /// honest description of what it does.
  ///
  /// The element lands in a `<slot>`, which means it stays in the light DOM and
  /// `grove.css` styles it like anything else on the page. Only the box the
  /// library wraps it in needs `unsafeCSS`.
  private fileHeader(fileDiff: FileDiffMetadata, item: CodeViewDiffItem): HTMLElement {
    const collapsed = item.collapsed === true

    const row = document.createElement('button')
    row.type = 'button'
    row.className = 'grove-file'
    row.dataset.collapsed = String(collapsed)
    row.dataset.change = fileDiff.type
    row.setAttribute('aria-expanded', String(!collapsed))
    row.title = fileDiff.prevName != null ? `${fileDiff.prevName} → ${fileDiff.name}` : fileDiff.name

    row.append(
      element('span', 'grove-file-chevron'),
      element('span', 'grove-file-status', STATUS_LABEL[fileDiff.type]),
      this.nameElement(fileDiff),
      element('span', 'grove-file-gap'),
      this.countsElement(fileDiff)
    )

    row.addEventListener('click', () => this.toggle(item.id))
    return row
  }

  /// The path, with everything but the file name dimmed.
  ///
  /// A commit's file list is read by scanning the last segment of each path;
  /// giving the directory the same weight as the name is what makes the
  /// existing list hard to scan at all.
  private nameElement(fileDiff: FileDiffMetadata): HTMLElement {
    const name = element('span', 'grove-file-name')

    if (fileDiff.prevName != null) {
      name.append(
        element('span', 'grove-file-prev', fileDiff.prevName),
        element('span', 'grove-file-arrow', '→')
      )
    }

    const slash = fileDiff.name.lastIndexOf('/')
    if (slash >= 0) {
      name.append(element('span', 'grove-file-dir', fileDiff.name.slice(0, slash + 1)))
    }
    name.append(element('span', 'grove-file-base', fileDiff.name.slice(slash + 1)))

    return name
  }

  private countsElement(fileDiff: FileDiffMetadata): HTMLElement {
    const { additions, deletions } = countLines(fileDiff)
    const counts = element('span', 'grove-file-counts')

    if (additions > 0) counts.append(element('span', 'grove-file-added', `+${additions}`))
    if (deletions > 0) counts.append(element('span', 'grove-file-removed', `−${deletions}`))

    return counts
  }

  // MARK: State

  private toggle(id: string): void {
    const item = this.byId.get(id)
    if (item == null || this.view == null) return

    const next: CodeViewDiffItem = {
      ...item,
      collapsed: item.collapsed !== true,
      version: (item.version ?? 0) + 1,
    }

    const index = this.items.findIndex((candidate) => candidate.id === id)
    if (index >= 0) this.items[index] = next
    this.byId.set(id, next)

    this.view.updateItem(next)
    this.report()
  }

  /// Tells Swift what is on screen, so the native header above the diff can
  /// show the file count and flip Expand All to Collapse All.
  private report(): void {
    const files: ChangesetFile[] = this.items.map((item) => {
      const fileDiff = (item as CodeViewDiffItem).fileDiff
      const { additions, deletions } = countLines(fileDiff)
      return {
        id: item.id,
        name: fileDiff.name,
        prevName: fileDiff.prevName,
        changeType: fileDiff.type,
        additions,
        deletions,
      }
    })

    this.send({
      type: 'changeset',
      files,
      collapsedCount: this.items.filter((item) => item.collapsed === true).length,
    })
  }
}

// MARK: - Helpers

function element(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag)
  node.className = className
  if (text != null) node.textContent = text
  return node
}

/// Counted off the parsed hunks rather than off the patch text — the parse has
/// already happened, and these are the numbers it produced.
function countLines(fileDiff: FileDiffMetadata): { additions: number; deletions: number } {
  let additions = 0
  let deletions = 0

  for (const hunk of fileDiff.hunks) {
    additions += hunk.additionLines
    deletions += hunk.deletionLines
  }

  return { additions, deletions }
}
