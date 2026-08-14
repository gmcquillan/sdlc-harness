# Spec: `/sdlc:domain-model` — a ubiquitous-language glossary skill

## Intent

Across a feature's life, the same domain concept gets renamed by whoever
touches it: one `implement` session calls it a `Widget`, a parallel one
calls it a `Gadget`, the spec called it an `Item`. Nothing in the harness
holds a shared vocabulary, so the drift is invisible until it has spread
across several merged PRs. This skill gives a project **one committed,
diffable glossary of its domain terms** — pinned at spec time, bound by
every fresh session, and checked against PR diffs — without taxing the
common path when a feature's domain is trivial.

The idea is adapted from Matt Pocock's `domain-model` skill (ubiquitous
language / shared vocabulary). It is realized here in the harness's own
idiom: durable state lives in git as a reviewable file, not in an
external store or a session summary.

## Users

- **The human partner**, who reads the glossary as onboarding/domain doc
  and reviews changes to it in a normal PR diff.
- **Fresh pipeline sessions** (`interview`, `implement`, `review`), which
  read the glossary to bind canonical terms instead of reinventing names.

## Non-goals

- **Not** a cross-repo or organizational knowledge base. One glossary per
  project, scoped to that project. (Cross-project semantic recall, if ever
  wanted, is a *separate* future skill that points `qmd` at these files —
  not this one.)
- **Not** an external-store integration. `obsidian-vault`/`mem0`/`qmd`
  were scanned and rejected: an external artifact is not diffable in a PR
  and breaks "a dead session resumes from git." The glossary is an in-repo
  markdown file.
- **Not** a full domain model. Entries are term + definition + disallowed
  aliases — no relationship graphs or invariants (YAGNI for v1).
- **Not** a blocking gate. Drift detection is advisory; naming is a nudge,
  not a merge veto.
- **Not** a change to the harness's own process vocabulary. See
  **Scope boundary** below.

## Success criteria ("It's working if")

- You can bootstrap a glossary from a spec **or** from a codebase scan,
  approve it at a dry-run gate, and it commits as diffable markdown at
  `docs/domain/glossary.md`.
- A fresh `implement`/`review` session with a glossary present reads it
  and uses the canonical terms.
- `review` flags a disallowed alias introduced in a PR's added lines as an
  **advisory, non-blocking** naming-drift note.
- With **no** glossary present, every existing skill behaves byte-for-byte
  as it does today. The default path pays nothing.

## Constraints

- **Default path free.** The only change to `interview`/`implement`/
  `review` is a single conditional read guarded on the glossary existing.
- **Git-portable string matching.** The drift check must use the repo's
  established BSD/macOS-portable word-boundary idiom — a bracket class,
  **not** `\b` — per `tests/validate-skills.sh:71`.
- **Human-gated writes.** The skill presents a dry-run of proposed entries
  and writes only after explicit approval, mirroring `ticket`'s dry-run
  and `interview`'s commit-after-approval. The glossary commits to the
  **current branch**; edits made mid-feature ride in on that branch's PR.
- **Deterministic drift check.** Alias detection is pure string matching —
  run by the main loop, no reviewer subagent, no skeptic-verify round.

## Design

### Artifact — `docs/domain/glossary.md`

A single git-committed markdown file. One entry per term:

```markdown
### Widget
The unit of work a user schedules. Created by a Plan, consumed by a Run.
**Not:** Gadget, Item, Task, Job
```

The `### <Term>` heading keeps entries greppable and linkable; the
definition is one to two sentences; the `**Not:**` line lists disallowed
aliases. That `**Not:**` line is **one source with two consumers** —
human guidance *and* the machine-readable input to the drift check.

### The skill — author mode

`/sdlc:domain-model [spec-path]`:

- **Bootstrap** (no glossary yet): with a spec path, seed candidate terms
  from it; without one (retrofit on an existing repo), dispatch a **scout**
  subagent to surface recurring domain nouns from the codebase — only the
  candidate list returns to the main loop.
- **Update** (glossary exists): reconcile — propose added / changed /
  removed terms.
- **Gate + commit:** present the proposed entries as a dry-run table, wait
  for approval, then write and commit `docs/domain/glossary.md` to the
  current branch.

### Scope boundary

The glossary models the **target project's product/business domain**. It
**explicitly excludes the sdlc pipeline's own process vocabulary** —
`epic`, `task`, `ops`, `spec`, `decomposition`, `in-progress`,
`in-review`. Those are fixed plugin-level terms, not per-project domain;
capturing them would pollute a product glossary. (Standardizing the
harness's *own* vocabulary — including the un-namespaced `ops` label — is a
separate follow-up that dogfoods this skill once it ships.)

### Optional consult

`interview`, `implement`, and `review` each gain a single conditional
line: *"If `docs/domain/glossary.md` exists, read it and bind its
canonical terms."* No file → behavior is unchanged.

### Drift check in `review`

A deterministic step in `review`, run by the main loop: extract the
`**Not:**` aliases from the glossary, grep the PR's **added** diff lines
for them, and report hits as `file:line — 'Gadget' found — should be
'Widget'`, in the same shape the other review dimensions use. Advisory and
non-blocking. The matching logic lives in a small, unit-testable `bin/`
helper following the `bin/sdlc-backend.sh sniff` template, using the
bracket-class word boundary (not `\b`).

## Decomposition

### T1: Build the `domain-model` skill, glossary format, and consults
**Acceptance criteria:**
- [ ] `skills/domain-model/SKILL.md` exists with valid frontmatter (`name: domain-model`; description invokes it as `sdlc:domain-model`) and passes `tests/validate-skills.sh`.
- [ ] Invoked with no existing glossary, the skill bootstraps `docs/domain/glossary.md` — seeding from a passed spec path when given, else via a scout scan of the codebase — and writes only after a dry-run approval gate.
- [ ] Invoked when the glossary exists, the skill enters update/reconcile mode and proposes add/change/remove behind the same gate.
- [ ] Glossary entries follow the documented format: a `### <Term>` heading, a definition, and a `**Not:** <aliases>` line.
- [ ] The skill documents the scope boundary: it models product-domain vocabulary and excludes sdlc process terms (epic/task/ops/spec/decomposition).
- [ ] `skills/interview/SKILL.md`, `skills/implement/SKILL.md`, and `skills/review/SKILL.md` each gain exactly one conditional consult line (read the glossary iff it exists); with no glossary, each behaves as before.
- [ ] A human-facing doc under `docs/` describes the skill and includes an "It's working if" success signal.
**Scope:** `skills/domain-model/SKILL.md` (new); one-line edits to `skills/interview/SKILL.md`, `skills/implement/SKILL.md`, `skills/review/SKILL.md`; `tests/validate-skills.sh`; `README.md` (skills table); a new doc under `docs/`.
**Depends on:** none
**Out of scope:** drift detection (T2); any change to the harness's own ticket vocabulary; JIRA-adapter changes.

### T2: Add the advisory drift check to `review`
**Acceptance criteria:**
- [ ] A new `bin/` helper extracts `**Not:**` aliases from `docs/domain/glossary.md` and greps a given diff/branch's **added** lines, emitting `file:line — '<alias>' found — should be '<canonical>'`.
- [ ] The helper's matching uses the BSD/macOS-portable bracket-class word boundary (no `\b`), consistent with `tests/validate-skills.sh:71`.
- [ ] A test under `tests/` exercises the helper: a seeded glossary plus a diff containing an alias reports the violation; a clean diff reports nothing; the test follows the suite's existing BSD-portability conventions.
- [ ] `skills/review/SKILL.md` gains a deterministic drift-check step (main loop; no reviewer subagent; no skeptic round) that runs the helper when the glossary exists and folds hits into the review body as advisory, non-blocking findings.
- [ ] With no glossary present, `review` behaves byte-for-byte as it does today.
**Scope:** a new `bin/` helper; a new test under `tests/`; `skills/review/SKILL.md`.
**Depends on:** T1
**Out of scope:** making drift a blocking gate; auto-suggesting new terms; any hook-based enforcement.
