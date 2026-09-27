#!/usr/bin/env bash
# references/reviewer-dispatch.md — the in-house reviewer-dispatch
# procedure skills/implement/SKILL.md step 7 points at instead of
# inlining superpowers:subagent-driven-development's own dispatch step.
# Modeled on tests/test-implement-baseref.sh's want-only pattern.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
f="$here/../references/reviewer-dispatch.md"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

want() { # <description> <fixed-string> — assert the string IS present
  if grep -qF -- "$2" "$f"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}

want "names dispatch site 1 (initial task review)" \
  "Initial task review"
want "names dispatch site 2 (scoped re-review)" \
  "Scoped re-review"
want "names dispatch site 3 (final whole-branch review)" \
  "Final whole-branch review"
want "defines stalled via ListAgents" \
  '`ListAgents` shows no visible progress'
want "defines stalled via an unanswered status-check nudge" \
  "status-check nudge sent to that subagent goes unanswered"
want "caps stalled attempts at 2 per dispatch site" \
  "Two stalled attempts per dispatch site"
want "forbids a 3rd dispatch at a capped site" \
  "do not dispatch a 3rd subagent for that site"
want "sites 1-2 fallback reports via the ledger" \
  "reviewer-stall-fallback (site: <task-review|re-review round"
want "site 3 fallback reports via the final summary, not the ledger" \
  "note the fallback in the final summary to the human"
want "site 3 fallback uses the broader code-reviewer.md rubric" \
  "a broader rubric than sites 1"
want "site 3 covers Final Review's own scoped re-review, not just the whole-branch review" \
  "its own single scoped re-review of the fix wave"
want "site 3 covers step 9's separate self-review dispatch" \
  "step 9's separate self-review dispatch"
want "late output is always read, findings folded in rather than discarded or blindly deferred to" \
  "Read it. If it raises findings the controller's own review missed"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
