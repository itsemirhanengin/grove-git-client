#!/bin/zsh
# Format in place, or `fmt.sh lint` to only report.
source "${0:A:h}/env.sh"

cd "$ROOT"

if [[ "${1:-format}" == "lint" ]]; then
    exec xcrun swift-format lint --recursive --strict Sources Packages
fi

xcrun swift-format format --in-place --recursive Sources Packages
echo "formatted."
