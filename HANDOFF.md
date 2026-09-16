# Grove — Handoff

Native macOS 27 multi-repo git client, SwiftUI. Written for picking the work up
in a fresh session.

**State: phases 0–7 done. Phase 8 (diff viewer) works and is on screen, but it
was rebuilt from scratch on 2026-09-16 on a completely different footing — the
diff body is now a `WKWebView`, not AppKit. Read "The diff surface" before
touching it, and "What went wrong" before deciding to make it native again.**

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
| 10 | Hunk/line staging (`PatchBuilder`) | ⬜ **needs a Swift parser again** |
| 11 | FSEvents live refresh | ⬜ |
| 12 | Persistence + workspace switcher (the glass morph) | ⬜ |
| 13 | fetch/pull/push, branch switch, merge | ⬜ |
| 14 | Conflict resolver | ⬜ |
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

Counts as of this handoff: **6 DiffCore tests + 106 app tests**, 3 of the app
tests disabled as above. Recount after any change.

---

## `Packages/DiffCore` — mostly gone, on purpose

Only `DiffLine.swift` (a 16-byte POD) and its 6 tests survive. The
`UnifiedDiffParser`, `DiffModel` and `RowLayout` were deleted with the native
renderer and **are not recoverable** — they were never committed (`git log
--all`, stash and `git fsck` all come up empty).

That is fine for now: `RepoEngine.diff(for:staged:contextLines:)` returns git's
own `diff --git` output as a `String`, and the renderer parses it.

**Phase 10 needs a parser again** — turning a *subset* of lines into a patch
`git apply` accepts is real work that cannot live in the web layer, because the
patch has to go back to git. Write it then, scoped to that job, rather than
rebuilding the general-purpose one.

What the old parser got right, worth reproducing:

- Consume hunk bodies by **counting** from the `@@` header, never by sniffing
  line prefixes. A diff of a diff contains context lines starting with
  `diff --git` and `@@`; prefix-sniffing parsers lose sync there. `git apply`
  counts, so counting is what makes synthesised patches apply.
- A 100 %-similar rename emits **no `---`/`+++` lines at all** — the paths come
  from `rename from` / `rename to`.
- Verify against **real `git diff` output**, not hand-written fixtures.
  Hand-written ones had wrong hunk counts three times and each looked like a
  parser bug.

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
- Staged rows offer no discard; unstage is the reversible step.
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
   `scripts/test.sh`.
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

**Phase 10** — `PatchBuilder`, and the Swift-side parser it needs. The transform
for a subset of lines is the subtle part, and the forward and reverse cases are
**mirror images**:

```
FORWARD (stage from `git diff`; discard uses the same body with -R):
  ' ' → ' '     '+' in S → '+'     '+' not in S → DROP
                '-' in S → '-'     '-' not in S → ' '

REVERSE (unstage, from `git diff --cached`, applied with -R):
  ' ' → ' '     '-' in S → '-'     '-' not in S → DROP    ← mirrored
                '+' in S → '+'     '+' not in S → ' '     ← mirrored
```

Getting the mirroring backwards yields "patch does not apply" — or worse, a
silently wrong index. Always `git apply --check` first. Copy the file header
**verbatim** from the original diff. Treat a line owning a `\ No newline at end
of file` marker as non-splittable.

The UI for it: `@pierre/diffs` supports line selection and can inject rows into
hunk headers, so Stage/Discard Chunk buttons belong in the page, reported back
over the `grove` message handler. `diffAcceptRejectHunk` in its API is worth
reading first.

**Phase 11** — FSEvents. One stream whose `pathsToWatch` is the repo roots.
Filter *in the callback*: inside `.git/` allow only `HEAD`, `index` (not
`index.lock`), `refs/`, `packed-refs`, `MERGE_HEAD`, `ORIG_HEAD`,
`rebase-merge`, `rebase-apply`. `index.lock` churn is the noisiest source and
must never trigger a refresh.

**Phase 12** — persistence and the workspace switcher. The switcher is the one
place `glassEffectTransition(.matchedGeometry)` is used; it must be anchored in
the sidebar, not a `.popover`, because a popover is a separate window and glass
cannot matched-geometry across one.

**Phases 13–18** — network ops, conflict resolver, history with a commit graph,
AI commit messages, then the operation log and recovery window.

Also outstanding: **Settings**, which is where context width and unified/split
are meant to live, and where the disabled rendering tests should be revisited.

---

## A trap worth knowing

Anything that changes a `List`'s row count **as async data arrives** can trip
AppKit's reentrant `NSTableView` delegate check — a warning today, an assert in
a future macOS. It cost a round of debugging here. Sidebar section expansion is
therefore driven by a **constant** default, never by repository data, and the
Overview uses `ScrollView` + `LazyVStack` rather than `List` for the same reason.
