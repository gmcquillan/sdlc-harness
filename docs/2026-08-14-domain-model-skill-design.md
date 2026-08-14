# Design: `sdlc:domain-model` — a ubiquitous-language glossary skill

## Purpose

Across a feature's life, the same domain concept gets renamed by whoever
touches it: one `implement` session calls it a `Widget`, a parallel one a
`Gadget`, the spec called it an `Item`. Nothing else in the harness holds a
shared vocabulary, so the drift is invisible until it has spread across
several merged PRs. `sdlc:domain-model` gives a project **one committed,
diffable glossary of its domain terms** — pinned at spec time, bound by
every fresh session, reviewed in a normal PR diff — without taxing the
common path when a feature's domain is trivial.

Durable state lives in git as a reviewable markdown file, not in an
external store or a session summary: a dead session resumes from git, and
the glossary shows up in a PR diff like any other change.

## Invocation

```
/sdlc:domain-model [spec-path]
```

- **With a spec path** — seed candidate terms from that spec.
- **Without one** — bootstrap by dispatching a scout to surface recurring
  domain nouns from the codebase (retrofit on an existing repo), or, when
  the glossary already exists, enter update/reconcile mode.

Every write is behind a **dry-run approval gate** and commits to the
**current branch**, so edits made mid-feature ride in on that branch's PR
(mirroring `ticket`'s dry-run and `interview`'s commit-after-approval).

## The glossary artifact

A single git-committed file at `docs/domain/glossary.md`, one entry per
term:

```markdown
### Widget
The unit of work a user schedules. Created by a Plan, consumed by a Run.
**Not:** Gadget, Item, Task, Job
```

A `### <Term>` heading keeps entries greppable and linkable; the definition
is one to two sentences; the `**Not:**` line lists the disallowed aliases.
That `**Not:**` line is **one source with two consumers** — human naming
guidance, and the machine-readable input to the advisory drift check that
`review` gains in a follow-up.

## Scope boundary

The glossary models the **target project's product/business domain**. It
**explicitly excludes the sdlc pipeline's own process vocabulary** —
`epic`, `task`, `ops`, `spec`, `decomposition`, `in-progress`,
`in-review`. Those are fixed plugin-level terms, not per-project domain;
capturing them would pollute a product glossary.

## The optional consult

`interview`, `implement`, and `review` each carry a single conditional
line: *if `docs/domain/glossary.md` exists, read it and bind its canonical
terms.* With **no** glossary present, every one of those skills behaves
byte-for-byte as it does today — the default path pays nothing.

## It's working if

- You can bootstrap a glossary from a spec **or** from a codebase scan,
  approve it at a dry-run gate, and it commits as diffable markdown at
  `docs/domain/glossary.md`.
- A fresh `implement`/`review` session with a glossary present reads it
  and uses the canonical terms instead of reinventing names.
- Re-running the skill with the glossary present proposes add/change/remove
  entries behind the same gate — it reconciles rather than duplicating.
- With **no** glossary present, `interview`/`implement`/`review` behave
  exactly as before. The default path pays nothing.

## Out of scope

- **Drift detection** — the deterministic `**Not:**`-alias check in
  `review` and its `bin/` helper land in a follow-up (spec §T2).
- **The harness's own vocabulary** — standardizing sdlc process terms
  (including the un-namespaced `ops` label) is a separate follow-up that
  dogfoods this skill once it ships.
- **JIRA-adapter changes** — none; the glossary is backend-agnostic.
- **Cross-repo / external-store knowledge bases** — one glossary per
  project, in-repo. `obsidian-vault`/`mem0`/`qmd` were considered and
  rejected: an external artifact is not diffable in a PR.
