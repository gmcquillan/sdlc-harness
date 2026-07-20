#!/usr/bin/env bash
# Zero / one / many handoff files; non-repo cwd falls back to cwd itself.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../hooks/handoff-pickup.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
OUT=""; RC=0
hook() { # cwd -> sets OUT, RC
  OUT=$(printf '{"cwd":"%s","session_id":"t"}' "$1" | bash "$script" 2>&1)
  RC=$?
}
contains() { # desc needle
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "$2"; then
    echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (got: ${OUT:-<empty>})"; fail=$((fail+1)); fi
}
empty() { # desc
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (expected empty, got: $OUT)"; fail=$((fail+1)); fi
}

repo="$tmp/repo"; mkdir -p "$repo/sub"; git -C "$repo" init -q
hook "$repo"
empty "no handoff files: silent"

touch "$repo/.handoff-2026-07-13-aaaa.md"
hook "$repo"
contains "one file: named"        ".handoff-2026-07-13-aaaa.md"
hook "$repo"
contains "instructs resume"       "sdlc:resume"
hook "$repo/sub"
contains "found from subdir"      ".handoff-2026-07-13-aaaa.md"

touch "$repo/.handoff-2026-07-14-bbbb.md"
hook "$repo"
contains "many: lists first"  ".handoff-2026-07-13-aaaa.md"
contains "many: lists second" ".handoff-2026-07-14-bbbb.md"

plain="$tmp/plain"; mkdir -p "$plain"; touch "$plain/.handoff-2026-07-13-cccc.md"
hook "$plain"
contains "non-repo cwd works" ".handoff-2026-07-13-cccc.md"

# --- worktree scanning ---
wtrepo="$tmp/wtrepo"; mkdir -p "$wtrepo"; git -C "$wtrepo" init -q
git -C "$wtrepo" config user.email t@t; git -C "$wtrepo" config user.name t
git -C "$wtrepo" commit -q --allow-empty -m init
git -C "$wtrepo" worktree add -q "$tmp/wt-a" -b feat-a
touch "$tmp/wt-a/.handoff-2026-07-19-cccc.md"
# launched from the MAIN repo, the hook must still find the worktree's file:
hook "$wtrepo"
contains "finds handoff in linked worktree" ".handoff-2026-07-19-cccc.md"
# launched from INSIDE the worktree, it must still fire:
hook "$tmp/wt-a"
contains "fires from inside worktree"       ".handoff-2026-07-19-cccc.md"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
