#!/bin/zsh
# Build the diff renderer that ships inside the app bundle.
#
# Skipped when Web/dist is newer than everything it is built from, because it
# runs on every build.sh and a full Vite pass on unchanged input is pure latency.
# Pass --force to rebuild regardless.
source "${0:A:h}/env.sh"

cd "$ROOT/Web"

# npm's shared cache has been left root-owned on this machine by an older npm,
# which makes installs fail with EACCES. A project-local cache sidesteps it
# without needing sudo.
NPM_CACHE="$ROOT/.build/npm-cache"

if [[ ! -d node_modules ]]; then
    echo "=== installing renderer dependencies ==="
    npm install --cache "$NPM_CACHE" --no-audit --no-fund
    npm rebuild esbuild --cache "$NPM_CACHE" >/dev/null
fi

if [[ "${1:-}" != "--force" && -f DiffRenderer/index.html ]]; then
    newest=$(find src index.html vite.config.ts package.json -type f -newer DiffRenderer/index.html 2>/dev/null | head -1)
    if [[ -z "$newest" ]]; then
        echo "renderer up to date"
        exit 0
    fi
fi

echo "=== building diff renderer ==="
npm run build
