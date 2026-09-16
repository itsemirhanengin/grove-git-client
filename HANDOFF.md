# Grove — Handoff

Native macOS 27 multi-repo git client, SwiftUI. Written for picking the work up
in a fresh session.

**State: phases 0–14 done. Phase 8 (diff viewer) was rebuilt from scratch on
2026-09-16 on a completely different footing — the diff body is a `WKWebView`,
not AppKit. Read "The diff surface" before touching it, and "What went wrong"
before deciding to make it native again. Phase 10 (hunk/line staging) landed the
same day; read "Partial staging" before changing anything about patches.**

---

## Run it

```bash
cd ~/projects/experiments/git-client
./scripts/build.sh          # web renderer + xcodegen + xcodebuild
./scripts/run.sh            # build, launch, bring to front (ctrl-C quits)
./scripts/test.sh           # architecture guards + DiffCore tests + app tests
./scripts/web.sh            # diff renderer only; --force to rebuild regardless
./scripts/fmt.sh            # swift-format in place; `fmt.sh lint` to check
./scripts/make-fixtures.sh            # rebuild the test workspace
./scripts/make-fixtures.sh --with-perf  # + 2,000 dirty files, 50k-line file
```

Everything pins `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
The Xcode project is **generated** from `project.yml` — never edit it, and it is
gitignored.

In Debug the app opens `Fixtures/` automatically (`GROVE_WORKSPACE` overrides
it), so there is always real data on screen.

**`xcodebuild test` runs the tests inside Grove.app**, so every test run
relaunches the app in the owner's face. Do not run the suite casually while they
are looking at the window — say what you are about to do first.

---

## Verified environment

Checked directly, not assumed: macOS 27.0, Xcode 27.0 beta (27A5218g), Swift 6.4,
SDK `MacOSX27.0`, git 2.55.0, `claude` CLI 2.1.273 at `~/.local/bin/claude`,
XcodeGen 2.46.0, node 24.18.0, npm 11.16.0.

Corrections worth keeping:

- There is **no `ToolbarItemPlacement.bottomBar` on macOS** — iOS/watchOS only.
  Bottom bars must be `safeAreaBar(edge:)`, which also insets scroll content.
- `NSColor(name:dynamicProvider:)` **can** resolve Increase Contrast variants
  (`NSAppearanceNameAccessibilityHighContrastAqua` / `…DarkAqua` are real). The
  original plan claimed otherwise and demanded an Asset Catalog; that was wrong,
  and `Sources/DesignSystem/Palette.swift` resolves all four variants in code.
- `copiesOnScroll` has been a no-op since macOS 11. The plan recommended it.
- **npm's shared cache on this machine is partly root-owned** and installs fail
  with `EACCES`. `scripts/web.sh` uses a project-local cache in `.build/npm-cache`
  to sidestep it. Do not "fix" it with sudo.

---

## Phase status

| # | Phase | State |
|---|---|---|
| 0 | Scaffolding, scripts, DiffCore package, window | ✅ |
| 1 | `ProcessRunner`, `GitEnvironment` | ✅ |
| 2 | `StatusParser` (porcelain v2) | ✅ |
| 3 | `RepoDiscovery`, `RepoEngine`, sidebar with real data | ✅ |
| 4 | Design system — palette with contrast tests, glass modifier | ✅ |
| 5 | Window chrome — toolbar glass capsules, `safeAreaBar` | ✅ |
| 6 | Sidebar polish, 300-row display cap, perf gates | ✅ |
| 7 | Working Copy — stage/unstage/discard/commit, backup refs | ✅ |
| 8 | Diff viewer — web renderer, native header, file selection | ✅ |
| 9 | Side-by-side, word diff, syntax highlighting | ✅ — comes from the renderer |
| 10 | Hunk/line staging (`PatchBuilder`) | ✅ — parser is back, see below |
| 11 | FSEvents live refresh | ✅ — see "Live refresh" |
| 12 | Persistence + workspace switcher | ✅ — the morph was dropped, see below |
| 13 | fetch/pull/push, branch switch, merge | ✅ |
| 14 | Conflict resolver | ✅ |
| 15 | History + commit graph | ⬜ |
| 16 | AI commit messages (`claude -p`) | ⬜ |
| 17 | *(absorbed into 9)* | — |
| 18 | Operation log, recovery window, stashes | ⬜ |

**Design polish is deliberately deferred.** The owner will do a visual pass over
everything once the features are in. Do not spend turns on aesthetics unasked.

---

## The diff surface

The diff **body** is a `WKWebView` rendering
[`@pierre/diffs`](https://diffs.com) (Apache-2.0) — the library Pierre uses in
its own git client. Everything around it is real AppKit through SwiftUI.

### Why

Two native renderers failed here, in the same week. See "What went wrong". The
short version: the owner needs a diff that looks right and works, and the
AppKit route had burned several rounds without producing one. This route
produced a correct, syntax-highlighted, word-level diff in a single session.

### Shape

```
Sources/Diff/DiffPane.swift          SwiftUI column — title row, info row, body
Sources/Diff/DiffWebView.swift       DiffWebSurface (the WKWebView + bridge)
                                     + DiffPayload + NSViewRepresentable
Sources/Diff/DiffSchemeHandler.swift serves the bundle over grove-diff://
Web/src/main.ts                      the page: parse, render, theme
Web/src/grove.css                    page chrome only — the library styles itself
Web/index.html                       inline first-paint background
Web/DiffRenderer/                    build output, gitignored, shipped as a
                                     folder reference named DiffRenderer
```

Swift sends a `DiffPayload` (patch text, file name, style, theme, font size,
canvas colour, generation) and the page replies `ready` / `rendered` / `error`
over a `WKScriptMessageHandler` named `grove`.

### Five things that are load-bearing

1. **`grove-diff://`, not `file://`.** The renderer is code-split: the entry is
   464 kB and each syntax grammar is a separate dynamic import. A `file://` page
   has an **opaque origin**, so every one of those imports fails CORS. The custom
   scheme gives the page a real origin while reading only from the app bundle.
   Inlining everything instead produces a 10.7 MB `index.html` that WKWebView
   must parse in full to draw one diff — measured, not guessed.
2. **`containerWrapper`, not `fileContainer`.** The library keeps *all* of its
   styling in a shadow root on its own `<diffs-container>` custom element, under
   `:host` selectors. Passing our own element as `fileContainer` means that
   element is never created, and the diff renders with no grid, no colours and
   no alignment — it looks exactly like a stylesheet failed to load. Pass the
   **parent** as `containerWrapper` and let it create its own container.
3. **`--diffs-*` custom properties drive the theme.** They are declared on
   `:host`, and custom properties inherit *through* a shadow boundary, so setting
   them on `document.documentElement` is enough — never reach into the shadow DOM.
   `applyChrome()` in `main.ts` maps Grove's canvas, font size and line height.
4. **The patch is passed as a `callAsyncJavaScript` argument**, never
   interpolated into script text. A diff is file contents, i.e. untrusted input;
   a file containing `</script>` would otherwise break out. There is a (disabled)
   test for exactly this.
5. **Two layers stop the white flash.** `webView.underPageBackgroundColor` covers
   what WebKit paints before the page does; an inline `<style>` in `index.html`
   with `light-dark()` covers the moment before the stylesheet arrives. Either
   one alone still flashes.

### Layout

`safeAreaBar(edge: .top, spacing: 0)` carries a 26 pt title row (status-tinted
icon, file name, dimmed directory, Staged/Unstaged switch) over one dense
information line (*Modified · 1 chunk · +2 −1*). Then the diff fills the rest.
No footer: context width and unified/split are fixed constants in `DiffPane`
and belong in Settings, which is where the owner wants them.

`spacing: 0` on that bar matters — the default leaves a visible gap under the
toolbar.

**The scope bar (All/Changed/Conflicts/Ahead) is not in `.accessoryBar`.** An
accessory bar spans the whole window, so it put 32 pt of empty strip above the
file name in the detail column, for a control that column does not own. It now
sits on the list column, which is what it filters.

The information line (chunk and ±counts) is **counted from the patch text** with
`hasPrefix`, not parsed. It is a running total; anything that needs real
structure is the renderer's job.

---

## Known gap — the rendering tests are disabled

`Tests/GroveTests/DiffRenderingTests.swift` mounts the real `DiffWebSurface`,
sends a patch and counts non-canvas pixels. **It does not run**: `WKWebView`
never finishes loading inside the xcodebuild test host, which logs
`RBS assertion … com.apple.runningboard.assertions.webkit` and never brings up a
WebContent process. Ordering the window in off-screen did not help.

Only `"the renderer ships inside the app bundle"` is live.

This matters more than a normal skipped test: **it is the only automated check
that the diff is actually drawn**, and its absence is precisely how the previous
renderer shipped blank twice. Worth a session. Likely leads: a test host with the
WebKit entitlements, an XCTest UI-test target instead of a unit target, or
driving the page in `safari`/`node` against the built `Web/DiffRenderer`.

Counts as of this handoff: **30 DiffCore tests + 170 app tests**, 3 of the app
tests disabled as above. Recount after any change.

---

## Partial staging — phase 10

`Packages/DiffCore` holds `DiffLine.swift` (a 16-byte POD), plus the parser and
the patch synthesiser phase 10 needed:

```
UnifiedPatch.swift   PatchLine / PatchHunk / PatchFile + UnifiedPatchParser
PatchBuilder.swift   PatchSelection, PatchApplication, PatchBuilder
```

The old `UnifiedDiffParser`, `DiffModel` and `RowLayout` were deleted with the
native renderer and are not recoverable — they were never committed. What came
back is scoped to one job: turning a *subset* of a diff into a patch `git apply`
accepts. `RepoEngine.diff(for:staged:contextLines:)` still hands the renderer
git's own output verbatim; nothing re-derives it.

### Five things that are load-bearing

1. **Hunk bodies are consumed by counting from the `@@` header**, never by
   sniffing line prefixes. A diff of a diff contains context lines that begin
   `diff --git` and `@@`; a prefix-sniffing parser loses sync there for the rest
   of the file. `git apply` counts, so counting is what makes patches apply.
2. **Lines are split on the newline *byte*.** In Swift `"\r\n"` is a single
   extended grapheme cluster, so `split(separator: "\n")` finds **no separator
   at all** inside a CRLF file — the whole diff comes back as one line and every
   hunk after the first is silently lost. `UnifiedPatchParser.splitLines` walks
   `String.UTF8View`. The same trap bites tests: `contains("+BETA\r")` never
   matches CRLF text; write `"+BETA\r\n"`.
3. **The forward and reverse transforms are mirror images**, and which one to
   use is decided by *which side has to match the file*, not by the operation's
   name:

   ```text
   FORWARD  (git apply)     ' ' → ' '   '+' in S → '+'   '+' not in S → DROP
                                        '-' in S → '-'   '-' not in S → ' '

   REVERSE  (git apply -R)  ' ' → ' '   '-' in S → '-'   '-' not in S → DROP
                                        '+' in S → '+'   '+' not in S → ' '
   ```

   | operation | diff source | application | target |
   |---|---|---|---|
   | stage | `git diff` | forward | `--cached` |
   | unstage | `git diff --cached` | reverse | `--cached -R` |
   | discard | `git diff` | **reverse** | worktree, `-R` |

   Discard is a *reverse* application of the same diff staging applies forwards.
   An earlier draft of this document said discard "uses the same body with -R";
   that is only true when the whole chunk is selected, where the two transforms
   coincide. For a partial selection it is wrong, and the failure mode is a
   silently wrong working tree.
4. **Only one side's hunk header survives verbatim** — the side git has to match.
   The produced side's start is re-derived from the hunks actually emitted, with
   a running offset, so dropping an earlier chunk un-shifts the ones after it. A
   zero-length side's start is the line *before* the change (`@@ -0,0 +1 @@`),
   which needs its own ±1.
5. **A line owning `\ No newline at end of file` is non-splittable.** Turning it
   into context asserts both sides end without a newline there, which is exactly
   what the marker says is untrue. `PatchBuilder` throws
   `.noNewlineNotSplittable` rather than synthesise it. Dropping such a line is
   fine; only *demoting* one is refused. A partial selection may also not
   contradict a whole-file create or delete (`.wholeFileOnly`).

### Applying

`RepoEngine.applyPartial(diff:selection:operation:)` runs **`git apply --check`
before every apply**, always. A subtly wrong patch does not fail cleanly — git
applies the hunks it can and rejects the rest, leaving an index that looks fine
and commits something nobody wrote. A discard takes a backup ref first, like
every other destructive operation.

The `diff` passed in is **the exact text the user was looking at**, never a
freshly fetched one. A selection is line numbers, and line numbers mean
something only against the diff they were made in. Note that a working-tree edit
does *not* invalidate a staging selection — `git apply --cached` reads the patch
and the index — but it does invalidate a discard, which is what `--check`
catches.

### The UI

The page reports selections and does nothing else with them:
`enableLineSelection: true` plus `onLineSelected`, over the existing `grove`
message handler. `DiffRowRange.resolve(in:)` matches the reported
`(line number, side)` anchors against `PatchHunk.lines`, which is already in
render order because it *is* the unified diff's order.

Everything the user presses is real AppKit: a `safeAreaBar(edge: .bottom)` in
`DiffPane` that exists only while rows are picked, offering Stage/Unstage Lines,
Stage/Unstage Chunk, and Discard.

The page's one visible control is `enableGutterUtility` — the small button that
appears in the **line-number column** on hover. It exists purely for
discoverability: nothing else on screen said line staging was possible until you
had already tried dragging. The library draws and styles it, and it is **not**
deprecated. Two things about it:

- `enableGutterUtility` alone is inert. The drag it starts is gated on
  `onGutterUtilityClick` being present, so Grove passes an empty one.
- That callback is empty on purpose. The range it produces is *also* committed
  through `onLineSelected` on the same pointer-up, so reporting from both would
  hand Swift the same selection twice.

**Per-hunk buttons injected into the page were not built.** `@pierre/diffs` only
exposes row injection through `lineAnnotations` (which render *below* a line,
not at the hunk header) or through the `hunkSeparators` *function*, which the
library marks deprecated. Neither was worth a deprecated dependency for a
control the native bar already provides — but if the owner wants GitHub-style
per-chunk buttons, `hunkSeparators` is where they go.

Untracked files offer no line discard: git has no record of them, so a backup
ref cannot help and the whole file goes to the Trash instead.

`RepoOperationAlerts` moved the discard confirmation, the receipt and the
failure alert out of `WorkingCopyPane` and onto the window root. A discard can
now be asked for from two panes, and those two are not both mounted for every
sidebar section — the sheet was waiting on a view that did not exist.

## Live refresh — phase 11

`Sources/Git/RepoWatcher.swift`. **One** FSEvents stream over the whole
workspace, not one per repository: FSEvents folds overlapping paths together,
and ten streams would mean ten wake-ups for one `git checkout`. `AppModel` starts
it after discovery and hands each changed repository a `refresh()`.

### The trap that cost the afternoon

`URL.resolvingSymlinksInPath()` resolves symlinks **and then strips a leading
`/private`**. FSEvents reports the opposite — `/private/var/folders/…`. A root
normalised with `resolvingSymlinksInPath()` therefore matches **no event at
all**, and nothing anywhere reports an error: the stream runs, events arrive, and
every one of them is attributed to no repository. `WatchedRepository` uses
`realpath(3)` instead.

### What gets through

The filter is `RepoEventFilter`, a pure function over paths so it can be tested
as one — the stream itself cannot be tested without a filesystem race.

- Anything ending `.lock` is dropped first. `index.lock` alone appears and
  vanishes several times per git command and is the noisiest thing on the disk.
- Inside the repository's `gitPath`, an **allow-list**: `HEAD`, `index`,
  `packed-refs`, `ORIG_HEAD`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`,
  `BISECT_LOG`, anything under `refs/`, and `rebase-merge` / `rebase-apply`.
  A deny-list would have to keep up with git's own bookkeeping — objects, logs,
  `FETCH_HEAD`, `COMMIT_EDITMSG` — and would lose.
- `refs/grove/` is excluded: Grove writes those itself, during an operation that
  already refreshes.
- In the working tree, everything **except** paths under a `.git` that is not
  this repository's — those belong to a nested repository or to a linked
  worktree's pointer file.
- Attribution is **longest prefix wins**, `.git` paths before roots. Repositories
  nest: a submodule's root is inside its parent's, and its git directory is under
  the parent's `.git/modules/`.

`kFSEventStreamCreateFlagFileEvents` is what makes any of this possible —
without it FSEvents reports the *directory*, and `.git` changing says nothing
about whether it was `index` or `index.lock`.

### A test that has to ignore its own setup

`kFSEventStreamEventIdSinceNow` with `NoDefer` still delivers the tail of the
directory the test just created, and under a loaded machine that lands *during*
the arming sleep. `RepoWatcherTests` therefore clears what it collected after
arming and before writing anything — otherwise its quiet half asserts against an
event nobody wrote, passing alone and failing in a full parallel run.

### Timing

FSEvents latency 0.2 s, then a 300 ms debounce, **capped at 2 s**. The cap is
not optional: a running build never leaves 300 ms of quiet, so a pure debounce
would hold the refresh back for as long as the build ran.

Teardown is stop → invalidate → release, then a `queue.sync {}` drain. Do
**not** call `FSEventStreamSetDispatchQueue(…, nil)` first: that unschedules the
stream, and invalidating an unscheduled stream trips a client assertion inside
FSEvents — *"Must call FSEventStreamScheduleWithRunLoop() before calling
FSEventStreamInvalidate()"*, logged rather than crashed, so it is easy to ship.
The drain on the serial queue is what actually guarantees no callback is still
running, which is what makes the unretained `info` pointer safe.

The C callback is a free `nonisolated func`. This module defaults to `MainActor`
isolation, and an isolated function cannot be converted to a C function pointer
at all.

---

## Persistence and the switcher — phase 12

`Sources/Persistence/AppStateStore.swift` — a JSON file at
`~/Library/Application Support/Grove/state.json`, not `UserDefaults`. This is a
developer tool; state you can open, read and delete beats state `cfprefsd`
caches somewhere on your behalf.

What is remembered: the recent workspaces (capped at 8), and per workspace the
**collapsed** repositories and the sidebar selection. What is deliberately not:
the scope filter — restoring a workspace into a non-default scope opens to a
list that hides most of it, with nothing on screen explaining why.

- Repository keys are paths **relative to the workspace root**, so moving or
  re-cloning the whole folder keeps the state. `Repository.relativePath(from:)`
  exists for this.
- **Collapsed**, not expanded: a repository that appears in the workspace later
  should arrive open like every other one, not silently shut.
- Reading never throws and never reports. A missing file is a first launch, and
  a corrupt one must not be why the app will not open. A file whose `version` is
  from the future is discarded rather than half-read.
- Writes are debounced by 1 s and flushed synchronously on
  `NSApplication.willTerminateNotification`. The file is a couple of kilobytes;
  the alternative on the way out of the process is losing it.

**The collapsed set is applied inside `discover()`, while the view models are
being built — never in a pass afterwards.** A later pass changes the sidebar's
row count during an update AppKit is still applying, which is the reentrancy the
whole expansion design exists to avoid.

Launch order for which workspace opens: `GROVE_WORKSPACE`, then the most recent,
then the Debug-only `Fixtures/` fallback.

### The switcher

`Sources/Sidebar/WorkspaceSwitcher.swift`. A pill at the top of the sidebar and
a dropdown that **floats over** the list.

**The matched-geometry morph is gone.** It shipped on 2026-09-16 and the owner
replaced it the same day: he wanted the panel to cover the list rather than push
it down, and a far quieter animation. Both of those remove the reason the morph
existed, so `appGlassMorph` and the `GlassEffectContainer` went with it, and
`Motion.morph` now has no caller. Do not put it back without asking — decision 5
below used to name this as the one place `.matchedGeometry` was allowed, and
that is now "nowhere".

- The dropdown is an **overlay in the same window**, not a `.popover`. A popover
  is a separate window with its own arrow and chrome; this needs to read as part
  of the sidebar.
- `SidebarColumn` is a `ZStack`: the list takes a `safeAreaInset` of
  `WorkspaceSwitcher.barHeight` for the pill, and the dropdown covers whatever
  is below it. A transparent layer under the switcher dismisses it on a click
  anywhere else, and `onExitCommand` handles Escape.
- The transition is opacity plus a 0.97 scale from the top edge, on
  `Motion.standard`. Enough to say where it came from, not enough to watch.
- No ⌘O on the panel's "Open Workspace…": the toolbar already owns that
  shortcut, and two views claiming one is undefined rather than redundant.

### Opening a diff from the Overview

The Overview shows every repository at once, and the sidebar points at none of
them — so `DetailColumn` had no repository to resolve and clicking a file there
did nothing at all. `WorkspaceModel.focusedRepoID` records which repository the
last clicked row belonged to, and `select(_:staged:in:)` clears every other
repository's selection on the way through: two highlighted rows, only one of
which is showing, is worse than no highlight.

Both the Overview and the Working Copy list route selection through that one
method, so a file opened in either place is the same kind of event. The Overview
stays a reading surface otherwise — no stage or discard buttons there, because
those belong next to the commit composer where the consequence is visible.

---

## Remotes and branches — phase 13

`RepoEngine`: `fetch`, `pull(_:)`, `push(setUpstream:)`, `switchTo(_:)`,
`createBranch(named:from:checkout:)`, `merge(_:)`, `abort(_:)`.

### The three that could hurt

1. **There is no force push, of any kind** — not even `--force-with-lease`.
   Overwriting a remote branch is the one git operation that can destroy someone
   else's work as well as your own, and it needs its own deliberate action
   rather than a flag on `push`.
2. **`pull` has no "just pull".** `git pull` with no strategy takes one from
   config, and where that is unset it invents a merge commit nobody asked for.
   The default here is `--ff-only`; when git refuses, `GitError.notFastForward`
   comes back and the alert offers *Pull and Merge* or *Pull and Rebase* as
   named choices. The refusal is the feature.
3. **`git switch`, never `git checkout`.** `checkout` will detach HEAD at a ref
   that turns out not to be a branch, and a client that does that by accident
   loses the user's commits.

Other things that are load-bearing:

- `push(setUpstream:)` is decided by the caller, not sniffed. "Where does this
  branch live" is a choice, and guessing it is how a private branch lands on a
  shared remote. The button says **Publish** rather than Push when there is no
  upstream, because it is a different act.
- Switching to a *remote* branch tries `switch --track origin/x` and falls back
  to plain `switch x` when the local branch already exists — which is what was
  meant anyway.
- A merge conflict comes back as `MergeOutcome.conflicted`, **not** an error. It
  is a legitimate state the user now has to finish; reporting it as a failure
  invites the UI to roll it back.
- `--no-edit` on merge and on `pull --no-rebase`: without it git opens an editor
  for the merge message, and there is no terminal here for it to open in.
- `pull` and `merge` take a backup ref first, like every other operation that
  rewrites the working tree. On a clean tree that costs nothing — `git stash
  create` returns empty and no ref is written.
- Network operations get a 300 s timeout. A fetch over a slow link is not a hang.

### Where the buttons are

`RepoActionBar` sits over the **list** column, and only when the sidebar points
at a repository. The window toolbar stays workspace-scoped (open a folder,
refresh everything): a network button whose target silently changes with the
sidebar selection is how a client pushes the wrong branch. Pull is a `Menu` with
a primary action — click to fast-forward, hold for the two reconciliations.

`BranchesPane` fills the Branches section: local and remote, current marked,
double-click or hover to switch, context menu to merge into the current branch.
It reloads on `status.headOID` rather than `loadBranchesIfNeeded`, because
ahead/behind and the current marker are stale the moment anything touches HEAD.

**Not in this phase:** deleting branches, renaming them, and force-pushing.

---

## Conflict resolution — phase 14

`@pierre/diffs` ships the resolver: `UnresolvedFile` parses the conflict markers,
draws Accept Current / Incoming / Both in the gutter of each region, and hands
back the **whole resolved file** through `onMergeConflictResolve`. Grove writes
that to disk and stages it. Nothing here re-derives where a conflict region
starts — that is the one thing the library has already done.

`ConflictPane` replaces `DiffPane` whenever the selected change is conflicted. A
conflicted file is not a diff: it has no staged/unstaged side to switch between
and no lines to stage, it has three versions and a decision.

### What is load-bearing

- **The file is read from the working tree**, markers and all — not reassembled
  from the three index stages. What git wrote is what the user sees in their
  editor, and showing a different reconstruction of it is lying about the thing
  they are being asked to resolve. A test asserts it is byte-identical to disk.
- **Staging is what settles a conflict.** The markers being gone is not enough;
  `applyResolution` and `resolve(_:using:)` both `git add` in the same breath. A
  merge commit with an unstaged "resolution" is how one gets silently lost.
- **Taking *ours* can look like nothing happened.** The file comes back
  identical to HEAD, so it appears in no status list at all — it is not staged,
  not modified, not conflicted. The invariant that actually holds for both sides
  is `git ls-files --unmerged` coming back empty, and that is what the tests
  assert.
- **Mark Resolved is disabled while `<<<<<<<` is still in the file.** Committing
  conflict markers is the most common way a merge goes wrong and is trivially
  detectable.
- **A partly-resolved file is written but not staged.** A file with several
  conflict regions fires `onMergeConflictResolve` once *per region*, each time
  with the whole file. Staging on the first one settles the conflict in the
  index **around the remaining markers** — which is precisely how markers end up
  in a commit. `applyResolution` stages only when `containsConflictMarkers` says
  there is nothing left, and returns whether it did.
- **`UnresolvedFile` parses a file exactly once.** Rendering it again with
  different contents throws *"uncontrolled unresolved files parse the file only
  once. Later updates must come from the cached diff state."* Two consequences,
  both load-bearing:
  - `main.ts` keys the live component by file **and generation**, and builds a
    **new** one when that key changes rather than calling `render` twice.
  - `ConflictPane` keeps what the page hands back in a separate `resolved`
    property and never writes it into `contents`. Writing it there would change
    the payload, re-render the page, and hand the component a second parse of a
    document it already owns.
- **`selectedChange` is reconciled on every refresh.** It holds a snapshot, and a
  resolved file's snapshot still reports `isConflicted` forever — which left the
  resolver on screen over a file that no longer had a conflict.
- A **binary** conflict throws `GitError.binaryConflict` rather than showing
  mangled text. Taking one side whole still works — it is the only resolution a
  binary has.
- `continueMerge` is `git commit --no-edit`, which keeps the message git already
  wrote in `MERGE_MSG`. No `--no-verify`: a merge is exactly when a pre-commit
  hook is worth listening to.

### One web surface, two documents

`DiffWebView` now takes a `DiffWebContent` — `.diff` or `.conflict` — instead of
a bare payload, and `main.ts` gained `window.grove.renderConflict`. One
`WKWebView`, because a second would mean a second renderer load and a second
464 kB parse for a pane the user only ever sees one of. The two components tear
each other down on switch: both create their own `<diffs-container>`, and
leaving the other mounted stacks two files on top of each other.

---

## What is solid

### Git layer — `Sources/Git/`

- `ProcessRunner` is the **only** place a process is spawned;
  `scripts/test.sh` fails the build otherwise. Drains stdout and stderr
  concurrently (sequential draining deadlocks on any real diff), resumes its
  continuation only after both EOFs *and* termination, escalates SIGTERM →
  SIGKILL, and **disarms SIGPIPE** — writing to a child that exited without
  reading stdin otherwise kills the app, which is routine when `git apply`
  rejects a patch.
- `GitEnvironment` resolves the login-shell `PATH` (GUI apps inherit launchd's
  minimal one, which breaks credential helpers) and sets `GIT_TERMINAL_PROMPT=0`,
  `GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C` on every call.
- `StatusParser` walks NUL records with an index because **a rename consumes two
  records**; advancing by one loses sync for the rest of the output.
- `RepoEngine` is an actor per repository: operations on one repo serialise, and
  different repos run in parallel under a shared `GitTaskLimiter`.
- `diff()` handles two cases git does not: an **untracked** file has nothing in
  the index, so it goes through `--no-index` against `/dev/null` and **exits 1 by
  design**; a **rename** must be diffed against its original path too or git
  reports an empty diff for the new name.

### Safety net (phase 7) — do not weaken

- Every destructive operation first runs `git stash create` and anchors the
  result under `refs/grove/backup/<epoch>`. That snapshots worktree *and* index
  without touching either, and is invisible to `git branch`/`git stash list`.
  Recovery is `git stash apply <ref>`.
- Untracked files go to the **Trash**, never `git clean` — git has no record of
  them so a backup ref cannot help.
- Discard always confirms, and the sheet names the files and says where they go.
  A **line-level** discard confirms too, with the line count and the same
  snapshot promise — there is no threshold below which destroying uncommitted
  work stops needing to be asked about.
- Staged rows offer no discard; unstage is the reversible step. The diff's
  selection bar follows the same rule: Discard appears on the unstaged side only.
- Every synthesised patch goes through `git apply --check` before it is applied.
- No `--no-verify` anywhere. Hooks are never bypassed.
- **Unstage sends both paths of a rename.** Sending only the new path leaves the
  original staged as a deletion, which the next commit would carry out. Staging
  must *not* send the old path — that file no longer exists and `git add` fails.

### Selection

`RepoViewModel.selectedChange` holds the file whose diff is shown, as a
`SelectedChange` (the change plus which side). It lives on the repository rather
than being threaded through the columns as a binding, because three separate
views read it and `@Observable` invalidates only the ones that do.

---

## Decisions that should not be re-litigated

1. Git backend **shells out to the `git` CLI**, never libgit2 — credential
   helpers, SSH agent and hooks must keep working.
2. App is **non-sandboxed**, ad-hoc signed, personal use.
3. **PascalCase.swift** file names — a deliberate exception to the owner's global
   kebab-case rule, confirmed for Swift projects. Web files are kebab-case.
4. Layout follows **Tower**: sidebar / list / detail, with the *repository* as
   the top-level sidebar item expanding to Working Copy · History · Stashes ·
   Branches, plus a pinned Overview for all repos at once.
5. **Glass floats, content sits.** Glass only on chrome hovering over scrolling
   content; never inside a `ForEach`; never on the diff surface. All of it goes
   through `appGlass` in `DesignSystem/Glass.swift`, enforced by a grep in
   `scripts/test.sh`. Nothing uses `.matchedGeometry` any more — the workspace
   switcher did until 2026-09-16; see "The switcher".
6. Red means **removed** and **destructive**, only. Conflicts, warnings and
   errors are amber. Modified is blue. Palette contrast is tested.
7. AI commit messages via `claude -p` (phase 16), with macOS 27's on-device
   `FoundationModels` as a no-login fallback. Both confirmed available.
8. **The diff body is a web view** and the chrome around it is native. Decided
   2026-09-16 after two failed native renderers, with the alternatives costed
   (`NSTableView`, STTextView) — see below. Revisit only with a reason better
   than "native would be nicer".
9. The renderer is **offline**. It reads from the app bundle over a custom
   scheme and makes no network request. A git client has no business fetching
   anything to draw a diff.

---

## Fixtures

`scripts/make-fixtures.sh` generates `Fixtures/` (gitignored — they are git
repos, and nesting them would make git treat them as embedded repos). The script
is the *definition* of what the tests exercise, and verifies itself with 14
checks.

| Fixture | Exercises |
|---|---|
| `alpha` | every status kind at once: `.M`, `R.` rename, `.D`, `M.`, `MM`, `?` |
| `beta` | real remote, 1 commit ahead |
| `gamma` | live merge conflict, `MERGE_HEAD` present, all three stages readable |
| `delta` | no commits at all — `rev-parse HEAD` fails, status says `(initial)` |
| `not-a-repo` | must be skipped by discovery |
| `perf` | 2,000 dirty files, 50k-line file, 100,000-char line, CRLF, no-EOL |

Tests that need fixtures use `.enabled(if:)` and report as **skipped** rather
than passing vacuously when they are missing.

**Using the app dirties them.** A Debug build opens `Fixtures/` on launch, so
staging or discarding anything while trying the UI out leaves the fixtures in a
state the status tests do not expect — they fail with a wrong `staged.count` and
look like a regression in the parser. Re-run `scripts/make-fixtures.sh` before
trusting a failure there.

---

## Measured numbers

Debug unless noted. Budgets in the tests are ~3–4× these.

| | |
|---|---|
| `git status`, 2,003 dirty files (263 KB output) | 10 ms |
| `StatusParser` on that output | 0.65 ms Release · 24.6 ms Debug |
| Workspace discovery (6 repos) | 0.5 ms |
| Palette contrast, worst case | 5.03:1 (Attention / Light) |
| Renderer entry chunk | 464 kB (134 kB gzip) |
| Renderer total, all grammars | 11 MB across ~320 lazy chunks |

Performance budgets are **configuration-aware** — the Debug/Release spread is
38× for byte-crunching code, so a single threshold either fails constantly or
catches nothing.

The diff viewer has **no frame-budget target**. The owner opens 1–2K line files.

---

## What went wrong, so it is not repeated

Two native renderers were built and both shipped blank.

**First: Core Text by hand.** The plan set a target of 50,000 lines at 120 fps,
so a custom `NSView` drew glyphs with a hand-rolled ASCII fast path. It hit
0.9 ms a frame and cost three rounds of visible bugs, because selection, copy,
find and accessibility all had to be written by hand too.

**Second: `NSTextView` + TextKit 2.** The text was laid out but never painted.
Diagnosing it properly took building a bisection harness that mounted the view
in a window and read its pixels back; that harness showed a plain `NSTextView`
painting fine and the configured one not, which is where it stopped being worth
chasing. **STTextView exists precisely because "NSTextView + TextKit 2 contains
numerous unresolved bugs"** — the bog was known, and a search would have found
that on day one.

The lessons, in the order they cost time:

1. **Search for an existing package before building the thing.** Both failures
   were solved-problem territory. The owner asked for this explicitly, twice.
2. **Discuss before coding.** When a first attempt fails, come back with options
   and a recommendation — not another rewrite. The owner wants to be in that
   conversation and gets angry when they are handed guesses to screenshot.
3. **Follow the exact source the owner names.** They said diffs.com; that was
   substituted with an assumption about diff2html and a turn was lost.
4. **Measure, do not theorise.** Screenshots plus reasoning produced three wrong
   diagnoses in a row. Mounting the view and reading pixels produced the right
   one in one pass. Keep that reflex — but measure to inform the conversation,
   not to justify another solo rewrite.
5. **Do not drive the UI with synthetic clicks.** Build, hand the app over, ask
   what they see. And remember `xcodebuild test` relaunches the app.
6. **Nothing is committed until it is committed.** A whole parser with 21 tests
   was lost because it sat untracked while the renderer churned. Commit working
   subsystems even when the feature above them is unfinished.

Alternatives that were costed and not taken, so they need not be re-costed:

- **`NSTableView`** — one row per diff line, frozen gutter column, row views for
  backgrounds. Genuinely viable and fully native; loses character-level
  selection. This is the one to reach for if the web view ever has to go.
- **STTextView** — solves the TextKit 2 bugs but still needs custom work for a
  two-column gutter and full-width line bands, i.e. the same edge of the same
  bog, plus a dependency.

---

## Remaining phases, in order

**Phases 15–18** — history with a commit graph, AI commit messages, then the
operation log and recovery window. Branch deletion, rename and force-push were
left out of phase 13 and have no home yet; a three-way (base / ours / theirs)
view of a conflict was left out of phase 14, which resolves from the merged file
with markers instead.

Also outstanding: **Settings**, which is where context width and unified/split
are meant to live, and where the disabled rendering tests should be revisited.

---

## A trap worth knowing

Anything that changes a `List`'s row count **as async data arrives** can trip
AppKit's reentrant `NSTableView` delegate check — a warning today, an assert in
a future macOS. It cost a round of debugging here. Sidebar section expansion is
therefore driven by a **constant** default, never by repository data, and the
Overview uses `ScrollView` + `LazyVStack` rather than `List` for the same reason.
