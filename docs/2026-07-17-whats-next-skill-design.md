# Design: `sdlc:next` — survey tickets, recommend highest-leverage work

Date: 2026-07-17

## Purpose

Given a backlog of open `sdlc:task` GitHub issues, decide which one to
build next. "Highest leverage" = the actionable ticket that unblocks the
most other work. The skill ranks ready tickets by their transitive
dependent count and hands the winner off to `sdlc:implement`.

It sits between `sdlc:ticket` and `sdlc:implement` in the pipeline:

```
/sdlc:interview → spec → /sdlc:ticket → epic + child issues
                                              │
                                        /sdlc:next   ← this skill
                                              │
                          /sdlc:implement [#] → PR → /sdlc:review
```

## Invocation

- `sdlc:next` — survey all open `sdlc:task` issues in the repo.
- `sdlc:next <epic#>` — scope the survey to one epic's children.

Directory: `skills/next/SKILL.md`. Auto-discovered by the plugin (no
`plugin.json` edit needed).

## Leverage model

Each `sdlc:task` issue body carries a `## Depends on` section listing the
`#refs` it depends on (produced by `sdlc:ticket`). That is the raw edge
set: `A depends on B` means `B → A`.

- **Dependents of X** = tickets that depend on X, directly or
  transitively (the downstream closure of X over the *open* task set).
  Closed tickets are already done and are not counted as "unblocked."
- **Leverage(X)** = count of distinct open dependents of X. This is the
  primary ranking key.

## Readiness (must match `sdlc:implement`)

A ticket is **ready** iff it satisfies the exact test `sdlc:implement`
step 1 uses to pick a candidate:

1. Not labeled `sdlc:in-progress` or `sdlc:in-review`.
2. Unassigned.
3. Every `#ref` under its `## Depends on` heading is CLOSED.

`sdlc:next` only ever *recommends* a ready ticket, so `implement` can
pick it up without rejecting it. Non-ready tickets still appear in the
graph (they contribute to other tickets' dependent counts and are shown
as context) but are never the recommendation.

**`ops` tickets.** A repo may label some `sdlc:task` issues `ops`
(business/ops action; no PR, exempt from the review flow). These are
ranked normally — they genuinely block downstream work — but are **not**
candidates for the `implement` handoff, which opens a PR. The handoff
target is always the top ready *non-ops* ticket; ready `ops` tickets are
listed separately for the user to action manually. (Surfaced by a smoke
test against a real backlog, where a high-leverage ticket that was
`ops`-labeled would otherwise have been handed to `implement`.)

## Ranking (ready set only)

Sort ready tickets by, in order:

1. Leverage (transitive open-dependent count), descending.
2. Critical-path depth — longest downstream dependency chain rooted at
   the ticket, descending. (Breaks ties toward work on the long pole.)
3. Age — oldest issue first (lowest `createdAt`).
4. Issue number, ascending. (Deterministic final tiebreak.)

## Flow

1. **Preconditions (main loop).** `gh auth status` succeeds, else stop
   and tell the user to run `! gh auth login`.

2. **Gather (subagent).** Issue bodies are bulky and only the parsed
   graph needs to survive into the main loop, so a scout subagent runs
   the `gh` queries, parses each `## Depends on` section, and returns a
   **compact adjacency list** — not raw bodies. Each node:
   `{number, title, dependsOn: [#…], inProgress, inReview, assigned,
   createdAt}`. The scout also returns the CLOSED/OPEN state of every
   `#ref` that appears in a `Depends on` section (needed for readiness),
   even refs outside the open-task set. Scoped form (`sdlc:next <epic#>`)
   restricts the node set to that epic's child issues.

3. **Build graph & classify (main loop, cheap).** Invert `dependsOn`
   into a dependents map; compute each ticket's transitive open-dependent
   count and critical-path depth; classify each node ready / not-ready by
   the readiness test above.

4. **Rank** the ready set by the ranking keys.

5. **Report.** Print:
   - **Next:** `#<n> — <title>`, leverage ("unblocks N: #a #b …"),
     "ready now."
   - **Runners-up:** next 2–3 ready tickets with their leverage.
   - **Blocked but high-leverage (context):** the top non-ready tickets
     by leverage, each with the open refs blocking them.

6. **Hand off (ready set non-empty).** One lightweight confirm before
   invoking `sdlc:implement`, because `implement` claims the issue,
   branches, and opens a PR:

   > `Next: #42 (unblocks 4). Proceed to implement? [Enter=yes / #=other]`

   On confirm (or a different `#` the user names), invoke
   `sdlc:implement <n>` in the same session.

7. **Empty ready set.** If no ticket is ready, do **not** invoke
   `implement`. Report the frontier instead: the highest-leverage blocked
   ticket and the exact open prerequisites to clear to reach it, e.g.

   ```
   No ready tickets.
   Highest leverage: #48 — data model (unblocks 5)
   Blocked by open: #40, #41
   → clear #40, #41 to unlock #48
   ```

   Also summarize why the rest aren't ready (in-progress / assigned /
   blocked counts). Then stop.

## Context discipline

Same rule as the rest of the harness: the main loop holds the graph,
judgment, and the state transition; the bulky `gh` fetch + body parsing
goes to a subagent that returns only the adjacency list. The graph
itself is small (numbers + short titles), so all ranking and reporting
stays in the main loop.

## Out of scope

- Does not claim, label, branch, or merge anything itself — that is
  `implement`'s job. `next` is read-only up to the handoff.
- Does not modify issue bodies or dependency edges.
- Does not weight by epic priority, estimated effort, or business value —
  leverage is purely structural (dependent count). A future revision
  could add a secondary weight; not now (YAGNI).

## Testing

Skills here are markdown instructions, not code, so "testing" matches the
repo's existing convention:

- `tests/validate-skills.sh` must pass for the new `SKILL.md` (valid
  frontmatter: `name`, `description`).
- The skill body carries the ranking rules as **worked examples** so the
  behavior is unambiguous when followed:
  - Linear chain `A→B→C`: A unblocks 2, B unblocks 1, C unblocks 0.
  - Diamond `A→{B,C}→D`: A unblocks 3 (transitive closure dedupes D).
  - Blocked high-leverage node surfaces as context, never as the pick.
  - Tie on leverage → critical-path depth → age → issue number.
  - Empty ready set → frontier report, no `implement` invocation.
- Manual acceptance: run `sdlc:next` against this repo's own open
  `sdlc:task` issues and confirm the recommendation and readiness
  classification match a hand-computed graph.
```
