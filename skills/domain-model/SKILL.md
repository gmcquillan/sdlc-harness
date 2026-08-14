---
name: domain-model
description: Use when a project's domain vocabulary needs pinning or reconciling — bootstraps or updates an in-repo ubiquitous-language glossary at docs/domain/glossary.md (each entry a term, a definition, and its disallowed aliases), seeding from a passed spec or a scout scan of the codebase, and writing only behind a dry-run approval gate committed to the current branch. Excludes the sdlc pipeline's own process vocabulary. Invoke as sdlc:domain-model [spec-path].
---

# SDLC Domain Model: vocabulary → committed glossary

The same domain concept drifts names across a feature's life — one session
calls it a `Widget`, a parallel one a `Gadget`, the spec called it an
`Item` — and the drift stays invisible until it has spread across merged
PRs. This skill gives a project **one committed, diffable glossary of its
domain terms**. Durable state lives in git as a reviewable markdown file,
not an external store or a session summary. The main loop holds judgment
and the human gate; breadth (scanning a codebase for recurring nouns) goes
to a scout. The `**Not:**` line of each entry is **one source with two
consumers**: human naming guidance now, and the machine-readable input to
the advisory drift check later. Create a todo per checklist item.

## The glossary — `docs/domain/glossary.md`

A single git-committed markdown file, one entry per term:

```markdown
### Widget
The unit of work a user schedules. Created by a Plan, consumed by a Run.
**Not:** Gadget, Item, Task, Job
```

A `### <Term>` heading (greppable and linkable), a one-to-two-sentence
definition, and a `**Not:** <aliases>` line listing the disallowed
synonyms. Every entry follows this shape exactly.

## Scope boundary

The glossary models the **target project's product/business domain**. It
**explicitly excludes the sdlc pipeline's own process vocabulary** —
`epic`, `task`, `ops`, `spec`, `decomposition`, `in-progress`,
`in-review`. Those are fixed plugin-level terms, not per-project domain;
capturing them would pollute a product glossary. Drop any candidate that
is one of them.

## Checklist

1. **Detect mode.** Does `docs/domain/glossary.md` exist? Absent →
   **bootstrap**. Present → **update/reconcile**.
2. **Gather candidates** (a spec path, when given, always seeds terms —
   in bootstrap it *is* the source; in update mode it re-seeds candidates
   that step 2's reconciliation then folds into the existing glossary):
   - **Spec path given** (`sdlc:domain-model docs/specs/…`): the main loop
     reads that one spec file and seeds candidate terms from it.
   - **Bootstrap, no spec path** (retrofit on an existing repo): dispatch
     ONE `fable-harness:scout` subagent to surface recurring domain nouns
     from the codebase; only its candidate list returns to you. Do NOT
     read the codebase file-by-file yourself.
   - **Update mode** (glossary exists): reconcile the existing entries
     against current usage — plus any spec-seeded candidates above —
     proposing terms to **add**, definitions/aliases to **change**, and
     stale terms to **remove**.
3. **Apply the scope boundary.** Drop every candidate that is sdlc process
   vocabulary (see above) before presenting anything.
4. **Dry-run gate.** Present the proposed entries as a table — Term |
   Definition | `Not:` aliases | add/change/remove — and get explicit
   approval BEFORE writing. This is a human gate; do not skip it, and do
   not write on the strength of your own judgment alone.
5. **Write + commit.** Write `docs/domain/glossary.md` in the documented
   format, then commit it to the **current branch** so edits made
   mid-feature ride in on that branch's PR. Never commit to `main`/
   `master`.
6. **Report.** State the committed path and mode, e.g.
   `"Glossary committed to docs/domain/glossary.md (bootstrap, N terms)."`

## Optional consult (how the pipeline reads this)

`interview`, `implement`, and `review` each carry a single conditional
line: *if `docs/domain/glossary.md` exists, read it and bind its canonical
terms.* With no glossary, those skills behave exactly as before — the
default path pays nothing.

## Red flags

- Writing the glossary before the dry-run approval → human gate violated.
- Capturing `epic`/`task`/`ops`/`spec`/`decomposition` → process
  vocabulary pollutes what should be a product glossary.
- Reading the codebase file-by-file in bootstrap → that is the scout's job.
- Committing to `main`/`master` → the glossary rides the current feature
  branch, not the shared base.
