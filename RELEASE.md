# Releasing Grove

A release is one tag, one disk image and one GitHub release page. Everything up
to the artefact is scripted; the publishing steps are typed by hand on purpose,
because they are the only ones that cannot be taken back.

## 1. Set the version

`project.yml` is the single source of it. Bump both keys under the `Grove`
target:

```yaml
MARKETING_VERSION: "0.1.0"     # what people see — the tag matches this
CURRENT_PROJECT_VERSION: "1"   # build number; increment on every published build
```

`scripts/release.sh` reads `MARKETING_VERSION` back out of the *built bundle*
and refuses to continue if it disagrees with the version it was asked for, so a
forgotten bump fails loudly rather than shipping a mislabelled app.

## 2. Build the artefact

```sh
./scripts/test.sh
./scripts/release.sh
```

That produces, in `.build/release/`:

- `Grove-0.1.0.dmg` — Release build, installer window artwork, volume icon
- `Grove-0.1.0.dmg.sha256` — the checksum people can verify against

## 3. Check the disk image by hand

Open it, and look at the window rather than the log:

```sh
open .build/release/Grove-0.1.0.dmg
```

Both icons should sit inside the white card, the arrow should point from Grove
to Applications, and the version under the wordmark should be the one you are
shipping. Then drag Grove across, launch it from Applications, and confirm the
About box shows the same version.

## 4. Tag it

The tag is `v` plus the marketing version. Tag the commit you actually built:

```sh
git tag -a v0.1.0 -m "Grove 0.1.0"
git push origin main
git push origin v0.1.0
```

## 5. Publish the release

```sh
gh release create v0.1.0 \
  --title "Grove 0.1.0" \
  --notes-file .build/release/notes.md \
  ".build/release/Grove-0.1.0.dmg#Grove 0.1.0 (Apple Silicon)" \
  .build/release/Grove-0.1.0.dmg.sha256
```

The `#` suffix is a display label — it is what the download button on the
release page says, and a bare filename there reads like a build artefact rather
than something to click.

Useful variations:

- `--generate-notes` writes the notes from the commits and pull requests since
  the last tag. Good as a starting point, not as the whole page.
- `--prerelease` keeps the release off `releases/latest`, which is what the
  README's download link points at. Use it for anything you do not want a first
  visitor to land on.
- `--draft` publishes nothing until you press the button in the browser. Worth
  it the first time, so you can see the page before anyone else does.

If the tag does not exist yet, `gh release create` will create it from the
current branch — convenient, but it means an untested commit can end up tagged.
Tagging first, as in step 4, keeps the tag pointing at the build you checked.

## What the release notes have to say

Grove is **not notarized** — there is no Apple Developer ID on this project yet
— so every downloader meets Gatekeeper before they meet the app. If the release
page does not tell them what to do, the issue tracker will:

```markdown
## Install

Open the disk image and drag Grove into Applications.

Grove is not yet signed with an Apple Developer ID, so macOS blocks the first
launch. Open Grove once, then go to **System Settings → Privacy & Security**,
scroll to Security, and click **Open Anyway**. Every launch after that is
normal. (Right-click → Open no longer works for unsigned apps.)

Requires macOS 27 on Apple Silicon.

`shasum -a 256 Grove-0.1.0.dmg` should print the value in
`Grove-0.1.0.dmg.sha256`, attached to this release.
```

## When there is a Developer ID

Two things change, and nothing else:

1. `project.yml` — set `CODE_SIGN_IDENTITY` to `Developer ID Application`,
   `DEVELOPMENT_TEAM` to the team id, and `ENABLE_HARDENED_RUNTIME` to `YES`.
   Hardened runtime is required for notarization and it is not free here: Grove
   spawns `git` and `claude`, so it needs the
   `com.apple.security.cs.allow-jit`-adjacent exceptions checked before the
   first notarized build is trusted.
2. `scripts/release.sh` — sign the app, then submit the finished disk image:

   ```sh
   xcrun notarytool submit "$DMG" --keychain-profile Grove --wait
   xcrun stapler staple "$DMG"
   ```

   Stapling matters: without it the first launch needs a working network
   connection to check the notarization ticket.

Then the whole Gatekeeper section above comes out of the README and the release
notes, and installing becomes a double-click.

## Building on CI, later

A macOS runner can do all of this — `macos-latest` has Xcode, and Homebrew has
both `xcodegen` and `create-dmg`. It is not set up here for one reason worth
knowing before you try: signing and notarization need the certificate and an
App Store Connect key in the repository secrets, which is only worth doing once
there is a Developer ID to put there. Until then a local `./scripts/release.sh`
is the whole pipeline.
