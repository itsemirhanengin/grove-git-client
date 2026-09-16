#!/bin/zsh
# Builds Grove's test workspace at Fixtures/.
#
# This script is the *definition* of what Grove's tests exercise. Each repository
# below reproduces a specific situation that breaks naive git clients, so read it
# as a spec rather than as setup noise:
#
#   alpha       every status kind at once, including a rename and a file that is
#               both staged and dirty (which must appear in TWO lists)
#   beta        a real remote, one commit ahead of it
#   beta-remote.git  the bare repo beta pushes to
#   gamma       a merge left mid-conflict, with all three stages present
#   delta       a repository with no commits at all — HEAD does not resolve
#   not-a-repo  a plain directory the scanner must skip
#   perf        (--with-perf) 2,000 dirty files and a 50k-line diff
#
# The fixtures are git repositories, so they are generated rather than committed:
# nesting them inside Grove's own repository would make git treat them as
# embedded repos and silently drop their history.

set -euo pipefail

ROOT="${0:A:h:h}"
FIXTURES="$ROOT/Fixtures"
WITH_PERF=0

[[ "${1:-}" == "--with-perf" ]] && WITH_PERF=1

# Identity is set per-repo so the fixtures are byte-stable regardless of whose
# machine builds them, and so a missing global git config cannot fail the build.
git_init() {
    local dir="$1" branch="$2"
    mkdir -p "$dir"
    git -C "$dir" init -q -b "$branch"
    git -C "$dir" config user.name "Grove Fixtures"
    git -C "$dir" config user.email "fixtures@grove.invalid"
    git -C "$dir" config commit.gpgsign false
}

commit() {
    git -C "$1" add -A
    git -C "$1" commit -q -m "$2"
}

echo "Building fixtures in $FIXTURES"
rm -rf "$FIXTURES"
mkdir -p "$FIXTURES"

# ── alpha ─────────────────────────────────────────────────────────────────────
# Ends dirty on purpose, with one file in every state porcelain v2 can report.
A="$FIXTURES/alpha"
git_init "$A" main
mkdir -p "$A/src/components" "$A/src/static/locales"

echo "# alpha" > "$A/README.md"
cat > "$A/src/components/VenueDetail.js" <<'EOF'
export function VenueDetail({ venue }) {
  return { name: venue.name, capacity: venue.capacity };
}
EOF
cat > "$A/src/components/TicketActionBar.js" <<'EOF'
export function TicketActionBar({ ticket }) {
  return { label: ticket.soldOut ? "Sold out" : "Buy" };
}
EOF
echo "export const legacyHelper = () => null;" > "$A/src/legacy.js"
echo "export const removeMe = () => null;" > "$A/src/remove-me.js"
cat > "$A/src/static/locales/en.json" <<'EOF'
{
  "hello": "Hello",
  "bye": "Goodbye",
  "buy": "Buy ticket"
}
EOF
cat > "$A/src/static/locales/tr.json" <<'EOF'
{
  "hello": "Merhaba",
  "bye": "Güle güle",
  "buy": "Bilet al"
}
EOF
commit "$A" "Initial commit"

echo '// sold-out state' >> "$A/src/components/TicketActionBar.js"
commit "$A" "Show sold-out state in ticket bar"

# → `1 .M` modified in the worktree only
echo '// venue capacity fix' >> "$A/src/components/VenueDetail.js"

# → `2 R.` staged rename; the ORIGINAL path arrives as the NEXT NUL record,
#   which is the detail that makes a naive porcelain-v2 parser lose sync.
git -C "$A" mv src/legacy.js src/helpers.js

# → `1 .D` deleted in the worktree, not staged
rm "$A/src/remove-me.js"

# → `1 M.` staged, worktree clean
printf '%s\n' '{' '  "hello": "Hello",' '  "bye": "Goodbye",' \
    '  "buy": "Buy ticket",' '  "sold_out": "Sold out"' '}' > "$A/src/static/locales/en.json"
git -C "$A" add src/static/locales/en.json

# → `1 MM` staged AND modified again: must show up in BOTH the staged and the
#   unstaged list, which is the case most clients collapse into one.
printf '%s\n' '{' '  "hello": "Merhaba",' '  "bye": "Güle güle",' \
    '  "buy": "Bilet al",' '  "sold_out": "Tükendi"' '}' > "$A/src/static/locales/tr.json"
git -C "$A" add src/static/locales/tr.json
printf '%s\n' '{' '  "hello": "Merhaba",' '  "bye": "Güle güle",' \
    '  "buy": "Bilet al",' '  "sold_out": "Tükendi!"' '}' > "$A/src/static/locales/tr.json"

# → `?` untracked
echo "export const config = { api: 'https://example.invalid' };" > "$A/src/config.js"

# ── beta + beta-remote.git ────────────────────────────────────────────────────
# Gives the tests a real push/pull target and a non-zero ahead count.
R="$FIXTURES/beta-remote.git"
git init -q --bare -b master "$R"

B="$FIXTURES/beta"
git_init "$B" master
echo "console.log('beta v1');" > "$B/index.js"
commit "$B" "Initial commit"
git -C "$B" remote add origin "$R"
git -C "$B" push -q -u origin master

echo "console.log('beta v2');" > "$B/index.js"
commit "$B" "Bump version"          # → `# branch.ab +1 -0`

# ── gamma ─────────────────────────────────────────────────────────────────────
# Left mid-merge so the conflict UI has something real to resolve. Stages 1/2/3
# are all readable via `git show :1:` / `:2:` / `:3:`.
G="$FIXTURES/gamma"
git_init "$G" main
cat > "$G/auth.ts" <<'EOF'
export function createSession() {
  return { source: "server", ttl: 12 };
}
EOF
echo "# gamma" > "$G/notes.md"
commit "$G" "Initial commit"

git -C "$G" switch -q -c feature/web-session
cat > "$G/auth.ts" <<'EOF'
export function createSession() {
  return { source: "web", ttl: 24 };
}
EOF
commit "$G" "Use web session"

git -C "$G" switch -q main
cat > "$G/auth.ts" <<'EOF'
export function createSession() {
  return { source: "server", ttl: 48 };
}
EOF
commit "$G" "Extend server ttl"

# Expected to fail — that is the point. Leaves MERGE_HEAD and a `u UU` record.
git -C "$G" merge --no-edit feature/web-session >/dev/null 2>&1 || true

# ── delta ─────────────────────────────────────────────────────────────────────
# No commits. `rev-parse HEAD` fails and status reports `# branch.oid (initial)`,
# so every code path that diffs against HEAD needs a separate branch.
D="$FIXTURES/delta"
git_init "$D" main
echo "# delta" > "$D/README.md"

# ── not-a-repo ────────────────────────────────────────────────────────────────
mkdir -p "$FIXTURES/not-a-repo"
echo "just a file" > "$FIXTURES/not-a-repo/file.txt"

# ── perf (opt-in) ─────────────────────────────────────────────────────────────
if [[ $WITH_PERF -eq 1 ]]; then
    echo "Building perf fixture (this takes a moment)…"
    P="$FIXTURES/perf"
    git_init "$P" main
    mkdir -p "$P/src"

    # 2,000 tracked files, all of which end up dirty — the sidebar benchmark.
    for i in $(seq 1 2000); do
        printf 'export const value%d = %d;\n' "$i" "$i" > "$P/src/module-$i.ts"
    done

    # A 50,000-line file — the diff renderer benchmark.
    seq 1 50000 | awk '{printf "const line%d = \"value %d\";\n", $1, $1}' > "$P/src/large.ts"

    # A minified-style single very long line — the windowed-shaping case.
    awk 'BEGIN { printf "const m="; for (i=0;i<100000;i++) printf "x"; printf "\n" }' \
        > "$P/src/minified.js"

    # CRLF and a no-trailing-newline file — both must survive patch synthesis.
    printf 'alpha\r\nbeta\r\ngamma\r\n' > "$P/src/crlf.txt"
    printf 'no trailing newline' > "$P/src/no-eol.txt"

    commit "$P" "Initial commit"

    for i in $(seq 1 2000); do
        printf 'export const value%d = %d; // touched\n' "$i" "$i" > "$P/src/module-$i.ts"
    done
    seq 1 50000 | awk '{printf "const line%d = \"changed %d\";\n", $1, $1}' > "$P/src/large.ts"
    printf 'alpha\r\nBETA\r\ngamma\r\n' > "$P/src/crlf.txt"
    printf 'no trailing newline, changed' > "$P/src/no-eol.txt"
fi

# ── verify ────────────────────────────────────────────────────────────────────
# Asserts the shapes the tests depend on, so a broken generator fails here rather
# than as a confusing test failure later.
echo
echo "Verifying…"
fail=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        printf '  ok   %s\n' "$label"
    else
        printf '  FAIL %s (expected to find: %s)\n' "$label" "$expected"
        fail=1
    fi
}

alpha_status=$(git -C "$A" status --porcelain=v2 --branch --untracked-files=all 2>&1)
check "alpha: modified in worktree"  ".M N... 100644 100644 100644" "$alpha_status"
check "alpha: staged rename"         "2 R."                          "$alpha_status"
check "alpha: worktree deletion"     ".D N..."                       "$alpha_status"
check "alpha: staged + dirty (MM)"   "1 MM"                          "$alpha_status"
check "alpha: untracked"             "? src/config.js"               "$alpha_status"

beta_status=$(git -C "$B" status --porcelain=v2 --branch 2>&1)
check "beta: upstream set"           "# branch.upstream origin/master" "$beta_status"
check "beta: one commit ahead"       "# branch.ab +1 -0"               "$beta_status"

gamma_status=$(git -C "$G" status --porcelain=v2 --branch 2>&1)
check "gamma: unmerged path"         "u UU"                            "$gamma_status"
[[ -f "$G/.git/MERGE_HEAD" ]] && echo "  ok   gamma: merge in progress" \
    || { echo "  FAIL gamma: no MERGE_HEAD"; fail=1; }
# NOTE: the braces around ${stage} are required. In zsh, `$stage:auth.ts` parses
# `:a` as the "absolute path" history modifier, so the argument silently becomes
# `:/some/abs/path/1uth.ts` and git reports the blob as missing.
for stage in 1 2 3; do
    git -C "$G" show ":${stage}:auth.ts" >/dev/null 2>&1 \
        && echo "  ok   gamma: stage ${stage} readable" \
        || { echo "  FAIL gamma: stage ${stage} missing"; fail=1; }
done

delta_status=$(git -C "$D" status --porcelain=v2 --branch 2>&1)
check "delta: unborn HEAD"           "# branch.oid (initial)"          "$delta_status"

[[ -d "$FIXTURES/not-a-repo/.git" ]] && { echo "  FAIL not-a-repo is a repo"; fail=1; } \
    || echo "  ok   not-a-repo: no .git"

echo
if [[ $fail -eq 0 ]]; then
    echo "All fixtures verified. ($(du -sh "$FIXTURES" | cut -f1))"
else
    echo "Fixture verification FAILED."
fi
exit $fail
