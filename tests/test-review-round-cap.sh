#!/usr/bin/env bash
# skills/review/SKILL.md — prose-only checklist; this test guards its
# round-cap (issue #38) strings against regressions the same way
# tests/test-epic-skill.sh guards skills/epic/SKILL.md.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
f="$here/../skills/review/SKILL.md"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

want() { # <description> <fixed-string> — assert the string IS present
  if grep -qF -- "$2" "$f"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
reject() { # <description> <fixed-string> — assert the string is NOT present
  if grep -qF -- "$2" "$f"; then bad "$1 (still present: $2)"; else ok "$1"; fi
}

want "round 1 is defined as the initial pass" 'Round 1 is this checklist'"'"'s initial pass'
want "cap value is 3 rounds" 'Cap = 3 rounds'
want "cap-out reports the new stop string" 'stopped:review-round-cap'
want "cap-out posts a plain PR comment" 'gh pr comment <PR#>'
want "cap-out explicitly forbids re-entering step 2" 'do NOT re-enter step 2'
want "cap-out explicitly forbids approve/request-changes" 'never `--approve` or'
want "red flag documents re-entering step 2 past the cap" \
  'Re-entering step 2 after round 3'
reject "old unconditional re-entry phrasing is gone" 'step 2 re-reviews, then'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
