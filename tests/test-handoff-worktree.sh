#!/usr/bin/env bash
# The two shell snippets the handoff skill embeds:
#  (1) resolve the MAIN worktree root from anywhere (incl. inside a worktree)
#  (2) idempotently add .handoff-*.md to the shared info/exclude
set -u
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

repo="$tmp/repo"; mkdir -p "$repo"; git -C "$repo" init -q
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" worktree add -q "$tmp/wt" -b feat >/dev/null 2>&1

# (1) main-root resolution, evaluated from INSIDE the worktree
main_root=$(cd "$tmp/wt" && git worktree list --porcelain \
              | awk '/^worktree /{print $2; exit}')
[ "$main_root" = "$repo" ] \
  && ok "main-root resolves to main tree from inside a worktree" \
  || bad "main-root wrong: got '$main_root' want '$repo'"

# (2) idempotent info/exclude append, run TWICE
add_exclude() {
  local excl; excl="$(git -C "$1" rev-parse --path-format=absolute \
    --git-common-dir)/info/exclude"
  grep -qxF '.handoff-*.md' "$excl" 2>/dev/null || echo '.handoff-*.md' >> "$excl"
}
add_exclude "$tmp/wt"; add_exclude "$tmp/wt"
excl="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
n=$(grep -cxF '.handoff-*.md' "$excl")
[ "$n" = "1" ] && ok "info/exclude has exactly one rule after two calls" \
                || bad "info/exclude rule count = $n (want 1)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
