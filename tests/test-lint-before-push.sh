#!/usr/bin/env bash
# lint-before-push hook: git-push gating, linter auto-detection, and
# deny/allow decisions. Each case builds a throwaway git repo so the
# detection signals (Makefile / package.json / lockfiles) are real.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../hooks/lint-before-push.sh"
pass=0; fail=0
OUT=""; RC=0

run() { # cmd_string repo_dir -> sets OUT, RC (hook runs with cwd=repo_dir)
  OUT=$( (cd "$2" && printf '{"tool_input":{"command":"%s"}}' "$1" \
    | bash "$script") 2>/dev/null )
  RC=$?
}
allow() { # desc  (allow == exit 0 with no stdout)
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}
deny() { # desc
  if printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'; then
    echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}
mkrepo() { local d; d=$(mktemp -d); git -C "$d" init -q; echo "$d"; }

# 1. Not a `git push` → allow (no repo, no linter needed).
tmp0=$(mktemp -d)
run "ls -la" "$tmp0"
allow "non-push command ignored"

# 2. `git push` but no linter detected → allow.
r=$(mkrepo)
run "git push origin master" "$r"
allow "no linter detected -> allow"

# 3. Makefile lint target that FAILS → deny.
r=$(mkrepo); printf 'lint:\n\t@exit 1\n' > "$r/Makefile"
run "git push" "$r"
deny "failing make lint -> deny push"

# 4. Makefile lint target that PASSES → allow.
r=$(mkrepo); printf 'lint:\n\t@exit 0\n' > "$r/Makefile"
run "git push" "$r"
allow "passing make lint -> allow push"

# 5. SDLC_SKIP_LINT bypasses even a failing linter.
r=$(mkrepo); printf 'lint:\n\t@exit 1\n' > "$r/Makefile"
export SDLC_SKIP_LINT=1
run "git push" "$r"
unset SDLC_SKIP_LINT
allow "SDLC_SKIP_LINT bypasses gate"

# 6. package.json with a lint script that fails → deny (npm path).
r=$(mkrepo)
printf '{"scripts":{"lint":"exit 1"}}\n' > "$r/package.json"
run "git push" "$r"
deny "failing npm lint -> deny push"

rm -rf "$tmp0"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
