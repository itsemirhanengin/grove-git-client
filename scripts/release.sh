#!/bin/zsh
# Build a Release Grove.app and wrap it in the installer disk image.
#
# This script stops at the artefact. Tagging and publishing are deliberately
# left to you — see RELEASE.md — because a release is the one thing here that
# cannot be taken back once it is pushed.
#
#   ./scripts/release.sh            # version from project.yml
#   ./scripts/release.sh 0.1.1      # or state it
source "${0:A:h}/env.sh"

VERSION="${1:-$(grep -m1 'MARKETING_VERSION' "$ROOT/project.yml" | tr -d ' "' | cut -d: -f2)}"
OUT="$ROOT/.build/release"
STAGE="$OUT/stage"
DMG="$OUT/Grove-$VERSION.dmg"
APP_RELEASE="$DERIVED/Build/Products/Release/Grove.app"

command -v create-dmg >/dev/null || {
    echo "create-dmg is missing — brew install create-dmg" >&2
    exit 1
}

echo "=== building Grove $VERSION (Release) ==="
"${0:A:h}/web.sh" || exit 1
xcodegen generate --quiet

set +e
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    build 2>&1 | grep -E '(error|warning):|BUILD (SUCCEEDED|FAILED)|^\*\*'
result=${pipestatus[1]}
set -e
[[ $result -eq 0 ]] || exit $result

# The tag, the disk image name and the app's own About box all have to agree.
# Reading it back out of the built bundle is what catches a project.yml that was
# bumped after the last build, or not bumped at all.
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_RELEASE/Contents/Info.plist")
[[ "$BUILT" == "$VERSION" ]] || {
    echo "version mismatch: bundle says $BUILT, release says $VERSION" >&2
    echo "fix MARKETING_VERSION in project.yml, then run again" >&2
    exit 1
}

"${0:A:h}/branding.sh" "$VERSION"

echo "=== building disk image ==="
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_RELEASE" "$STAGE/Grove.app"

# Icon coordinates are centres, and they must match the artwork drawn by
# DiskImageArt in scripts/Branding.swift — the window is laid out in two places
# that cannot see each other, so they are stated identically in both.
create-dmg \
    --volname "Grove $VERSION" \
    --volicon "$ROOT/.build/branding/Grove.icns" \
    --background "$ROOT/.build/branding/dmg-background.tiff" \
    --window-pos 320 180 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "Grove.app" 180 196 \
    --hide-extension "Grove.app" \
    --app-drop-link 480 196 \
    --no-internet-enable \
    "$DMG" \
    "$STAGE"

rm -rf "$STAGE"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

# ---------------------------------------------------------------------------
# The update feed
#
# Sparkle trusts an update because of the EdDSA signature over this disk image,
# not because of where it was downloaded from — so the signature is made here,
# from the private key in the releaser's Keychain, and it is what turns a DMG on
# a release page into something Grove will install.
# ---------------------------------------------------------------------------
TOOLS="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
UPDATES="$OUT/updates"
APPCAST="$UPDATES/appcast.xml"

ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" \
    "$APP_RELEASE/Contents/Info.plist" 2>/dev/null || true)
FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" \
    "$APP_RELEASE/Contents/Info.plist" 2>/dev/null || true)

[[ -n "$ED_KEY" ]] || {
    echo >&2
    echo "SUPublicEDKey is empty in project.yml, so this build cannot be updated." >&2
    echo "Generate the key pair once — the private half goes to your Keychain:" >&2
    echo >&2
    echo "  $TOOLS/generate_keys" >&2
    echo >&2
    echo "then put the public key it prints into project.yml. See RELEASE.md." >&2
    exit 1
}
[[ -x "$TOOLS/generate_appcast" ]] || {
    echo "Sparkle's tools are missing from $TOOLS" >&2
    echo "they come with the Swift package — build once, then run this again" >&2
    exit 1
}

echo "=== signing the update and writing the appcast ==="
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"

# The published feed is pulled down first and updated in place, so the entries
# for older versions survive. Without this, every release would publish a feed
# containing one item, and anyone whose app is checking a version older than
# that item's minimum would be told there is nothing to update to.
#
# A failure here is expected exactly once — before the first release there is no
# feed to fetch — so it is not fatal, but the difference is printed rather than
# swallowed, because "no feed" and "the feed moved" look identical afterwards.
if curl -fsSL -o "$APPCAST" "$FEED"; then
    echo "updating the published feed ($FEED)"
else
    rm -f "$APPCAST"
    echo "no published feed at $FEED — writing a new one"
fi

# `--maximum-deltas 0`: delta updates would need every intermediate archive kept
# and uploaded alongside the release, which this hand-published flow does not
# do. A missing delta makes Sparkle fall back to the full download, so the only
# thing skipping them costs is bandwidth.
"$TOOLS/generate_appcast" \
    --download-url-prefix "https://github.com/itsemirhanengin/grove-git-client/releases/download/v$VERSION/" \
    --link "https://github.com/itsemirhanengin/grove-git-client" \
    --maximum-deltas 0 \
    "$UPDATES"

# Both ways this goes wrong are quiet, and both are checked on the *outcome*
# rather than the inputs:
#
#   1. Sparkle decides what is newer from CFBundleVersion, so a release that
#      bumped MARKETING_VERSION and forgot CURRENT_PROJECT_VERSION is not a new
#      version as far as the feed is concerned and gets no entry at all. The
#      release would publish a disk image nobody is ever offered.
#   2. `generate_appcast` only *warns* when the private key is missing from the
#      Keychain — on another machine, or after the login keychain was rebuilt —
#      and writes the entry unsigned. That feed publishes fine and then fails at
#      install time on every user's machine, which is the worst place to find out.
python3 - "$APPCAST" "Grove-$VERSION.dmg" <<'PY' || exit 1
import sys, xml.etree.ElementTree as ET

appcast, wanted = sys.argv[1], sys.argv[2]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"

enclosures = [
    element
    for element in ET.parse(appcast).getroot().iter("enclosure")
    if element.get("url", "").rsplit("/", 1)[-1] == wanted
]

if not enclosures:
    sys.exit(
        f"\nthe appcast has no entry for {wanted}.\n"
        "Sparkle orders releases by CFBundleVersion, not by the marketing\n"
        "version — bump CURRENT_PROJECT_VERSION in project.yml and run again."
    )

if not any(element.get(f"{{{sparkle}}}edSignature") for element in enclosures):
    sys.exit(
        f"\n{wanted} is in the appcast but is not signed.\n"
        "generate_appcast only warns when the private key is missing from the\n"
        "Keychain, and an unsigned update is rejected by every install. Import\n"
        "the key with `generate_keys -f <file>` — see RELEASE.md."
    )
PY

echo
echo "built   $DMG"
echo "feed    $APPCAST"
echo "next: RELEASE.md"
