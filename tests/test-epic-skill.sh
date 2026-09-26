#!/usr/bin/env bash
# skills/epic/SKILL.md — prose-only orchestrator; this test guards its
# key checklist strings against regressions the same way
# tests/test-cleanup-skill.sh guards skills/cleanup/SKILL.md.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
f="$here/../skills/epic/SKILL.md"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

want() { # <description> <fixed-string> — assert the string IS present
  if grep -qF -- "$2" "$f"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
reject() { # <description> <fixed-string> — assert the string is NOT present
  if grep -qF -- "$2" "$f"; then bad "$1 (still present: $2)"; else ok "$1"; fi
}

want "never-merge invariant is stated" '`sdlc:epic` never merges anything'
want "hop-cap stop condition is present" 'stopped:hop-cap'
want "tier b/c stop condition is present" 'stopped:review-tier-b-c'
want "build step dispatches the base-ref override" '--base-ref <tip>'
want "exclude-file bootstrap targets the epic state glob" '.sdlc-epic-*.md'
want "resume step verifies the tip branch against git reality" \
  'does the recorded `tip=` branch exist'
want "resume step defers to sdlc:resume for a live handoff file" \
  "do not touch this loop until that ticket's"
reject "no direct merge command leaked into the skill" 'gh pr merge'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
