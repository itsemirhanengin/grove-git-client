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

echo
echo "built $DMG"
echo "next: RELEASE.md"
