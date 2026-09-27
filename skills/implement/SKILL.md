---
name: implement
description: Use when an sdlc:task ticket is ready to build — claims the ticket, maps the subsystem via scouts, branches in a worktree, plans, executes with TDD in fresh subagents, self-reviews, and opens a PR. Never merges. Invoke as sdlc:implement [ref].
---

# SDLC Implement: Ticket → PR

The workhorse. Context discipline governs every step: **the main loop
holds judgment and state transitions; breadth goes to subagents.** If a
step will generate more than a few thousand tokens of tool output you
don't need verbatim afterward, it belongs in a subagent. Create a todo
per checklist item.

## Checklist

0. **Resolve the backend:** run `sdlc-backend.sh resolve`. On `use-github`
   continue below unchanged; on `use-jira` read and follow the plugin's
   `references/backend-jira.md`; on `bind-needed`, `backend-bind.md`.
1. **Select the issue.** Argument given → use it. None → list candidates:
   `gh issue list --label "sdlc:task" --state open --json
   number,title,body,labels,assignees` and pick the first that is (a) not
   labeled `sdlc:in-progress` or `sdlc:in-review`, (b) unassigned, and
   (c) unblocked — every ref under its `## Depends on` heading is
   CLOSED (`gh issue view <ref> --json state`; that section writes GitHub
   refs as `#123`, so pass them bare). No candidate → report why
   each open task is blocked and stop. (`sdlc:epic` relies on a
   same-epic in-review relaxation to the CLOSED requirement — see
   `skills/next/SKILL.md`'s Ready section — but that only applies to
   `sdlc:next`'s own recommendation; this auto-pick path always requires
   CLOSED, since `sdlc:epic` never reaches it — it always passes an
   explicit ref.)
2. **Preconditions:** clean `git status`; `gh auth status` succeeds.
   Either failure → stop and report. Then **sync the base branch with
   origin BEFORE any scouting or worktree** (steps 4–5): `git fetch
   origin` and fast-forward the local base (`main`/`master`, or the
   `--base-ref <branch>` override if one was passed at invocation — see
   below) to `origin/<base>`. If the local base has diverged
   (non-fast-forward) → stop and report rather than force anything. If
   `<branch>` does not exist locally or on `origin` →
   stop and report exactly like a diverged base; never fall back to
   `main`/`master` silently. The worktree in step 5 MUST branch from
   this freshly-synced base.

   **Base-ref override (additive, opt-in):** `sdlc:implement <ref>
   --base-ref <branch>` syncs and branches against `<branch>` instead
   of `main`/`master` — used by `sdlc:epic` to stack one ticket's PR on
   the previous ticket's branch. Invoked without `--base-ref`, this
   step's behavior is unchanged from the paragraph above.
3. **Claim it** (prevents double pickup by parallel sessions):
   `gh issue edit <n> --add-label "sdlc:in-progress" --add-assignee "@me"`
4. **Understand.** Read the issue body — it is self-contained; there is no
   spec file to cross-reference — main loop. Then invoke
   `fable-harness:systems-mapping` — scout
   subagents map the affected subsystem; only their maps return to you.
   Do NOT read the subsystem file-by-file yourself. If
   `docs/domain/glossary.md` exists, read it and bind its canonical terms.
5. **Isolate.** Invoke `superpowers:using-git-worktrees`; branch
   `sdlc/<ref>-<slug>` (slug = kebab-cased ticket title, ≤5 words) from
   step 2's synced base — so `sdlc/42-add-widget` or
   `sdlc/PROJ-123-add-widget`. With a `--base-ref` override, the
   branch point is the override branch's tip; without one, it is
   `main`/`master`'s tip, unchanged.
6. **Plan.** Invoke `superpowers:writing-plans` for a per-issue plan
   scoped to the acceptance criteria; save under `docs/plans/` and COMMIT
   it to the branch — plans must survive handoffs and session death.
7. **Execute.** Invoke `superpowers:subagent-driven-development` (the
   default — each task runs in a fresh subagent, protecting this
   session's budget) with `superpowers:test-driven-development` per task.
   Fall back to inline `superpowers:executing-plans` ONLY when tasks are
   so tightly coupled that per-task subagent setup exceeds the benefit —
   and say so explicitly.

   **Reviewer-dispatch (override, additive):** at every point
   `superpowers:subagent-driven-development` or
   `superpowers:requesting-code-review` calls for a reviewer-subagent
   dispatch — initial task review, each scoped re-review, the final
   whole-branch review — use `references/reviewer-dispatch.md` instead
   of that skill's own dispatch step. Everything else about the invoked
   skill (fix-round numbering, model selection, ledger format) is
   unchanged.
8. **Verify.** Invoke `superpowers:verification-before-completion`.
   Run full test suites in a subagent that returns a pass/fail summary
   plus failures verbatim — never page raw test logs through this
   context. Every acceptance criterion needs evidence.
9. **Self-review.** Invoke `superpowers:requesting-code-review` on the
   branch diff; fix findings before delivery (verify each finding
   technically first — no performative agreement).
10. **Lint.** Run the project's linter/formatter and fix every finding
    before pushing. The `lint-before-push` hook is a backstop, not a
    substitute — running lint here surfaces failures in-loop instead of
    as a blocked push. The same gate applies to any later push that
    fixes CI on the open PR.
11. **Deliver.** With a `--base-ref` override, add `--base <branch>` to
    the `gh pr create` call below so the PR's diff is only this
    ticket's incremental change against the stack tip; without an
    override, the command below is unchanged.

    ```bash
    git push -u origin "sdlc/<ref>-<slug>"
    gh pr create --title "<issue title>" --body "Closes #<issue>

    Epic: #<epic>

    ## Acceptance criteria
    - [x] <criterion — evidence: <one line>>"
    gh issue edit <n> --remove-label "sdlc:in-progress" \
      --add-label "sdlc:in-review"
    gh issue comment <n> --body "PR: <pr-url>"
    ```

12. **Stop.** Never merge; never push to main/master. Suggest:
    "Run `/sdlc:review <PR#>` in a fresh session."

## If the context tripwire fires mid-issue

Finish the current atomic step (SOFT) or stop immediately (HARD), then
invoke sdlc:handoff. The committed plan + branch + handoff file carry
everything; a mid-issue split is survivable by design.

## Red flags

- Reading file-after-file in step 4 → that is the scouts' job.
- Skipping the claim in step 3 → two sessions build the same issue.
- "Tests probably pass" in step 8 → evidence before assertions, always.
- Dispatching a 3rd reviewer subagent at a dispatch site past its stall
  cap → see `references/reviewer-dispatch.md`'s own Red Flags; the cap
  exists precisely to stop that.
