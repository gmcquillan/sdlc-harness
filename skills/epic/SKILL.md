---
name: epic
description: Use when a GitHub epic's open tickets should be built unattended as one stacked PR chain instead of ticket-by-ticket — loops sdlc:next (pick) → sdlc:implement with a base-ref override (build) → sdlc:review with its Tier A auto-fix loop (review) against a durable, gitignored per-epic state file, stopping on a Tier B/C finding, an epic-wide hop cap, or an empty frontier. Never merges. Invoke as sdlc:epic <epic-ref>.
---

# SDLC Epic (autopilot)

Build every ready ticket under an epic as a single GitHub PR stack, each
PR based on the previous ticket's branch, so a human reviews the whole
stack once instead of ticket by ticket. Requires no migration against an
epic whose tickets predate this skill — it wraps `sdlc:next`'s existing
survey, so already-closed tickets and any ticket with a pre-existing
manual PR (labeled `sdlc:in-review`) are simply left alone. Create a
todo per checklist item.

## Checklist

0. **Resolve the backend.** `sdlc-backend.sh resolve` (bare name —
   `bin/` is on `PATH`). Branch on `action` the same way every other
   sdlc skill does.

1. **Ensure the ignore rule (once, shared across all worktrees) —
   mirrors, but does not modify, `sdlc:handoff` step 2's equivalent for
   `.handoff-*.md`:**

   ```bash
   excl="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
   grep -qxF '.sdlc-epic-*.md' "$excl" 2>/dev/null || echo '.sdlc-epic-*.md' >> "$excl"
   ```

2. **Resume-or-init, at the MAIN worktree root** (a single durable file
   per epic, findable from any worktree, same convention as
   `.handoff-*.md`):

   ```bash
   main_root=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
   ```

   Run `sdlc-epicstate.sh status <epic-ref>` from `$main_root`.
   - **Exit 0 (file exists):** a prior run is resuming. Before trusting
     it, verify against git reality the same way `sdlc:resume` does:
     does the recorded `tip=` branch exist (`git branch --list <tip>`)?
     does the last `stack=` line's PR exist and have the recorded base
     (`gh pr view <pr#> --json baseRefName`)? Disagreement → tell the
     human and stop; do not silently trust the file over git.
     - If a live `.handoff-*.md` also exists at `$main_root` (the
       in-flight ticket itself hit a context tripwire), resolve that via
       `sdlc:resume` FIRST — do not touch this loop until that ticket's
       `implement`/`review` finishes.
     - `status=done` or any `stopped:*` → report the stack (the
       `stack=` lines) and stop; a human decides whether to resume past
       a stop.
     - `status=running` → continue at step 3 using the recorded `tip=`.
   - **Exit 2 (no file yet):** `sdlc-epicstate.sh init <epic-ref>`, then
     continue at step 3 with `tip=main` (or whatever base
     `sdlc:implement` step 2 resolves as this repo's default).

3. **Pick.** `sdlc:next <epic-ref>`.
   - No ready non-ops ticket and nothing open remains under the epic at
     all → `sdlc-epicstate.sh set-status <epic-ref> done`, then go to
     step 7.
   - No ready non-ops ticket but open work remains (blocked outside the
     epic, or `ops` tickets needing manual action) → this is
     `sdlc:next` step 7's existing frontier report, surfaced to the
     human as-is; leave `status=running` (nothing to record — a
     temporarily-empty frontier is not a terminal state). Stop.
   - A ready ticket `<ref>` → continue at step 4.

4. **Build.** Dispatch ONE fresh subagent: "Run `sdlc:implement <ref>
   --base-ref <tip>`." (`<tip>` from step 2/6's resolved state — `main`
   on the epic's first ticket, else the previous ticket's branch.) The
   subagent reports back the ticket's branch name, PR number, and hop
   count consumed (0 if no context tripwire fired).
   - The subagent hits its own context tripwire mid-ticket → it writes
     its own `.handoff-*.md` exactly as `sdlc:implement` always does;
     this loop's step 2 resume path picks that up on the next
     `sdlc:epic` invocation. Stop this turn.

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

6. **Record.** `sdlc-epicstate.sh record <epic-ref> <ticket-ref>
   <branch> <pr#> <hops>`.
   - Exit 0 → the new running hop total is under the cap; go to step 3
     with `tip=<branch>` from this record.
   - Exit 1 → the epic-wide hop cap (default 30) is reached; the state
     file already recorded `status=stopped:hop-cap` and the hop count.
     Stop; tell the human the partial stack and which ticket to resume
     from.

7. **Finish.** Any stop above (done, blocked, Tier B/C, hop cap) ends
   the run. On a clean "done" finish, post one summary comment on the
   epic issue: the full stack in order (ticket → branch → PR#, from
   `sdlc-epicstate.sh status <epic-ref>`'s `stack=` lines), and tell the
   human it's ready for review starting with the bottom PR.
   **`sdlc:epic` never merges anything** — same invariant as every
   other skill in this repo.

## Red flags

- Trusting the state file's `tip=`/`stack=` without step 2's git-reality
  check → building on a branch that was rebased, deleted, or merged
  since the last recorded hop.
- Building or reviewing without a fresh subagent per step 4/5 → context
  from one ticket bleeding into the next ticket's `implement`/`review`.
- Fixing a Tier B/C finding inline "to keep the stack moving" → the
  design requires a hard stop; resuming after a human resolves it
  re-checks readiness from step 3 rather than skipping back into
  step 4/5.
- Special-casing a diamond-shaped epic dependency graph → always
  linearize via `sdlc:next`'s existing ranking, even at a genuine fork.
- Merging any PR in the stack, ever → that's always the human's call,
  identical to `sdlc:review`'s own invariant.
