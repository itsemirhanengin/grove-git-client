#!/bin/zsh
# Render every image Grove ships: the app icon in the Asset Catalog, the volume
# icon for the mounted disk image, and the installer window's artwork.
#
# The app icon and the SVG mark are committed — a clone has to build without
# running this. Everything the disk image needs is generated, because it carries
# the version number and would otherwise go stale one release after it is right.
source "${0:A:h}/env.sh"

VERSION="${1:-$(grep -m1 'MARKETING_VERSION' "$ROOT/project.yml" | tr -d ' "' | cut -d: -f2)}"
BUILD="$ROOT/.build/branding"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$ROOT/Branding"

swift "${0:A:h}/Branding.swift" "$ROOT" "$VERSION" "$BUILD"

iconutil --convert icns "$BUILD/Grove.iconset" --output "$BUILD/Grove.icns"

# Finder picks the matching representation out of a multi-resolution TIFF; two
# separate PNGs would leave the background soft on every Mac sold since 2012.
tiffutil -cathidpicheck \
    "$BUILD/dmg-background.png" "$BUILD/dmg-background@2x.png" \
    -out "$BUILD/dmg-background.tiff" >/dev/null

echo "branding: $BUILD"
