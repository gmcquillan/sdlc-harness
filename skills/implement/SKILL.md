---
name: implement
description: Use when an sdlc:task GitHub issue is ready to build — claims the issue, maps the subsystem via scouts, branches in a worktree, plans, executes with TDD in fresh subagents, self-reviews, and opens a PR. Never merges. Invoke as sdlc:implement [issue#].
---

# SDLC Implement: Issue → PR

The workhorse. Context discipline governs every step: **the main loop
holds judgment and state transitions; breadth goes to subagents.** If a
step will generate more than a few thousand tokens of tool output you
don't need verbatim afterward, it belongs in a subagent. Create a todo
per checklist item.

## Checklist

1. **Select the issue.** Argument given → use it. None → list candidates:
   `gh issue list --label "sdlc:task" --state open --json
   number,title,body,labels,assignees` and pick the first that is (a) not
   labeled `sdlc:in-progress` or `sdlc:in-review`, (b) unassigned, and
   (c) unblocked — every `#ref` under its `## Depends on` heading is
   CLOSED (`gh issue view <ref> --json state`). No candidate → report why
   each open task is blocked and stop.
2. **Preconditions:** clean `git status`; `gh auth status` succeeds.
   Either failure → stop and report. Then **sync the base branch with
   origin BEFORE any scouting or worktree** (steps 4–5): `git fetch
   origin` and fast-forward the local base (`main`/`master`) to
   `origin/<base>`. If the local base has diverged (non-fast-forward) →
   stop and report rather than force anything. The worktree in step 5
   MUST branch from this freshly-synced base.
3. **Claim it** (prevents double pickup by parallel sessions):
   `gh issue edit <n> --add-label "sdlc:in-progress" --add-assignee "@me"`
4. **Understand.** Read the issue body and the spec section it links —
   main loop. Then invoke `fable-harness:systems-mapping` — scout
   subagents map the affected subsystem; only their maps return to you.
   Do NOT read the subsystem file-by-file yourself.
5. **Isolate.** Invoke `superpowers:using-git-worktrees`; branch
   `sdlc/<issue#>-<slug>` (slug = kebab-cased issue title, ≤5 words).
6. **Plan.** Invoke `superpowers:writing-plans` for a per-issue plan
   scoped to the acceptance criteria; save under `docs/plans/` and COMMIT
   it to the branch — plans must survive handoffs and session death.
7. **Execute.** Invoke `superpowers:subagent-driven-development` (the
   default — each task runs in a fresh subagent, protecting this
   session's budget) with `superpowers:test-driven-development` per task.
   Fall back to inline `superpowers:executing-plans` ONLY when tasks are
   so tightly coupled that per-task subagent setup exceeds the benefit —
   and say so explicitly.
8. **Verify.** Invoke `superpowers:verification-before-completion`.
   Run full test suites in a subagent that returns a pass/fail summary
   plus failures verbatim — never page raw test logs through this
   context. Every acceptance criterion needs evidence.
9. **Self-review.** Invoke `superpowers:requesting-code-review` on the
   branch diff; fix findings before delivery (verify each finding
   technically first — no performative agreement).
10. **Deliver.**

    ```bash
    git push -u origin "sdlc/<issue#>-<slug>"
    gh pr create --title "<issue title>" --body "Closes #<issue>

    Epic: #<epic> · Spec: \`<spec-path>\` §T<n>

    ## Acceptance criteria
    - [x] <criterion — evidence: <one line>>"
    gh issue edit <n> --remove-label "sdlc:in-progress" \
      --add-label "sdlc:in-review"
    gh issue comment <n> --body "PR: <pr-url>"
    ```

11. **Stop.** Never merge; never push to main/master. Suggest:
    "Run `/sdlc:review <PR#>` in a fresh session."

## If the context tripwire fires mid-issue

Finish the current atomic step (SOFT) or stop immediately (HARD), then
invoke sdlc:handoff. The committed plan + branch + handoff file carry
everything; a mid-issue split is survivable by design.

## Red flags

- Reading file-after-file in step 4 → that is the scouts' job.
- Skipping the claim in step 3 → two sessions build the same issue.
- "Tests probably pass" in step 8 → evidence before assertions, always.
