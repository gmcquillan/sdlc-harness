---
name: next
description: Use when an SDLC backlog has open sdlc:task issues and you need to pick what to build next — surveys open tasks, ranks the actionable ones by how many other tickets they unblock (transitive dependents), reports the frontier, and hands the winner to sdlc:implement. Invoke as sdlc:next [epic#].
---

# SDLC Next: pick the highest-leverage ticket

Decides which open `sdlc:task` issue to build next. **Leverage = the
actionable ticket that unblocks the most other work.** Read-only up to
the handoff. Context discipline: the main loop holds the graph and the
judgment; the bulky `gh` fetch + body parsing goes to a subagent that
returns only a compact adjacency list. Create a todo per checklist item.

## Leverage model

Each `sdlc:task` body carries a `## Depends on` section of `#refs`
(written by `sdlc:ticket`). `A depends on B` is the edge `B → A`.

- **Dependents of X** = tickets that depend on X directly *or
  transitively* (the downstream closure of X over the OPEN task set).
  Closed tickets are already done and are NOT counted.
- **Leverage(X)** = count of distinct open dependents of X.

## Ready (must match `sdlc:implement` step 1)

A ticket is **ready** iff:

1. Not labeled `sdlc:in-progress` or `sdlc:in-review`, AND
2. Unassigned, AND
3. Every `#ref` under its `## Depends on` heading is CLOSED.

Only ready tickets are ever recommended — so `implement` never rejects
the pick. Non-ready tickets still count toward others' dependents and
appear as context, but are never the recommendation.

## Checklist

1. **Preconditions:** `gh auth status` succeeds (else stop; tell the user
   to run `! gh auth login`).
2. **Gather (subagent).** Dispatch one scout to run the `gh` queries and
   return a **compact adjacency list** — NOT raw issue bodies. Query:
   `gh issue list --label "sdlc:task" --state open --json
   number,title,body,labels,assignees,createdAt`. For each issue the
   scout parses the `## Depends on` section into `#refs` and returns a
   node `{number, title, dependsOn:[#…], inProgress, inReview, assigned,
   createdAt}`. It also returns the OPEN/CLOSED state of every `#ref` that
   appears in any `Depends on` section — including refs outside the open
   set — via `gh issue view <ref> --json number,state` (needed for
   readiness). Scoped form `sdlc:next <epic#>`: restrict the node set to
   that epic's children (issues whose body `## Epic` line is `#<epic#>`,
   or the epic's `## Tasks` checklist).
3. **Build graph & classify (main loop).** Invert `dependsOn` into a
   dependents map. For each node compute (a) transitive open-dependent
   count = leverage, (b) critical-path depth = longest downstream chain
   rooted at it. Classify each node ready / not-ready by the test above.
4. **Rank the ready set** by, in order: leverage desc → critical-path
   depth desc → oldest `createdAt` → lowest issue number.
5. **Report.**
   - **Next:** `#<n> — <title>` · "unblocks N: #a #b …" · "ready now."
   - **Runners-up:** next 2–3 ready tickets with their leverage.
   - **Blocked but high-leverage (context):** top non-ready tickets by
     leverage, each with the open `#refs` blocking them.
6. **Hand off (ready set non-empty).** One lightweight confirm — because
   `implement` claims the issue, branches, and opens a PR:

   > `Next: #<n> (unblocks N). Proceed to implement? [Enter=yes / #=other]`

   On confirm (or a different `#` the user names, if that ticket is also
   ready), invoke `sdlc:implement <n>` in this session. Never invoke
   `implement` on a non-ready ticket.
7. **Empty ready set → report the frontier, do NOT invoke `implement`.**
   Show the highest-leverage blocked ticket and the exact open
   prerequisites to clear to reach it, plus why the rest aren't ready:

   ```
   No ready tickets.
   Highest leverage: #48 — data model (unblocks 5)
   Blocked by open: #40, #41
   → clear #40, #41 to unlock #48
   (also: 2 in-progress, 1 assigned)
   ```

   Then stop.

## Worked examples (the ranking, made unambiguous)

- Linear `A→B→C` (C depends on B depends on A): A unblocks 2, B unblocks
  1, C unblocks 0 → recommend A if ready.
- Diamond `A→{B,C}→D`: A unblocks 3 — the transitive closure counts D
  once, not twice.
- A ticket with the most dependents but an OPEN prerequisite is shown as
  context, never as the pick.
- Two ready tickets tied on leverage → the one on the longer downstream
  chain wins; still tied → the older issue; still tied → lower number.

## Red flags

- Recommending a ticket that isn't ready → `implement` will reject it;
  the readiness test MUST match `sdlc:implement` step 1 exactly.
- Reading full issue bodies in the main loop → that is the scout's job;
  the main loop only needs the adjacency list.
- Counting closed tickets as dependents → inflates leverage with work
  that's already done.
- Invoking `implement` when the ready set is empty → step 7 reports the
  frontier and stops instead.
