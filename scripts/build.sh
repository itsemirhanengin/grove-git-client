#!/bin/zsh
# Build Grove. Prints only diagnostics and the final status so the output stays
# readable (and greppable) without xcbeautify.
source "${0:A:h}/env.sh"

CONFIG="${1:-Debug}"

cd "$ROOT"
xcodegen generate --quiet

set +e
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    build 2>&1 | grep -E '(error|warning):|BUILD (SUCCEEDED|FAILED)|^\*\*'
result=${pipestatus[1]}
set -e

exit $result
