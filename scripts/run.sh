#!/bin/zsh
# Build, then run Grove attached so stdout/stderr land in this terminal.
source "${0:A:h}/env.sh"

"$ROOT/scripts/build.sh" Debug

pkill -f 'Grove.app/Contents/MacOS/Grove' 2>/dev/null || true

echo "--- launching $APP ---"
exec "$APP/Contents/MacOS/Grove"
