import './grove.css'
import { FileDiff, processFile } from '@pierre/diffs'
import type { FileDiffMetadata } from '@pierre/diffs'

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

interface GroveBridge {
  render(payload: string): void
  setThemeType(themeType: 'light' | 'dark', canvas: string): void
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
let lastPayload: RenderPayload | undefined

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

  send({ type: 'rendered', lines: metadata.hunks?.length ?? 0 })
}

function setThemeType(themeType: 'light' | 'dark', canvas: string): void {
  if (lastPayload) {
    lastPayload.themeType = themeType
    lastPayload.canvas = canvas
    applyChrome(lastPayload)
  }
  component?.setThemeType(themeType)
}

window.grove = { render, setThemeType }

// Swift holds its first payload until this lands: `loadFileURL` is asynchronous
// and evaluating into the page before the module has run does nothing.
send({ type: 'ready' })
