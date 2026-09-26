#!/usr/bin/env bash
# skills/implement/SKILL.md's base-ref override — additive/opt-in, so
# this guards both the new override language AND the unchanged-by-
# default language, the same way tests/test-cleanup-skill.sh guards
# skills/cleanup/SKILL.md.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
f="$here/../skills/implement/SKILL.md"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

want() { # <description> <fixed-string> — assert the string IS present
  if grep -qF -- "$2" "$f"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}

want "step 2 documents the base-ref override flag" \
  '`--base-ref <branch>` override if one was passed at invocation'
want "step 2 stops on a missing override branch" \
  'stop and report exactly like a diverged base'
want "step 2 states default behavior is unchanged" \
  'behavior is unchanged from the paragraph above'
want "step 5 branches from the override tip when given" \
  "branch point is the override branch's tip"
want "step 5 default stays main/master's tip" \
  '`main`/`master`'"'"'s tip, unchanged'
want "step 11 documents the --base flag addition" \
  'add `--base <branch>` to'
want "step 11 references the gh pr create call it modifies" \
  'the `gh pr create` call below'
want "step 11's gh pr create is otherwise unchanged" \
  'gh pr create --title "<issue title>" --body "Closes #<issue>'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
