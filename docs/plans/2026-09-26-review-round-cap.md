# Review Round Cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `skills/review/SKILL.md` step 6's Tier A auto-fix loop a hard
iteration cap (3 rounds) and a documented stop state
(`stopped:review-round-cap`) so an unattended dispatcher (e.g. `sdlc:epic`)
can never be cycled through step 2 → 5 → 6 indefinitely when reviewers keep
raising findings.

**Architecture:** This is a prose-only documentation change to one skill
file, verified the same way this repo verifies every other skill-prose
change: a `grep -qF` fixed-string assertion test
(`tests/test-review-round-cap.sh`) modeled directly on
`tests/test-epic-skill.sh`, run alongside the existing
`tests/validate-skills.sh` floor check. No script, state file, or executable
code changes — `skills/review/SKILL.md` is pure instructional prose read by
an agent, not code that runs.

**Tech Stack:** Bash (POSIX-ish, matching the rest of `tests/*.sh`), Markdown
(the skill file itself).

**Spec:** n/a — deleted per `sdlc:ticket` step 8; full context lives in
issue #38 (https://github.com/<owner>/<repo>/issues/38, in the epic #37).
Acceptance criteria, copied here since the spec file is gone:

- `skills/review/SKILL.md` step 6 documents a round counter (round 1 =
  initial pass, cap = 3) and stops re-entering step 2 once the cap is
  reached with confirmed findings still outstanding.
- On cap-out, the checklist posts a PR comment (not approve/request-changes)
  summarizing fixes applied across rounds and findings still outstanding,
  and defines the report string `stopped:review-round-cap` (with round
  count and remaining findings) as what gets reported back to the
  dispatcher.
- Rounds 1–3 reaching a clean approval behave exactly as today (no
  regression to the existing Tier A flow for the common case).
- Red flags section gains an entry for "re-entering step 2 past the cap"
  as a documented anti-pattern, matching the file's existing style.

Scope: `skills/review/SKILL.md` only (plus its guard test). Out of scope:
Tier B/C handling, the skeptic-verify/fan-out reviewer steps, any new
script/state file, and `sdlc:epic`'s handling of this new stop state
(that's ticket #39, a separate PR that must depend on this one).

## Global Constraints

- Round cap value is fixed at **3** and the stop string is fixed as
  **`stopped:review-round-cap`** — both already confirmed with the human
  during design; do not change either number or name.
- Only `skills/review/SKILL.md` and its new test file change. Do not touch
  `skills/epic/SKILL.md`, `bin/sdlc-epicstate.sh`, or any other skill.
- Follow the file's existing prose conventions: bold lead-in phrases
  (`**Round cap.**`), fenced `gh` command examples, and the existing
  Tier A/B/C bullet structure — do not restructure step 6 beyond what's
  needed.
- `tests/validate-skills.sh` has a `gh`-call-count floor for `review` of 7
  (see `gh_floors="... review:7 ..."` in that file). The current inline
  `gh` count in `skills/review/SKILL.md`'s body (frontmatter excluded) is 8
  as of this plan. Adding one `gh pr comment` call for the cap-out path
  raises this to 9, which still clears the floor of 7 — no edit to
  `tests/validate-skills.sh` is needed unless a later task removes `gh`
  calls instead of adding them.
- New test file must follow `tests/test-epic-skill.sh`'s exact
  `want()`/`reject()` grep-based pattern (no execution of the skill file,
  pure fixed-string assertions) — this repo's skill-doc tests are
  convention-locked to that shape.

## Review Focus

- **Cap-out still runs Tier A fixes before stopping** — a reader could
  misimplement this as "skip fixing entirely once the cap is hit." The
  prose must make clear that round 3's confirmed Tier A findings are still
  fixed and pushed; only the *re-entry to step 2* (which would start round
  4) is what's blocked. Pinned by the test's assertion on the "do not
  re-enter step 2" language plus a manual read-through in Task 2's
  self-check step.
- **Clean approval inside the cap must be unaffected** — nothing in the
  edit should touch step 5's `--approve` path or make an early clean
  review look like a cap-out. Pinned by leaving step 5 completely
  untouched and by the test's `reject()` assertion that the old uncapped
  sentence ("re-run this checklist from step 2" with no cap qualifier) is
  gone.
- **The stop string must not collide with existing stop states** — this
  repo already defines `stopped:hop-cap` and `stopped:review-tier-b-c` in
  `skills/epic/SKILL.md`. Pinned by using the exact, already-confirmed
  string `stopped:review-round-cap`, checked verbatim in the new test.
- **The cap-out comment must never carry a verdict** — a sloppy edit could
  reuse `gh pr review --request-changes` (which is not the same as a plain
  PR comment) for the cap-out path, muddying the "PR comment, not
  approve/request-changes" acceptance criterion. Pinned by the test's
  assertion that the cap-out command is `gh pr comment`, not
  `gh pr review`.
- **Red flags entry must describe the anti-pattern, not just name it** —
  a one-word red flag line would pass a shallow read but not help a future
  agent recognize the mistake. Pinned by writing a full red-flag bullet in
  the file's existing style (a wrong action → why it's wrong) and
  asserting its key phrase in the test.

---

### Task 1: Write the failing guard test for the round cap

**Files:**
- Create: `tests/test-review-round-cap.sh`

**Interfaces:**
- Consumes: nothing (reads `skills/review/SKILL.md` as plain text, same as
  `tests/test-epic-skill.sh` reads `skills/epic/SKILL.md`).
- Produces: an executable test script other tasks/CI invoke directly:
  `bash tests/test-review-round-cap.sh` (or `./tests/test-review-round-cap.sh`
  once `chmod +x`'d), printing `ok:`/`FAIL:` lines and a final
  `passed=N failed=N` summary, exiting 0 iff `failed=0` — the same contract
  `tests/test-epic-skill.sh` and `tests/validate-skills.sh` use.

- [ ] **Step 1: Write the test file**

```bash
cat > tests/test-review-round-cap.sh <<'EOF'
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
EOF
chmod +x tests/test-review-round-cap.sh
```

- [ ] **Step 2: Run it and confirm it fails against the current (unedited) skill file**

Run: `bash tests/test-review-round-cap.sh`

Expected: several `FAIL:` lines (the round-cap language doesn't exist yet
in `skills/review/SKILL.md`) and a final `passed=<n> failed=<m>` with
`m > 0`, non-zero exit status. If instead every `want()` already passes,
stop — that means Task 2's target text already exists and this task's
assumptions are wrong; re-check `skills/review/SKILL.md` before continuing.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/test-review-round-cap.sh
git commit -m "test: add failing guard test for sdlc:review's round cap (#38)"
```

### Task 2: Add the round cap and stop state to skills/review/SKILL.md

**Files:**
- Modify: `skills/review/SKILL.md:85-160` (step 6's opening paragraph, the
  Tier A Act bullet, and the Red flags section)
- Test: `tests/test-review-round-cap.sh` (from Task 1 — must go green)

**Interfaces:**
- Consumes: nothing new.
- Produces: the exact strings Task 1's test asserts on. This task's edit
  is the only place those strings may originate — do not paraphrase them.

- [ ] **Step 1: Insert the round-counter paragraph into step 6**

In `skills/review/SKILL.md`, step 6 currently opens:

```markdown
6. **Address findings (ONLY if the user asked you to fix, not just
   review).** Triage → gate → act. Every fix runs in a sub-agent; the main
   loop never edits files itself, no matter how small the change.

   **Triage.** Sort each *confirmed* finding (survived the skeptic step)
```

Replace it with (adds a new `**Round cap.**` paragraph between the opening
sentence and `**Triage.**`, no other text in this block changes):

```markdown
6. **Address findings (ONLY if the user asked you to fix, not just
   review).** Triage → gate → act. Every fix runs in a sub-agent; the main
   loop never edits files itself, no matter how small the change.

   **Round cap.** Round 1 is this checklist's initial pass (step 1 through
   this step, the first time it runs for this PR); each re-entry to step 2
   below starts a new round. Cap = 3 rounds. Round 3's Tier A fixes still
   get made and pushed exactly as any other round's — the cap only blocks
   the *re-entry to step 2* that would start a round 4 (see the Tier A
   bullet below).

   **Triage.** Sort each *confirmed* finding (survived the skeptic step)
```

- [ ] **Step 2: Rewrite the Tier A Act bullet to gate re-entry on the cap**

The current Tier A bullet reads:

```markdown
   - **Tier A:** check out the branch (`gh pr checkout <PR#>`), then dispatch
     ONE fresh sub-agent per fix (or a small batched set) running
     `superpowers:receiving-code-review` + `superpowers:test-driven-development`.
     The main loop supervises only. When fixes land and lint passes, push the
     branch (`git push`) so the updated PR is what step 2 re-reviews, then
     re-run this checklist from step 2.
```

Replace it with:

```markdown
   - **Tier A:** check out the branch (`gh pr checkout <PR#>`), then dispatch
     ONE fresh sub-agent per fix (or a small batched set) running
     `superpowers:receiving-code-review` + `superpowers:test-driven-development`.
     The main loop supervises only. When fixes land and lint passes, push the
     branch (`git push`) so the updated PR is what step 2 re-reviews.

     Check the round counter before re-entering step 2: below the cap (this
     was round 1 or round 2) → re-run this checklist from step 2, exactly as
     before. At the cap (this was round 3, and confirmed findings are still
     outstanding after round 3's fixes) → do NOT re-enter step 2. Instead
     `gh pr comment <PR#> --body "<summary of every fix applied across all
     three rounds, plus every confirmed finding still outstanding>"` —
     never `--approve` or `--request-changes` for this path, since the
     review itself was never re-run past the cap to justify a verdict —
     then report `stopped:review-round-cap` back to whatever invoked this
     checklist, along with the round count (3) and the list of remaining
     findings.
```

- [ ] **Step 3: Add the Red flags entry**

The Red flags section currently ends with:

```markdown
- Running the drift check with no glossary present, or letting a drift
  hit block approval → the check is advisory and the default path must
  stay free.
```

Append one new bullet directly after it (last line of the file):

```markdown
- Running the drift check with no glossary present, or letting a drift
  hit block approval → the check is advisory and the default path must
  stay free.
- Re-entering step 2 after round 3's fixes land → the cap exists precisely
  to stop this; post the summary comment and report
  `stopped:review-round-cap` instead.
```

- [ ] **Step 4: Run the new guard test and confirm it passes**

Run: `bash tests/test-review-round-cap.sh`

Expected: every line `ok:`, final `passed=8 failed=0`, exit status 0. If
any `FAIL:` remains, compare the failing `want()`/`reject()`'s exact string
against what was written in Steps 1–3 — the test uses `grep -qF` fixed-string
matching, so whitespace/line-wrapping inside a `want()` argument must match
the file byte-for-byte on that logical string.

- [ ] **Step 5: Run the full existing skill-doc test suite to confirm no regressions**

Run:
```bash
bash tests/test-epic-skill.sh && \
bash tests/validate-skills.sh && \
bash tests/test-review-round-cap.sh
```

Expected: all three print `passed=<n> failed=0` and exit 0. In particular,
confirm `validate-skills.sh`'s line `ok: review: 9 inline gh commands
(floor 7)` (or similar — the exact count may differ slightly from this
plan's estimate of 9, but it must be `>= 7`) — if it instead reads `FAIL:`
for `review`, the floor in `tests/validate-skills.sh`'s `gh_floors` string
needs bumping in this same task, with a one-line comment explaining why
(per that file's own stated convention for floor changes).

- [ ] **Step 6: Commit**

```bash
git add skills/review/SKILL.md
git commit -m "feat: add a 3-round cap and stopped:review-round-cap to sdlc:review's Tier A loop (#38)"
```
