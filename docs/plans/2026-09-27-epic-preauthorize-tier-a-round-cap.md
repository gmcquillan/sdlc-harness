# Pre-authorize Tier A and handle the round-cap stop in sdlc:epic — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `skills/epic/SKILL.md` step 5 safe and complete for its
unattended-subagent use: explicitly pre-authorize Tier A auto-fixes (no
human present to give the go-ahead `sdlc:review` step 6 normally waits
for), and add a third outcome branch — matching the existing Tier B/C
branch's shape — for the `stopped:review-round-cap` outcome that
issue #38 / PR #40 added to `sdlc:review`'s Tier A loop.

**Architecture:** Both changes live entirely in the prose checklist of
`skills/epic/SKILL.md` step 5 and its Red flags section — no new
script logic, mirroring how issue #38 changed `skills/review/SKILL.md`.
The one exception: `bin/sdlc-epicstate.sh`'s `set-status` subcommand
validates its `<status>` argument against a closed whitelist
(`done|stopped:review-tier-b-c|stopped:blocked`) that does **not**
include `stopped:review-round-cap` — confirmed by running it directly
(`sdlc-epicstate.sh set-status <ref> stopped:review-round-cap "..."`
exits 2 today with "status must be done, stopped:review-tier-b-c, or
stopped:blocked"). Issue #39's "Out of scope" note claims "no new
script logic needed — the new token flows through the existing
set-status code path," but that claim doesn't hold against the actual
code: the new branch's `sdlc-epicstate.sh set-status` call would always
fail. This plan makes the minimal, surfaced deviation of adding the one
new token to the existing whitelist (not new arithmetic, not a new
subcommand) so acceptance criterion 2 is actually satisfiable, and
flags it explicitly for human review at the `sdlc:review` stage rather
than silently expanding scope.

**Tech Stack:** Bash (test scripts), Markdown (skill prose). No
compiled code, no package manager, no CI workflow in this repo — each
`tests/test-*.sh` is run directly with `bash`.

**Spec:** GitHub issue #39 (`gh issue view 39`) — no separate spec
file; the issue body is self-contained per `sdlc:implement` step 4.

## Global Constraints

- Scope is `skills/epic/SKILL.md` only, per the issue — except the one
  surfaced, necessary deviation into `bin/sdlc-epicstate.sh`'s
  whitelist described above.
- Tier B/C must still never be auto-fixed inside the unattended
  subagent — only Tier A gets pre-authorized.
- The new outcome branch must match the existing Tier B/C branch's
  shape (a `sdlc-epicstate.sh set-status` call with the ticket ref, PR
  number, and a one-line detail, then a hard stop telling the human
  what to do).
- The Red flags entry must frame a round-cap stop as a hard stop, not
  something to retry-and-continue past.
- Every new prose assertion needs a corresponding `want`/`reject` line
  in `tests/test-epic-skill.sh` (the file's own guarding convention —
  see its header comment) and, for the epicstate whitelist change, a
  new happy-path case in `tests/test-epicstate.sh` mirroring the
  existing `stopped:blocked` case (lines 87–91).

## Review Focus

- A human reviewer skimming step 5's new pre-authorization sentence
  might read it as *also* pre-authorizing Tier B/C — the task below
  must keep the "Tier B/C still require a stop" language immediately
  adjacent and explicit.
- Someone re-running `sdlc:epic` after a `stopped:review-round-cap` stop
  might assume the loop can just re-dispatch step 5 — the Red flags
  entry must say this needs the same explicit human confirmation
  `sdlc:review`'s own round-cap gotcha requires, not an automatic
  resume.
- `bin/sdlc-epicstate.sh set-status`'s die message (the text printed on
  an invalid token) must be updated alongside the case statement, or a
  future invalid-token error will describe a vocabulary that's already
  stale.
- The header comment in `bin/sdlc-epicstate.sh` (lines 11–13) documents
  the "closed vocabulary" as `done | stopped:review-tier-b-c |
  stopped:blocked` — this must be updated too, or the doc comment
  silently drifts from the code the moment this task lands.
- `tests/test-epicstate.sh` line 96's existing case (`run set-status
  100 bogus-status` → exit 2) must keep passing — adding one token to
  the whitelist must not accidentally loosen the validation into
  accepting arbitrary strings.

---

### Task 1: Add `stopped:review-round-cap` to `sdlc-epicstate.sh`'s set-status vocabulary

**Files:**
- Modify: `bin/sdlc-epicstate.sh:11-13` (header comment), `bin/sdlc-epicstate.sh:153-159` (`cmd_set_status`'s case statement and die message)
- Test: `tests/test-epicstate.sh` (append after the existing set-status block, currently lines 86–97)

**Interfaces:**
- Consumes: nothing new — this task only widens an existing closed
  `case` statement in `cmd_set_status()`.
- Produces: `sdlc-epicstate.sh set-status <ref> stopped:review-round-cap
  <detail>` now exits 0 and persists `status=stopped:review-round-cap`
  and `stopped_detail=<detail>`, exactly like the existing
  `stopped:blocked`/`stopped:review-tier-b-c` tokens. Task 2's skill
  prose calls this exact command shape.

- [ ] **Step 1: Write the failing test**

  Add this block to `tests/test-epicstate.sh` immediately after the
  existing set-status block (after the line `eq "2" "$RC" "set-status
  with an unrecognized token exits 2"` — currently line 97 — and before
  the `# --- unknown epic ...` comment):

  ```bash
  run set-status 100 stopped:review-round-cap "39 41 round cap hit"
  eq "0" "$RC" "set-status accepts stopped:review-round-cap"
  run status 100
  eq "stopped:review-round-cap" "$(field status)" \
    "set-status records stopped:review-round-cap as the status"
  eq "39 41 round cap hit" "$(field stopped_detail)" \
    "set-status records the round-cap detail"
  ```

- [ ] **Step 2: Run test to verify it fails**

  Run: `bash tests/test-epicstate.sh`
  Expected: FAIL — `sdlc-epicstate: set-status: status must be done,
  stopped:review-tier-b-c, or stopped:blocked` on stderr (suppressed by
  the harness's `2>/dev/null`, but `$RC` is 2, not 0), so the new "exits
  0" assertion fails with `FAIL: set-status accepts
  stopped:review-round-cap (want '0' got '2')`.

- [ ] **Step 3: Write minimal implementation**

  In `bin/sdlc-epicstate.sh`, change the `cmd_set_status` case statement
  (currently):

  ```bash
    case "$status" in
      done|stopped:review-tier-b-c|stopped:blocked) ;;
      *) die "set-status: status must be done, stopped:review-tier-b-c, or stopped:blocked" 2 ;;
    esac
  ```

  to:

  ```bash
    case "$status" in
      done|stopped:review-tier-b-c|stopped:review-round-cap|stopped:blocked) ;;
      *) die "set-status: status must be done, stopped:review-tier-b-c, stopped:review-round-cap, or stopped:blocked" 2 ;;
    esac
  ```

  Also update the header comment block at the top of the file
  (currently):

  ```
  #   set-status <epic-ref> <status> [detail]
  #                               closed vocabulary: done |
  #                               stopped:review-tier-b-c | stopped:blocked
  ```

  to:

  ```
  #   set-status <epic-ref> <status> [detail]
  #                               closed vocabulary: done |
  #                               stopped:review-tier-b-c |
  #                               stopped:review-round-cap | stopped:blocked
  ```

- [ ] **Step 4: Run test to verify it passes**

  Run: `bash tests/test-epicstate.sh`
  Expected: `passed=<N>` with the new assertions counted, `failed=0`,
  exit 0. Confirm the pre-existing `bogus-status` case (line 96-97)
  still exits 2 (it must — the case statement is additive, not
  loosened to a wildcard).

- [ ] **Step 5: Commit**

  ```bash
  git add bin/sdlc-epicstate.sh tests/test-epicstate.sh
  git commit -m "Accept stopped:review-round-cap in sdlc-epicstate.sh set-status"
  ```

---

### Task 2: Pre-authorize Tier A and add the round-cap outcome branch in `skills/epic/SKILL.md`

**Files:**
- Modify: `skills/epic/SKILL.md` step 5 (lines 85–96) and the Red flags
  section (lines 115–129)
- Test: `tests/test-epic-skill.sh` (append new `want` assertions)

**Interfaces:**
- Consumes: Task 1's widened `sdlc-epicstate.sh set-status` vocabulary
  (the new branch calls it with the `stopped:review-round-cap` token).
- Produces: nothing consumed by later tasks — this is the last task.

- [ ] **Step 1: Write the failing tests**

  Append to `tests/test-epic-skill.sh`, right before the final `echo
  "passed=$pass failed=$fail"` line:

  ```bash
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
  ```

- [ ] **Step 2: Run test to verify it fails**

  Run: `bash tests/test-epic-skill.sh`
  Expected: FAIL on all five new assertions (none of those strings
  exist in `skills/epic/SKILL.md` yet).

- [ ] **Step 3: Write minimal implementation**

  In `skills/epic/SKILL.md`, replace step 5's current text (lines
  85–96):

  ```markdown
  5. **Review.** Dispatch ONE fresh subagent: "Run `sdlc:review` on PR
     `<pr#>` at effort `medium`, including its Tier A auto-fix loop; if a
     Tier B or C finding comes back, do NOT fix it — report it and stop."
     `sdlc:review`'s own gate (human go-ahead before any Tier A fix lands)
     still applies unchanged inside that subagent; this loop does not
     bypass it.
     - Resolved (approved outright, or Tier-A-fixed to approval) →
       continue at step 6.
     - Any Tier B/C finding → `sdlc-epicstate.sh set-status <epic-ref>
       stopped:review-tier-b-c "<ticket-ref> <pr#> <one-line finding
       summary>"`. Stop; tell the human which PR and finding to resolve
       before resuming.
  ```

  with:

  ```markdown
  5. **Review.** Dispatch ONE fresh subagent: "Run `sdlc:review` on PR
     `<pr#>` at effort `medium`, including its Tier A auto-fix loop. Tier A
     fixes are pre-authorized in this unattended context — treat step 6's
     triage gate as satisfied for every Tier A finding without waiting for
     a human go-ahead. Tier B or C still must not be auto-fixed — report
     them and stop instead." This is the one place this loop bypasses
     `sdlc:review`'s own human-gate default, and only for Tier A; Tier B/C
     always still hits a hard stop below.
     - Resolved (approved outright, or Tier-A-fixed to approval) →
       continue at step 6.
     - Any Tier B/C finding → `sdlc-epicstate.sh set-status <epic-ref>
       stopped:review-tier-b-c "<ticket-ref> <pr#> <one-line finding
       summary>"`. Stop; tell the human which PR and finding to resolve
       before resuming.
     - The subagent reports `stopped:review-round-cap` (the round cap was
       hit inside `sdlc:review`'s own Tier A loop — see that skill's step
       6) → `sdlc-epicstate.sh set-status <epic-ref>
       stopped:review-round-cap "<ticket-ref> <pr#> <round count and
       remaining findings from the subagent's report>"`. Stop; tell the
       human this PR capped out at 3 review rounds inside the subagent and
       needs its own fresh, human-confirmed `sdlc:review` invocation
       (per that skill's cross-invocation-persistence check) before this
       loop can resume.
  ```

  Then, in the Red flags section (lines 115–129), add one bullet after
  the existing "Fixing a Tier B/C finding inline" bullet and before
  "Special-casing a diamond-shaped epic dependency graph":

  ```markdown
  - Treating a `stopped:review-round-cap` stop as retry-and-continue →
    like Tier B/C, this is a hard stop; `sdlc:review`'s own round-cap
    gotcha requires explicit human confirmation before any fresh
    `sdlc:review` re-invocation on that PR, and this loop must not
    auto-resume step 5 for that ticket without it.
  ```

- [ ] **Step 4: Run test to verify it passes**

  Run: `bash tests/test-epic-skill.sh`
  Expected: `passed=<N>` with all (old + 5 new) assertions passing,
  `failed=0`, exit 0.

  Then re-run Task 1's test to confirm nothing regressed:
  `bash tests/test-epicstate.sh` → `failed=0`.

  Also run `bash tests/validate-skills.sh` if it exists, to catch any
  skill-format regressions (front-matter, structure) this edit might
  introduce.

- [ ] **Step 5: Commit**

  ```bash
  git add skills/epic/SKILL.md tests/test-epic-skill.sh
  git commit -m "Pre-authorize Tier A and handle stopped:review-round-cap in sdlc:epic"
  ```
