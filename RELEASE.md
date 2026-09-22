# Releasing Grove

A release is one tag, one disk image, one appcast and one GitHub release page.
Everything up to the artefacts is scripted; the publishing steps are typed by
hand on purpose, because they are the only ones that cannot be taken back.

## 0. Once, ever: the signing key

Grove updates itself through Sparkle, which trusts an update because of an
**EdDSA signature** over the disk image — not because of where it was downloaded
from. That is a signature scheme of Sparkle's own, unrelated to Apple code
signing, which is why self-updating works while Grove is still unsigned.

Generate the key pair once. The private half goes into your login Keychain and
the tool prints the public half:

```sh
.build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

Put what it prints into `project.yml` as `SUPublicEDKey`, and commit that — the
public key is meant to ship inside the app. `scripts/release.sh` refuses to
build a release while it is empty, because an app with no public key cannot
verify an update and Sparkle treats that as fatal.

**Back the private key up before shipping anything.** Losing it means never
being able to publish another update that existing installs will accept: they
only trust signatures from this one key, and an update signed with a new key is
rejected rather than merely distrusted. Export it and put it somewhere durable:

```sh
.build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x grove-eddsa-private.key
# store that file in a password manager, then delete it from disk
```

`generate_keys -p` prints the public key again, and `-f <file>` imports the
private key back into the Keychain on another machine.

## 1. Set the version

`project.yml` is the single source of it. Bump both keys under the `Grove`
target:

```yaml
MARKETING_VERSION: "0.1.0"     # what people see — the tag matches this
CURRENT_PROJECT_VERSION: "1"   # build number; increment on every published build
```

Both, every time. `CURRENT_PROJECT_VERSION` stopped being bookkeeping the moment
Sparkle went in: **it is what Sparkle compares** to decide that one build is
newer than another, and it ignores `MARKETING_VERSION` entirely. A release that
bumps the marketing version and forgets the build number is not a new version as
far as the feed is concerned, and nobody is ever offered it.

`scripts/release.sh` guards both ends of that. It reads `MARKETING_VERSION` back
out of the *built bundle* and refuses to continue if it disagrees with the
version it was asked for, and after writing the feed it checks that the feed
actually gained an entry for this disk image — which is the only way the
forgotten build number shows up before a user fails to get the update.

## 2. Build the artefact

```sh
./scripts/test.sh
./scripts/release.sh
```

That produces, in `.build/release/`:

- `Grove-0.1.0.dmg` — Release build, installer window artwork, volume icon
- `Grove-0.1.0.dmg.sha256` — the checksum people can verify against
- `updates/appcast.xml` — the update feed, with this build signed into it

The feed is built by fetching the currently published one and adding to it, so
older entries survive; before the first release there is nothing to fetch and
the script says so. Signing reads the private key from your Keychain, which
macOS may ask you to allow.

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
  .build/release/Grove-0.1.0.dmg.sha256 \
  .build/release/updates/appcast.xml
```

`appcast.xml` goes on **every** release, and this is not optional bookkeeping:
the app looks for the feed at

```
https://github.com/itsemirhanengin/grove-git-client/releases/latest/download/appcast.xml
```

which GitHub redirects to that asset *on whatever the latest release is*. A
release published without it moves `latest` to a release that has no feed, and
every installed Grove stops finding updates until the next one. The download
URLs inside the feed point at `releases/download/v0.1.0/Grove-0.1.0.dmg`, so the
disk image has to be attached to the release for its own tag, under that name —
which is what `release.sh` produces.

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

## What the update path proves, and what it does not

Verified so far: the Release build embeds `Sparkle.framework`, the disk image
builds, the missing-key guard stops a release that could never be updated, and a
build with an empty key starts with no updater and no menu item rather than
Sparkle's fatal-error alert.

**Not yet verified, because it takes two published releases to see:** that an
installed Grove finds the feed, verifies the signature and replaces itself. Do
that deliberately the first time — publish, install *from the disk image*, then
publish a second build and press **Check for Updates…** in the app menu rather
than trusting that it works.

The open question in that test is Gatekeeper, not Sparkle. Sparkle verifies the
update with its own EdDSA signature, which is independent of Apple code signing
and works fine on an unsigned app — but what macOS does with a freshly installed
*unsigned* bundle on its first launch after an update is the thing to watch. If
it asks for **Open Anyway** again, that is the missing Developer ID, and the fix
is notarization below, not a change to the update channel.

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
