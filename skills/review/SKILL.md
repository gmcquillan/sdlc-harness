---
name: review
description: Use when an SDLC pull request needs review against its issue's acceptance criteria — fans out spec-compliance, correctness, and test-quality reviewers, skeptic-verifies findings, and posts a gh pr review. Never merges. Invoke as sdlc:review <PR#>.
---

# SDLC Review: PR → Verdict

The diff is reviewed by subagents; this session holds only metadata,
verdicts, and judgment. Create a todo per checklist item.

## Checklist

1. **Gather metadata (main loop, small):**
   `gh pr view <PR#> --json title,body,headRefName,files` — extract the
   linked issue from `Closes #<n>`, then
   `gh issue view <n> --json body` for the acceptance criteria and spec
   pointer. Do NOT fetch the diff into this context.
2. **Fan out reviewers** per `fable-harness:fan-out` — three subagents,
   ALL dispatched in a single message, each given the PR number, the
   acceptance criteria, and ONE dimension:
   - **Spec compliance:** does the diff satisfy every acceptance
     criterion? Anything out-of-scope smuggled in?
   - **Correctness:** logic, edge cases, error handling, concurrency.
   - **Test quality:** do tests exercise the criteria for real, or are
     they mocked facades that would pass against a stub?
   Each returns findings as `file:line — claim — severity`.
3. **Skeptic-verify significant findings:** every finding a reviewer
   rates important enough to block approval goes to a
   `fable-harness:skeptic` subagent (one finding each, dispatched in a
   single message) that tries to REFUTE it against the actual code.
   Refuted findings are dropped. No plausible-but-wrong comments reach
   the PR.
4. **Post the verdict** — comment or approve, NEVER merge:

   ```bash
   # criteria unmet or confirmed findings:
   gh pr review <PR#> --request-changes --body "<verified findings,
   grouped by dimension, each with file:line and the failure scenario>"
   # everything satisfied:
   gh pr review <PR#> --approve --body "All acceptance criteria verified:
   <one line of evidence per criterion>"
   ```

   Approval ends with: "Ready for your merge decision." The merge is
   always the human's.
5. **Address findings (ONLY if the user asked you to fix, not just
   review).** Triage → gate → act. Every fix runs in a sub-agent; the main
   loop never edits files itself, no matter how small the change.

   **Triage.** Sort each *confirmed* finding (survived the skeptic step)
   into one tier:
   - **Tier A — fix now:** a bounded edit to files already in the diff (or
     immediately adjacent), no new subsystem, no plan of its own needed.
   - **Tier B — ticket it:** needs its own plan, touches a subsystem
     outside the PR's scope, or is really a *new* acceptance criterion
     rather than a defect in the current one.
   - **Tier C — recommend a fresh implementation:** the confirmed findings
     *aggregate* into a re-do — the PR's approach is wrong, or Tier-B-or-
     larger findings are numerous enough that rebuilding beats patching.
     This is a judgment call over the whole findings list, not a per-
     finding rule.

   **Gate.** Present a triage table — each confirmed finding with its tier
   and the action it implies — and WAIT for an explicit go-ahead. Issue
   creation is outward-facing; gate it like `sdlc:ticket`'s dry-run. Create
   nothing and edit nothing before the yes.

   **Act** (only what was approved):
   - **Tier A:** check out the branch (`gh pr checkout <PR#>`), then dispatch
     ONE fresh sub-agent per fix (or a small batched set) running
     `superpowers:receiving-code-review` + `superpowers:test-driven-development`.
     The main loop supervises only. When fixes land and lint passes, push the
     branch (`git push`) so the updated PR is what step 2 re-reviews, then
     re-run this checklist from step 2.
   - **Tier B:** resolve the epic from the reviewed issue's `## Epic`
     section (the `#<n>` under that heading), then create a child issue in
     the same section format `sdlc:task` issues use, so `sdlc:next` /
     `sdlc:implement` pick it up:

     ```bash
     gh issue create --label "sdlc:task" \
       --title "<short finding title>" \
       --body "## Context
     Found in review of #<PR#> (<file:line>). <failure scenario>.

     ## Acceptance criteria
     - [ ] <criterion the fix must meet>

     ## Depends on
     #<current-issue>   # only if the fix must land after this PR; else 'none'

     ## Suggested direction
     <one or two lines>

     ## Epic
     #<epic>"
     ```
   - **Tier C:** `gh pr review <PR#> --request-changes` with the summary,
     create a Tier-B-style `sdlc:task` for the redo, and recommend
     `/sdlc:implement <issue#>` in a fresh session. Do NOT patch the branch.

   Report what was fixed, the URLs of any tickets created, and any redo
   recommendation.

## Red flags

- Pulling the full diff into the main loop "for a quick look" → that is
  the reviewers' context to spend, not yours.
- Posting reviewer findings nobody tried to refute → skeptic step is not
  optional for blocking findings.
- Merging an approved PR "to save a step" → human gate violated.
- Editing files from the main loop to "just fix it quickly" → every fix
  runs in a sub-agent; the main loop is supervisor only.
- Creating tickets or pushing fixes before the triage gate → the go-ahead
  is required, exactly like sdlc:ticket's dry-run.
- Patching a branch whose approach is wrong (Tier C) instead of
  recommending a fresh sdlc:implement → you are polishing a rewrite.
