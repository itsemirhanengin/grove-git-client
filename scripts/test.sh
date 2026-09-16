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

if [[ ! -d "$ROOT/Fixtures/alpha" ]]; then
    echo "=== fixtures missing — generating ==="
    "$ROOT/scripts/make-fixtures.sh" >/dev/null || { echo "fixture build failed"; exit 1; }
    echo "ok"
fi

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
