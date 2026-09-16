#!/bin/zsh
# Build, then run Grove attached so its stdout/stderr land in this terminal.
#
# The app is launched as a child rather than through `open` so logs stay visible,
# but a process started that way is not activated by macOS — the window opens
# behind whatever you were looking at, and it looks like nothing happened. So we
# bring it to the front explicitly once it registers with the window server.
source "${0:A:h}/env.sh"

"$ROOT/scripts/build.sh" Debug

pkill -f 'Grove.app/Contents/MacOS/Grove' 2>/dev/null || true

echo "--- launching Grove (ctrl-C to quit) ---"
"$APP/Contents/MacOS/Grove" &
GROVE_PID=$!

# Stop the app when this script is interrupted, instead of orphaning it.
trap 'kill $GROVE_PID 2>/dev/null; exit 0' INT TERM

(
    for _ in $(seq 1 40); do
        if osascript -e "tell application \"System Events\" to set frontmost of \
            (first process whose unix id is $GROVE_PID) to true" >/dev/null 2>&1; then
            exit 0
        fi
        sleep 0.25
    done
) &

wait $GROVE_PID
