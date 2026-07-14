---
name: interview
description: Use when starting a new feature or project under the SDLC pipeline — interviews the user to surface intent, wraps superpowers:brainstorming to produce a committed spec that ends with a PR-scoped, context-budgeted Decomposition section, then hands off to sdlc:ticket.
---

# SDLC Interview → Spec

Wraps `superpowers:brainstorming` for the dialogue mechanics (one
question at a time, 2–3 approaches, section-by-section approval) with
three SDLC overrides. Invoke `superpowers:brainstorming` NOW and follow
it, applying the overrides below. Create a todo per override.

## Override 1 — Interview additions

Beyond brainstorming's questions, explicitly establish: **intent** (the
problem behind the request), **users**, **non-goals**, **success
criteria**, and **constraints**. Before proposing approaches, dispatch
`fable-harness:integration-scan` — integrator subagents, one capability
statement each, in a single message — so "wire, don't build" options
surface during the interview, not after design lock-in. Keep the scan in
subagents: their transcripts must not enter this session's context.

## Override 2 — Spec must end with `## Decomposition`

An ordered task list; each task is one PR and an estimated ≤100k tokens
of implementation work (headroom under the 150k tripwire). Sizing
heuristics per task: one subsystem, ≲10 files, ≲500 LOC diff. Exact
format (sdlc:ticket parses this):

```markdown
## Decomposition

### T1: <imperative title>
**Acceptance criteria:**
- [ ] <observable, testable criterion>
- [ ] <another>
**Scope:** <files/areas expected to change>
**Depends on:** none
**Out of scope:** <explicit exclusions>

### T2: <imperative title>
**Acceptance criteria:**
- [ ] <criterion>
**Scope:** <files/areas>
**Depends on:** T1
**Out of scope:** <exclusions>
```

If any task fails the sizing heuristics, split it before presenting the
spec. Recurring oversize discovered later (mid-implement handoffs) is
feedback to tighten this section's estimates.

## Override 3 — Terminal state

Brainstorming normally ends by invoking writing-plans. **Do not.**
Per-issue planning happens inside sdlc:implement, in fresh context. After
the spec is committed to `docs/specs/YYYY-MM-DD-<topic>.md` and the user
has approved it, end with exactly this handoff:

> "Spec committed to `<path>`. Run `/sdlc:ticket <path>` (fresh session
> recommended) to create the GitHub issues."
