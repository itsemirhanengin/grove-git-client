#!/bin/zsh
# Unit tests, plus the two architectural guards the plan commits to:
#   1. glassEffect( may only appear in DesignSystem/Glass.swift
#   2. Process( may only appear in Git/ProcessRunner.swift
source "${0:A:h}/env.sh"

cd "$ROOT"

fail=0

echo "=== guard: glassEffect confined to DesignSystem/Glass.swift ==="
offenders=$(grep -rln 'glassEffect(' Sources --include='*.swift' \
    | grep -v 'Sources/DesignSystem/Glass.swift' || true)
if [[ -n "$offenders" ]]; then
    echo "FAIL — glassEffect( outside DesignSystem/Glass.swift:"
    echo "$offenders"
    fail=1
else
    echo "ok"
fi

echo "=== guard: Process( confined to Git/ProcessRunner.swift ==="
offenders=$(grep -rln 'Process(' Sources Packages --include='*.swift' \
    | grep -v 'Sources/Git/ProcessRunner.swift' || true)
if [[ -n "$offenders" ]]; then
    echo "FAIL — Process( outside Git/ProcessRunner.swift:"
    echo "$offenders"
    fail=1
else
    echo "ok"
fi

# Regenerated on **every** run, not just when missing.
#
# A Debug build opens `Fixtures/` on launch, so trying the app out stages a file,
# resolves gamma's conflict, or discards something — and the status tests then
# fail with a wrong count that looks exactly like a parser regression. It cost
# two debugging rounds before this was made unconditional. The fixtures are
# generated and gitignored, so the only thing a rebuild throws away is whatever
# was being poked at in the running app.
echo "=== regenerating fixtures ==="
"$ROOT/scripts/make-fixtures.sh" >/dev/null || { echo "fixture build failed"; exit 1; }
echo "ok"

echo "=== DiffCore package tests ==="
set +e
swift test --package-path Packages/DiffCore 2>&1 | tail -30
[[ ${pipestatus[1]} -ne 0 ]] && fail=1
set -e

echo "=== app tests ==="
xcodegen generate --quiet
set +e
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    test 2>&1 | grep -E '(error|warning):|Test Suite|Executed .* tests|TEST (SUCCEEDED|FAILED)|^\*\*'
[[ ${pipestatus[1]} -ne 0 ]] && fail=1
set -e

exit $fail
