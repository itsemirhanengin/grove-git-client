#!/bin/zsh
# Shared settings for every Grove script. Pinning DEVELOPER_DIR keeps builds
# reproducible while Xcode 27 is still a beta living alongside a stable Xcode.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

ROOT="${0:A:h:h}"
export ROOT
export PROJECT="$ROOT/Grove.xcodeproj"
export SCHEME="Grove"
export DERIVED="$ROOT/.build/dd"
export APP="$DERIVED/Build/Products/Debug/Grove.app"

export DESTINATION='platform=macOS,arch=arm64'
