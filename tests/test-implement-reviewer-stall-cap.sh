#!/usr/bin/env bash
# skills/implement/SKILL.md step 7's reviewer-dispatch override — points
# at references/reviewer-dispatch.md instead of inlining the stall-cap
# procedure. Modeled on tests/test-implement-baseref.sh's want-only
# pattern (nothing here is deleted from the file, so no reject()
# assertions are needed).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
f="$here/../skills/implement/SKILL.md"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

want() { # <description> <fixed-string> — assert the string IS present
  if grep -qF -- "$2" "$f"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}

want "step 7 points at the reviewer-dispatch reference file" \
  'use `../../references/reviewer-dispatch.md` instead'
want "step 7 names all three dispatch sites inline" \
  'initial task review, each scoped re-review, the final'
want "step 7 states which upstream mechanics stay unchanged" \
  'fix-round numbering, model selection, ledger format'
want "red flags points at reviewer-dispatch's own red flags" \
  "reviewer-dispatch.md\`'s own Red Flags"
want "step 9's self-review is in scope of the same override" \
  "step 9's separate self-review dispatch"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
