# Reviewer dispatch

Read this file whenever `sdlc:implement` step 7 causes
`superpowers:subagent-driven-development` or
`superpowers:requesting-code-review` to call for a reviewer-subagent
dispatch. It replaces those skills' own dispatch step, uniformly, at
every one of the three sites below. Everything else about the invoked
skill — fix-round numbering, model selection, ledger format, the review
templates themselves — is unchanged.

## The problem this solves

A reviewer subagent can stall: never return output at all, unresponsive
to a status-check nudge (observed: 3 consecutive dispatches, 9–40+
minutes each, zero output — 2 on sonnet, 1 on haiku, ruling out a
model-specific cause). `subagent-driven-development`'s fix-round cap
(rounds 1–5) only guards a review that *does* return and keeps
returning findings; it has no cap or fallback for a dispatch that never
returns at all. This procedure adds that cap, applied everywhere a
reviewer subagent gets dispatched, not just the one site where it was
first observed.

## The three dispatch sites

Each site is capped independently — its own review package, its own
brief, its own two attempts:

1. **Initial task review** — `subagent-driven-development` §3
   ("Generate review package, dispatch task reviewer"), once per task.
2. **Scoped re-review** — `subagent-driven-development` §4, once per
   fix round (rounds 1–5), per task.
3. **Final whole-branch review** — `subagent-driven-development`'s
   Final Review section, which delegates to
   `requesting-code-review`'s `code-reviewer.md`; once per branch.

## What counts as stalled

A dispatch is stalled once all three are true:

- `subagent-driven-development`'s own bounded wait for that dispatch
  (five to ten minutes) has elapsed with no output.
- `ListAgents` shows no visible progress from that subagent.
- A direct status-check nudge sent to that subagent goes unanswered.

## The cap

Two stalled attempts per dispatch site — not two total across a task, and not two total across the branch. Site 1 gets its own two attempts; each fix round's re-review (site 2) gets its own two attempts, independent of site 1's and of every other round's; the final review (site 3) gets its own two attempts, independent of every task's sites 1 and 2. A single stall is a retry, not the cap — dispatch once more at the same site before falling back.

## The fallback

On the 2nd stalled attempt at a site: do not dispatch a 3rd subagent for that site. Instead, perform that site's review yourself, in this session, reading the same inputs a subagent would have received:

- **Sites 1–2 (task-scoped):** the brief file, the implementer's report
  file, and the review package (for a re-review: the findings list, the
  report file, and the fix-range review package instead), applying
  `task-reviewer-prompt.md`'s rubric (site 1) or `re-review-prompt.md`'s
  rubric (site 2) — spec compliance and code quality for a task review;
  per-finding ADDRESSED/NOT-ADDRESSED verdicts plus new-breakage and
  out-of-scope-observations sections for a re-review.
- **Site 3 (branch-scoped):** the final review package
  (`review-package PLAN_FILE MERGE_BASE HEAD`) and the ledger's
  deferred-minor and parked lines, applying `code-reviewer.md`'s rubric
  in full — plan alignment, code quality, architecture, testing, and
  production readiness, including its "declined to judge" list. This is
  a broader rubric than sites 1–2's task-scoped one: do not substitute
  the narrower task-reviewer rubric here just because the same
  controller is doing the reading.

After the controller's own review, continue exactly where a subagent's
verdict would have left the loop: clean → the task completes (sites
1–2) or the branch proceeds to `finishing-a-development-branch` (site
3); findings → the normal fix loop (sites 1–2), or Final Review's
existing one-fix-dispatch-plus-one-scoped-re-review (site 3 — this
fallback does not add a second fix wave beyond what Final Review
already allows).

## Reporting the fallback

Never let a fallback happen silently:

- **Sites 1–2 (task-scoped):** append to the ledger — `Task <N>:
  reviewer-stall-fallback (site: <task-review|re-review round R>,
  controller reviewed directly)`.
- **Site 3 (branch-scoped):** there is no owning task and no ledger line
  format fits — note the fallback in the final summary to the human
  partner instead: which site stalled, how many attempts, and what the
  controller's own review found.

## Failure modes

| Situation | Behavior |
|---|---|
| A dispatch stalls once at a site | Retry once more at the same site — one stall is not the cap. |
| A dispatch stalls twice at the same site | Do not dispatch a 3rd subagent for that site — controller reviews directly, per "The fallback" above. |
| A task's site 1 already hit its cap; that task's first fix round (site 2) also stalls | Counts independently — each site's cap is its own budget. A task can fall back on its task review and still get two full attempts on its first re-review round. |
| The final review (site 3) stalls twice | Controller applies `code-reviewer.md`'s full rubric directly; reported in the final summary, not the ledger — there is no task ID to hang a ledger line on. |
| A stalled subagent's output eventually arrives after the controller already fell back | The controller's own review stands. Read the late output only if it changes the verdict, and say so in the fallback report — do not re-open the site or discard the late output unread. |

## Red flags

- Dispatching a 3rd subagent at a site whose cap is already spent — the
  cap exists precisely to stop that; a 3rd dispatch just burns another
  9–40+ minutes for the same zero output.
- Applying the narrower task-reviewer rubric to a site-3 fallback
  because it is faster — site 3's rubric is the full `code-reviewer.md`
  checklist, not the task-scoped one.
- Reporting a site 1–2 fallback in the final summary instead of the
  ledger, or a site 3 fallback as a ledger line with no owning task —
  each site's report format is fixed, not interchangeable.
- Treating a fallback as a reason to skip the fix loop or Final
  Review's fix-dispatch step — a controller-performed review that finds
  issues still goes through the same loop a subagent's findings would
  have.
