---
name: ticket
description: Use when a committed SDLC spec with a Decomposition section needs tickets created — translates each decomposition task into a PR-scoped child ticket under one epic, with a dry-run approval gate and idempotency check. Invoke as sdlc:ticket <spec-path>.
---

# SDLC Ticket: Spec → Tickets

Pure translation plus `gh` calls. Create a todo per checklist item.

## Checklist

0. **Resolve the backend:** run `sdlc-backend.sh resolve`. On `use-github`
   continue below unchanged; on `use-jira` read and follow the plugin's
   `references/backend-jira.md`; on `bind-needed`, `backend-bind.md`.
1. **Preconditions:** `gh auth status` succeeds (else stop; tell the user
   to run `! gh auth login`). The spec path argument exists and contains
   a `## Decomposition` section (else stop and say what is missing —
   re-run sdlc:interview to produce one).
2. **Idempotency check:** derive the spec slug (filename minus date and
   extension). Search: `gh issue list --label "sdlc:epic" --state all
   --search "<slug>" --json number,title`. If an epic exists, STOP and
   ask: update the existing epic in place, or abort? Never silently
   duplicate.
3. **Ensure labels** (idempotent):

   ```bash
   for l in "sdlc:epic" "sdlc:task" "sdlc:in-progress" "sdlc:in-review"; do
     gh label create "$l" --force --description "sdlc pipeline"
   done
   ```

4. **Dry-run gate:** parse every `### T<n>:` block and present a table —
   T#, title, criteria count, depends-on — headed by
   `Backend: <github|jira> · Project: <owner/name or JIRA key>`, both
   read off step 0's resolve output: `backend`, or `github` when it is
   null; `project`, or when that is null the `owner/name` tail of `repo`
   (which reads `host/owner/name`, or `path:<dir>` for a repo with no
   origin — show that one whole). Then the epic title
   (`[epic] <spec slug>`). Get explicit user approval BEFORE
   creating anything. This is a human gate; do not skip it — the
   `Backend:` line is what stops an epic being filed into the wrong
   system.
5. **Create the epic** (placeholder body; task list is filled in step 7):

   ```bash
   gh issue create --label "sdlc:epic" --title "[epic] <slug>" \
     --body "Spec: \`<spec-path>\` (commit <hash>)

   Task list populated after child issues are created."
   ```

6. **Create child issues**, one per decomposition task, in T-order (so
   depends-on references point backward at existing issues). Record each
   created ref to translate `T<n>` → `<ref>`:

   ```bash
   gh issue create --label "sdlc:task" --title "<T-title>" --body "## Context
   <one paragraph> — spec §T<n> in \`<spec-path>\`

   ## Acceptance criteria
   - [ ] <copied verbatim from the spec>

   ## Scope
   <files/areas from the spec>

   ## Depends on
   <#refs translated from T-refs, or 'none'>

   ## Out of scope
   <from the spec>

   ## Epic
   #<epic-number>"
   ```

7. **Fill the epic task list** so progress renders on the epic:

   ```bash
   gh issue edit <epic#> --body "Spec: \`<spec-path>\` (commit <hash>)

   ## Tasks
   - [ ] #<child1> <title1>
   - [ ] #<child2> <title2>"
   ```

8. **Report:** epic URL, child count, and: "Run `/sdlc:implement` (fresh
   session recommended) to pick up the first unblocked issue."

## Red flags

- Creating issues before the dry-run approval → human gate violated.
- Children created out of dependency order → forward refs that
  don't exist yet.
