---
name: next
description: Use when an SDLC backlog has open sdlc:task tickets and you need to pick what to build next — surveys open tasks, ranks the actionable ones by how many other tickets they unblock (transitive dependents), reports the frontier, and hands the winner to sdlc:implement. Invoke as sdlc:next [epic-ref].
---

# SDLC Next: pick the highest-leverage ticket

Decides which open `sdlc:task` issue to build next. **Leverage = the
actionable ticket that unblocks the most other work.** Read-only up to
the handoff. Context discipline: the main loop holds the graph and the
judgment; the bulky `gh` fetch + body parsing goes to a subagent that
returns only a compact adjacency list. Create a todo per checklist item.

## Leverage model

Each `sdlc:task` body carries a `## Depends on` section of ticket refs
(written by `sdlc:ticket`). `A depends on B` is the edge `B → A`.
A ref is opaque: `123` on GitHub — written `#123` inside issue bodies,
but bare when passed to `gh` — and `PROJ-123` on JIRA.

- **Dependents of X** = tickets that depend on X directly *or
  transitively* (the downstream closure of X over the OPEN task set).
  Closed tickets are already done and are NOT counted.
- **Leverage(X)** = count of distinct open dependents of X.

## Ready (must match `sdlc:implement` step 1)

A ticket is **ready** iff:

1. Not labeled `sdlc:in-progress` or `sdlc:in-review`, AND
2. Unassigned, AND
3. Every ref under its `## Depends on` heading is CLOSED.

Only ready tickets are ever recommended — so `implement` never rejects
the pick. Non-ready tickets still count toward others' dependents and
appear as context, but are never the recommendation.

## Checklist

0. **Resolve the backend:** run `sdlc-backend.sh resolve`. On `use-github`
   continue below unchanged; on `use-jira` read and follow the plugin's
   `references/backend-jira.md`; on `bind-needed`, `backend-bind.md`.
1. **Preconditions:** `gh auth status` succeeds (else stop; tell the user
   to run `! gh auth login`).
2. **Gather (subagent).** Dispatch one scout to run the `gh` queries and
   return a **compact adjacency list** — NOT raw issue bodies. Query:
   `gh issue list --label "sdlc:task" --state open --json
   number,title,body,labels,assignees,createdAt`. For each issue the
   scout parses the `## Depends on` section into refs and returns a
   node `{ref, title, dependsOn:[…], inProgress, inReview, assigned,
   ops, createdAt}` — where `ops` is true iff the issue carries an `ops`
   label (business/ops action; no PR, exempt from the review flow). It
   also returns the OPEN/CLOSED state of every ref that
   appears in any `Depends on` section — including refs outside the open
   set — via `gh issue view <ref> --json number,state` (needed for
   readiness). Scoped form `sdlc:next <epic-ref>`: restrict the node set
   to that epic's children (issues whose body `## Epic` line names that
   ref, or the epic's `## Tasks` checklist).
3. **Build graph & classify (main loop).** Invert `dependsOn` into a
   dependents map. For each node compute (a) transitive open-dependent
   count = leverage, (b) critical-path depth = longest downstream chain
   rooted at it. Classify each node ready / not-ready by the test above.
4. **Rank the ready set** by, in order: leverage desc → critical-path
   depth desc → oldest `createdAt` → lowest numeric part of the ref
   (so `42` before `100`, `PROJ-9` before `PROJ-10`). `ops` tickets
   are ranked normally (they genuinely block downstream work) but are NOT
   candidates for the `implement` handoff — see step 6.
5. **Report.**
   - **Next (implement):** the top ready **non-ops** ticket — `<ref> —
     <title>` · "unblocks N: <ref> <ref> …" · "ready now."
   - **Runners-up:** next 2–3 ready non-ops tickets with their leverage.
   - **Ready, but ops (action manually — no PR):** any ready `ops`
     tickets, with their leverage. These do NOT go to `implement`.
   - **Blocked but high-leverage (context):** top non-ready tickets by
     leverage, each with the open refs blocking them.
6. **Hand off (a ready non-ops ticket exists).** `ops` tickets are
   review-exempt and produce no PR, so `implement` never runs on them —
   the handoff target is the top ready **non-ops** ticket. One
   lightweight confirm — because `implement` claims the issue, branches,
   and opens a PR:

   > `Next: <ref> (unblocks N). Proceed to implement? [Enter=yes / ref=other]`

   On confirm (or a different ref the user names, if that ticket is also
   ready and non-ops), invoke `sdlc:implement <ref>` in this session. Never
   invoke `implement` on a non-ready or `ops` ticket.
7. **No ready non-ops ticket → report the frontier, do NOT invoke
   `implement`.**
   Show the highest-leverage blocked ticket and the exact open
   prerequisites to clear to reach it, plus why the rest aren't ready.
   If ready `ops` tickets exist, list them here too — they are
   actionable, just not by `implement`.

   ```
   No ready non-ops ticket to implement.
   Highest leverage: #48 — data model (unblocks 5)
   Blocked by open: #40, #41
   → clear #40, #41 to unlock #48
   Ready, but ops (action manually): #44 (unblocks 2)
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
  chain wins; still tied → the older ticket; still tied → the lower
  numeric part of the ref.

## Red flags

- Recommending a ticket that isn't ready → `implement` will reject it;
  the readiness test MUST match `sdlc:implement` step 1 exactly.
- Reading full issue bodies in the main loop → that is the scout's job;
  the main loop only needs the adjacency list.
- Counting closed tickets as dependents → inflates leverage with work
  that's already done.
- Invoking `implement` when the ready set is empty → step 7 reports the
  frontier and stops instead.
- Handing an `ops` ticket to `implement` → ops tickets are review-exempt
  and produce no PR; rank them, but the handoff target is always the top
  ready non-ops ticket.
