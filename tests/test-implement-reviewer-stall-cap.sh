#!/usr/bin/env bash
# skills/implement/SKILL.md step 7's reviewer-dispatch stall cap — an
# additive override on top of superpowers:subagent-driven-development,
# which the same file invokes. That upstream skill's fix-round cap only
# guards a review that returns findings; it has no cap for a task-reviewer
# dispatch that never returns anything at all. Modeled on
# tests/test-implement-baseref.sh's want-only pattern (nothing here is
# deleted from the file, so no reject() assertions are needed).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
f="$here/../skills/implement/SKILL.md"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

want() { # <description> <fixed-string> — assert the string IS present
  if grep -qF -- "$2" "$f"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}

want "step 7 distinguishes the stall cap from the fix-round cap" \
  'does not cover'
want "step 7 defines stalled operationally via ListAgents" \
  'ListAgents-visible progress'
want "step 7 requires a direct status-check nudge before counting a stall" \
  'status-check nudge'
want "step 7 caps stalled dispatch attempts at 2 per task" \
  '2 per task'
want "step 7 forbids a 3rd task-reviewer dispatch after the cap" \
  'not dispatch a 3rd task-reviewer subagent: perform the task review'
want "step 7 falls back to a direct controller review" \
  'yourself in this session instead'
want "step 7 reports the fallback in the ledger" \
  'reviewer-stall-fallback'
want "red flags names skipping the fallback for a 3rd dispatch" \
  'Dispatching a 3rd task-reviewer subagent after 2 stalled attempts'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
