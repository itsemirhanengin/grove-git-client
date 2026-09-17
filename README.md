<img src="Branding/grove-icon.png" width="104" alt="">

# Grove

A native macOS git client for people who work in several repositories at once.
Sidebar, list, detail — the repository is the top-level item, expanding to
Working Copy, History, Stashes and Branches, with a pinned Overview that shows
every repository's uncommitted work in one place.

Grove shells out to the `git` you already have, so your credential helper, SSH
agent and hooks keep working exactly as they do in the terminal.

- Stage and unstage by file, hunk or line, with rename-aware diffs
- Conflict resolution against the merged file git leaves on disk
- Stashes, an operation log and a recovery window for anything undone
- Commit messages drafted from the staged diff, on-device or through `claude`

## Requirements

macOS 27 or later, on Apple Silicon.

## Install

Download `Grove-0.1.0.dmg` from the [latest release][releases], open it, and
drag Grove into Applications.

Grove is not signed with an Apple Developer ID yet, so the first launch is
blocked. Once, after that never again:

1. Open Grove from Applications. macOS refuses and offers only **Done**.
2. Open **System Settings → Privacy & Security**, scroll to Security, and click
   **Open Anyway** next to the message about Grove.
3. Confirm. Grove opens, and every later launch is ordinary.

The equivalent in one line, if you prefer the terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Grove.app
```

Right-click → Open does *not* work here: macOS stopped accepting it as consent
for unsigned apps.

[releases]: https://github.com/itsemirhanengin/grove-git-client/releases/latest

## Build from source

```sh
./scripts/build.sh          # Debug build
./scripts/run.sh            # build and launch
./scripts/test.sh           # tests, format check and design-system greps
./scripts/release.sh        # Release build wrapped in the installer disk image
```

`xcodegen` and `create-dmg` come from Homebrew; everything else ships with
Xcode. The Xcode project is generated from `project.yml` and is not committed.

## Repository

| Path | What lives there |
| --- | --- |
| `Sources/` | The app, by feature — `Git/` is the only place that knows about `git` |
| `Packages/DiffCore` | Diff parsing and hunk arithmetic, tested in isolation |
| `Web/` | The diff renderer that runs inside a web view in the detail pane |
| `Branding/` | The logo artwork, and the icons `scripts/branding.sh` cuts from it |
| `scripts/` | Everything you run; each one explains itself at the top |

`HANDOFF.md` is the long version: architecture, the decisions that should not be
re-litigated, and what is deliberately left unbuilt. `RELEASE.md` is how a
version gets out the door.
