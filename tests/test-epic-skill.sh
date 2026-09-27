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
want "pick step stops before sdlc:next's own hand-off" \
  "do NOT let it continue into its own"
reject "no direct merge command leaked into the skill" 'gh pr merge'

want "step 5 pre-authorizes Tier A fixes for the unattended subagent" \
  'Tier A fixes are pre-authorized'
want "step 5 still requires Tier B/C to stop, not auto-fix" \
  'Tier B or C still must not be auto-fixed'
want "step 5 gains a round-cap outcome branch" \
  'stopped:review-round-cap` (the round cap was hit'
want "round-cap branch calls set-status with the matching token" \
  'set-status <epic-ref> stopped:review-round-cap'
want "red flag warns against retry-and-continue past a round-cap stop" \
  'Treating a `stopped:review-round-cap` stop as retry-and-continue'
want "step 7's stop list includes round cap alongside the other stops" \
  'Any stop above (done, blocked, Tier B/C, round cap, hop cap)'
want "frontmatter description lists round cap among the stop conditions" \
  'a review round cap'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
