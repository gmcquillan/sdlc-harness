# domain-model Skill (T1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this plan is executed **inline** by its author via superpowers:executing-plans (tasks are tightly-coupled prose sharing one voice; per-task subagent setup exceeds the benefit). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the standalone `/sdlc:domain-model` skill that maintains an in-repo ubiquitous-language glossary at `docs/domain/glossary.md`, plus one conditional consult line in each of interview/implement/review, per spec §T1.

**Architecture:** A new `skills/domain-model/SKILL.md` documents an author-mode workflow (bootstrap-or-update → dry-run gate → commit to current branch). Durable state is a git-committed markdown file, not an external store. The three pipeline skills each gain a single conditional read guarded on the glossary existing, so the default path (no glossary) pays nothing. The skills validator (`tests/validate-skills.sh`) is a hardcoded allowlist, so `domain-model` must be registered there to be checked.

**Tech Stack:** Markdown SKILL.md files; POSIX/bash `tests/validate-skills.sh`; `gh`/git for delivery. No runtime code in T1 (the `bin/` drift helper is T2, out of scope).

## Global Constraints

- **Default path free.** The only change to `interview`/`implement`/`review` is a single conditional read guarded on `docs/domain/glossary.md` existing. With no glossary, each skill behaves byte-for-byte as today.
- **Human-gated writes.** The skill presents a dry-run of proposed entries and writes only after explicit approval, mirroring `ticket`'s dry-run and `interview`'s commit-after-approval. The glossary commits to the **current branch**.
- **Scope boundary is product-domain only.** The glossary excludes the sdlc pipeline's own process vocabulary: `epic`, `task`, `ops`, `spec`, `decomposition`, `in-progress`, `in-review`.
- **Glossary entry format (verbatim target):**
  ```markdown
  ### Widget
  The unit of work a user schedules. Created by a Plan, consumed by a Run.
  **Not:** Gadget, Item, Task, Job
  ```
  A `### <Term>` heading, a one-to-two-sentence definition, and a `**Not:** <aliases>` line.
- **Validator facts:** `tests/validate-skills.sh` discovery is the hardcoded allowlist on line 11 (`expected="..."`), NOT a glob. Frontmatter must be `---`-fenced with `name:` equal to the directory name and `description:` beginning literally `Use when`. Do **not** add `domain-model` to `pipeline` (line ~32) or `gh_floors` (line ~77): it has no step-0 backend-resolve block and shells out to no `gh`.
- **Drift detection (T2) is out of scope.** No `bin/` helper, no grep-of-diff logic, no changes to `review`'s body beyond the single consult line.

---

## File Structure

- **Create** `skills/domain-model/SKILL.md` — the skill: author-mode checklist, glossary format, scope boundary, dry-run gate, scout dispatch.
- **Modify** `tests/validate-skills.sh:11` — append `domain-model` to the `expected` allowlist.
- **Modify** `skills/interview/SKILL.md`, `skills/implement/SKILL.md`, `skills/review/SKILL.md` — one conditional consult line each, placed outside any step-0 block and containing no `gh ` token.
- **Modify** `README.md` (skills table, ~line 142) — one `sdlc:domain-model` row.
- **Create** `docs/2026-08-14-domain-model-skill-design.md` — human-facing doc with an "It's working if" section.

---

## Task 1: Register + author the `domain-model` skill (red → green)

**Files:**
- Modify: `tests/validate-skills.sh:11`
- Create: `skills/domain-model/SKILL.md`

**Interfaces:**
- Produces: the skill directory name `domain-model` and frontmatter `name: domain-model`; the on-disk artifact path `docs/domain/glossary.md`; the entry format consumed conceptually by the consults (Task 2) and the doc (Task 3).

- [ ] **Step 1 — Write the failing test.** Append `domain-model` to the allowlist so the validator now expects a file that doesn't exist yet:
  - `tests/validate-skills.sh:11` → `expected="interview ticket next implement review handoff resume cleanup fixes domain-model"`
- [ ] **Step 2 — Run to verify it fails.** Run: `bash tests/validate-skills.sh`. Expected: FAIL — `FAIL: skills/domain-model/SKILL.md missing` (or the frontmatter-fence failure), `failed>=1`.
- [ ] **Step 3 — Write `skills/domain-model/SKILL.md`.** Frontmatter (exactly two keys; `name` = dir; description begins `Use when`, ends `Invoke as sdlc:domain-model [spec-path].`):
  - `description` names the trigger (a project's domain vocabulary needs pinning/reconciling), the artifact (`docs/domain/glossary.md`), the entry shape (term + definition + disallowed aliases), the dry-run gate, and commit-to-current-branch.
  - Body sections (house style — framing paragraph ending "Create a todo per checklist item.", then numbered `## Checklist` with bold-imperative labels, then `## Red flags` with `mistake → consequence` arrows):
    - **Framing:** durable state lives in git as a reviewable file; main loop holds judgment, breadth goes to a scout; the `**Not:**` line is one source with two consumers (human guidance + machine input for the future drift check).
    - **`## The glossary` / format block:** the verbatim `### Widget … **Not:**` example from Global Constraints.
    - **`## Scope boundary`:** models the target project's product/business domain; explicitly EXCLUDES sdlc process vocabulary — name `epic`, `task`, `ops`, `spec`, `decomposition`, `in-progress`, `in-review`.
    - **`## Checklist`:**
      1. **Detect mode:** does `docs/domain/glossary.md` exist? → bootstrap vs update/reconcile.
      2. **Gather candidates:** spec-path arg → seed terms from that one spec (main loop reads it); no arg + bootstrap → dispatch ONE scout to surface recurring domain nouns, only the candidate list returns, do NOT read the codebase file-by-file; update mode → reconcile existing entries against current usage, proposing add/change/remove.
      3. **Apply the scope boundary:** drop any candidate that is sdlc process vocab.
      4. **Dry-run gate:** present proposed entries as a table (Term | Definition | Not: aliases | add/change/remove) and get explicit approval BEFORE writing. Human gate; do not skip.
      5. **Write + commit:** write `docs/domain/glossary.md` in the documented format; commit to the CURRENT branch so edits ride in on that branch's PR.
      6. **Report:** verbatim terminal message pointing at the committed path.
    - **`## Red flags`:** writing before dry-run approval → human gate violated; capturing epic/task/ops/spec/decomposition → process vocab pollutes a product glossary; reading the codebase file-by-file in bootstrap → that is the scout's job; committing to main/master → the glossary rides the current feature branch.
- [ ] **Step 4 — Run to verify it passes.** Run: `bash tests/validate-skills.sh`. Expected: `ok: domain-model` present; `failed=0`; `passed` count increased by 1 (24).
- [ ] **Step 5 — Commit.**
  ```bash
  git add tests/validate-skills.sh skills/domain-model/SKILL.md
  git commit -m "feat(domain-model): add skill + register in validator (#27)"
  ```

---

## Task 2: Add the three conditional consult lines

**Files:**
- Modify: `skills/interview/SKILL.md`
- Modify: `skills/implement/SKILL.md`
- Modify: `skills/review/SKILL.md`

**Interfaces:**
- Consumes: the artifact path `docs/domain/glossary.md` (Task 1).
- Produces: nothing downstream; each edit is exactly one line, conditional on the glossary existing, with no `gh ` token and outside any step-0 block.

- [ ] **Step 1 — Write the consult line into each skill.** Add exactly one conditional line to each, phrased: *If `docs/domain/glossary.md` exists, read it and bind its canonical terms* (adapted to each skill's local step). Placement:
  - `interview`: in the intent/brainstorming phase (so spec terms align to the glossary) — NOT in any step-0/handoff block.
  - `implement`: within step 4 (**Understand**), after the systems-mapping line.
  - `review`: in the acceptance-criteria/context reading step — a plain consult only (drift check is T2), no `gh`, outside step 0.
- [ ] **Step 2 — Verify presence.** Run:
  ```bash
  grep -l 'docs/domain/glossary.md' skills/interview/SKILL.md skills/implement/SKILL.md skills/review/SKILL.md
  ```
  Expected: all three paths listed.
- [ ] **Step 3 — Verify the default path is untouched.** Run: `bash tests/validate-skills.sh`. Expected: `failed=0`; the gh-floor lines still read `implement: 7 … (floor 7)` and `review: 7 … (floor 7)` and every `step 0 resolves the backend` check still `ok` — proving the consult line perturbed neither the gh count nor the step-0 block.
- [ ] **Step 4 — Commit.**
  ```bash
  git add skills/interview/SKILL.md skills/implement/SKILL.md skills/review/SKILL.md
  git commit -m "feat(domain-model): conditional glossary consult in interview/implement/review (#27)"
  ```

---

## Task 3: README skills-table row + human-facing design doc

**Files:**
- Modify: `README.md` (skills table, after the `sdlc:cleanup` row ~line 142)
- Create: `docs/2026-08-14-domain-model-skill-design.md`

**Interfaces:**
- Consumes: skill name/behavior (Task 1), consult behavior (Task 2).

- [ ] **Step 1 — Add the README row.** Insert one pipe-delimited row matching the table's format:
  `| `sdlc:domain-model [spec]` | Bootstrap/update an in-repo ubiquitous-language glossary (`docs/domain/glossary.md`), dry-run gated |`
- [ ] **Step 2 — Write the design doc.** `docs/2026-08-14-domain-model-skill-design.md`, mirroring the repo's dated-design-doc convention. Sections: `# Design: sdlc:domain-model — a ubiquitous-language glossary skill`; `## Purpose`; `## Invocation`; `## The glossary artifact` (format block); `## Scope boundary` (excludes process vocab); `## The optional consult` (one conditional read; default path free); `## It's working if` (adapt the spec's success-criteria bullets: bootstrap-from-spec-or-scan → approve at gate → diffable commit; fresh implement/review reads it and uses canonical terms; with no glossary every skill behaves byte-for-byte as today); `## Out of scope` (drift detection T2; harness's own vocabulary; JIRA-adapter changes).
- [ ] **Step 3 — Verify.** Run:
  ```bash
  grep -q 'sdlc:domain-model' README.md && echo README-ok
  grep -q "It's working if" docs/2026-08-14-domain-model-skill-design.md && echo doc-ok
  ```
  Expected: `README-ok` and `doc-ok`.
- [ ] **Step 4 — Commit.**
  ```bash
  git add README.md docs/2026-08-14-domain-model-skill-design.md
  git commit -m "docs(domain-model): README row + design doc (#27)"
  ```

---

## Acceptance-Criteria Traceability

| AC (issue #27) | Task/step |
|---|---|
| SKILL.md valid frontmatter + passes validate-skills.sh | T1 S1–S4 |
| Bootstrap (spec-seed / scout-scan) behind dry-run gate | T1 S3 (Checklist 2, 4, 5) |
| Update/reconcile mode behind same gate | T1 S3 (Checklist 1, 2, 4) |
| Entry format `### Term` / definition / `**Not:**` | T1 S3 (format block) |
| Scope boundary excludes epic/task/ops/spec/decomposition | T1 S3 (Scope boundary) |
| Exactly one conditional consult line in each of 3 skills; default unchanged | T2 S1–S3 |
| Human-facing doc under `docs/` with "It's working if" | T3 S2 |

## Self-Review Notes

- **Coverage:** every §T1 acceptance criterion maps to a task above (see traceability table).
- **Default-path guard:** T2 S3 is the explicit regression check that the consults didn't change gh-floors or step-0 detection — the load-bearing "default path free" evidence.
- **Out of scope held:** no `bin/` helper, no drift grep, no marketplace.json edit (not machine-validated, not in AC scope).
