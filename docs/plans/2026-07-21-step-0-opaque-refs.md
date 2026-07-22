# Step 0 and Opaque Ticket References Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `ticket`, `next`, `implement`, and `review` a three-line
step 0 that resolves the ticket backend, and generalize ticket references
across the seven pipeline skills from GitHub's `#<n>` to an opaque
`<ref>` — without altering a single inline `gh` command.

**Architecture:** These files are prose read by a model, not executable
code. The change is therefore surgical text editing under two hard
invariants: (1) the 27 `gh`-bearing lines in `skills/` stay byte-identical,
and (2) the existing numbered steps keep their numbers, because
`references/backend-jira.md`'s routing table addresses skill steps by
number. Step 0 is inserted as a literal `0.` list item ahead of an
unchanged `1.`. JIRA-specific behavior is added nowhere — it already
lives in `references/backend-jira.md`, which needs no edit.

**Tech Stack:** Markdown skill files; `bash` test harness
(`tests/*.sh`); `bin/sdlc-backend.sh` (already shipped on `main`).

## Global Constraints

- **No `gh` command may change by one byte.** Verified by diffing a
  pre-edit snapshot of `grep -rh '\bgh ' skills/` against a post-edit
  one. This includes the `--body` payloads of `gh issue create` and
  `gh pr create`, which contain `#<n>` refs that MUST survive.
- **Never renumber an existing step.** `references/backend-jira.md:27-38`
  cites `ticket` 2/5/6/7, `next` 2, `implement` 1/3/11, `review` 1/5,
  `resume` 3. All ten are correct on `main` and must stay correct.
- **`references/backend-jira.md` and `references/backend-bind.md` are
  not edited by this plan.** If a change seems to require editing them,
  the change is wrong.
- **No skill may name the nine operations** (`create_epic`, `get_state`,
  …). Per the design: "The skills do not name them at all."
- **No new file is created except this plan.** In particular, no
  `backend-github.md`.
- Body text wraps at ~72–75 columns (repo p95 = 74).
- Invoke the script by bare name: `sdlc-backend.sh resolve`. Never
  `bin/sdlc-backend.sh`, never `"${CLAUDE_PLUGIN_ROOT}/bin/…"`.

## File Structure

| File | Change |
|---|---|
| `skills/ticket/SKILL.md` | step 0; `Backend:` line on the dry-run gate; T→ref prose |
| `skills/next/SKILL.md` | step 0; node shape `{number→ref}`; ref prose in model/readiness/report |
| `skills/implement/SKILL.md` | step 0; branch → `sdlc/<ref>-<slug>`; ref prose; frontmatter |
| `skills/review/SKILL.md` | step 0; ticket resolution from PR generalized; epic ref prose |
| `skills/handoff/SKILL.md` | template: `Ticket: <ref>` + `Backend:` line; branch pattern |
| `skills/resume/SKILL.md` | step 3 reads the recorded backend before its `gh` call |
| `skills/cleanup/SKILL.md` | branch pattern prose widened to both ref forms |

The step-0 block is **byte-identical across all four** skills that get
it — one string, four insertion points.

---

### Task 1: Snapshot the invariant, then add step 0 to the four resolving skills

**Files:**
- Modify: `skills/ticket/SKILL.md` (insert after `## Checklist`, line 10)
- Modify: `skills/next/SKILL.md` (insert after `## Checklist`, line 36)
- Modify: `skills/implement/SKILL.md` (insert after `## Checklist`, line 14)
- Modify: `skills/review/SKILL.md` (insert after `## Checklist`, line 11)
- Test: `/tmp/gh-before.txt` (the byte-identity snapshot, captured in
  Step 1 below and diffed against in every subsequent task)

**Interfaces:**
- Consumes: `sdlc-backend.sh resolve` → JSON with `action` ∈
  {`use-github`, `use-jira`, `bind-needed`}.
- Produces: the literal step-0 text reused verbatim by Tasks 2–4.

- [ ] **Step 1: Capture the byte-identity baseline**

```bash
grep -rh '\bgh ' skills/ | sed 's/^[[:space:]]*//' | sort > /tmp/gh-before.txt
wc -l < /tmp/gh-before.txt   # expect 27
```

- [ ] **Step 2: Insert this exact block as the first list item under
      `## Checklist` in each of the four skills**

```markdown
0. **Resolve the backend:** run `sdlc-backend.sh resolve`. On `use-github`
   continue below unchanged; on `use-jira` read `references/backend-jira.md`;
   on `bind-needed` read `references/backend-bind.md` and follow it.
```

Three lines. Insert it directly above the existing `1.` item, separated
by a blank line, leaving `1.`…`N.` untouched.

- [ ] **Step 3: Verify no step was renumbered**

```bash
for f in ticket next implement review handoff resume cleanup; do
  echo "== $f"; grep -nE '^[0-9]+\. ' "skills/$f/SKILL.md" | head -20
done
```
Expected: `ticket` shows `0.` then `1.`…`8.`; `next` `0.` then `1.`…`7.`;
`implement` `0.` then `1.`…`12.`; `review` `0.` then `1.`…`5.`;
`handoff`/`resume`/`cleanup` unchanged and with **no** `0.`.

- [ ] **Step 4: Verify byte-identity of every `gh` command**

```bash
grep -rh '\bgh ' skills/ | sed 's/^[[:space:]]*//' | sort > /tmp/gh-after.txt
diff /tmp/gh-before.txt /tmp/gh-after.txt && echo "IDENTICAL"
```
Expected: `IDENTICAL`, empty diff.

- [ ] **Step 5: Verify the routing table's step citations still resolve**

```bash
grep -n 'step [0-9]' references/backend-jira.md
```
Expected: every cited number still names the same command in the skill —
checked by hand against the outline from Step 3. No edit to
`backend-jira.md`.

- [ ] **Step 6: Commit**

```bash
git add skills/ticket/SKILL.md skills/next/SKILL.md \
        skills/implement/SKILL.md skills/review/SKILL.md
git commit -m "feat(skills): resolve the ticket backend in a step 0"
```

---

### Task 2: Generalize `ticket` — the `Backend:` gate line and the T→ref translation

**Files:**
- Modify: `skills/ticket/SKILL.md` (step 4 dry-run gate; step 6 prose)

**Interfaces:**
- Consumes: step 0 from Task 1.
- Produces: a dry-run gate naming backend and project — the human gate
  that prevents filing into the wrong system.

- [ ] **Step 1: Replace the dry-run gate step (currently step 4)**

From:
```markdown
4. **Dry-run gate:** parse every `### T<n>:` block and present a table —
   T#, title, criteria count, depends-on — plus the epic title
   (`[epic] <spec slug>`). Get explicit user approval BEFORE creating
   anything. This is a human gate; do not skip it.
```
To:
```markdown
4. **Dry-run gate:** parse every `### T<n>:` block and present a table —
   T#, title, criteria count, depends-on — headed by
   `Backend: <github|jira> · Project: <owner/repo or JIRA key>` and the
   epic title (`[epic] <spec slug>`). Get explicit user approval BEFORE
   creating anything. This is a human gate; do not skip it — the
   `Backend:` line is what stops an epic being filed into the wrong
   system.
```

- [ ] **Step 2: Generalize the T→ref translation prose (step 6, line ~44)**

From: ``Record each created number to translate `T<n>` → `#<issue>` ``
To:   ``Record each created ref to translate `T<n>` → `<ref>` ``

Do **not** touch the `gh issue create` block below it — its `#refs`
body text is part of a `gh` command.

- [ ] **Step 3: Verify `gh` byte-identity and run the suite**

```bash
grep -rh '\bgh ' skills/ | sed 's/^[[:space:]]*//' | sort > /tmp/gh-after.txt
diff /tmp/gh-before.txt /tmp/gh-after.txt && echo "IDENTICAL"
grep -n 'Backend:' skills/ticket/SKILL.md
```
Expected: `IDENTICAL`; the `Backend:` line present in step 4.

- [ ] **Step 4: Commit**

```bash
git add skills/ticket/SKILL.md
git commit -m "feat(ticket): name backend and project on the dry-run gate"
```

---

### Task 3: Generalize `next` — node shape and reference prose

**Files:**
- Modify: `skills/next/SKILL.md` (leverage model ~L16; readiness ~L30;
  scout node shape ~L45; epic scoping ~L52; report format ~L63-76)

**Interfaces:**
- Consumes: step 0 from Task 1.
- Produces: node shape `{ref, title, dependsOn, inProgress, inReview,
  assigned, ops, createdAt}` — the shape `references/backend-jira.md:350`
  requires the JIRA gather-scout to normalize into. The key rename from
  `number` to `ref` is what makes that reference true.

- [ ] **Step 1: Rename the node-shape key**

From: `{number, title, dependsOn:[#…], inProgress, inReview, assigned,`
To:   `{ref, title, dependsOn:[…], inProgress, inReview, assigned,`

- [ ] **Step 2: Generalize reference wording (prose only — never a `gh` line)**

- Leverage model: ``a `## Depends on` section of `#refs` `` → ``a
  `## Depends on` section of ticket refs``
- Readiness test item 3: ``Every `#ref` under its `## Depends on` heading
  is CLOSED`` → ``Every ref under its `## Depends on` heading is CLOSED``
- Scout step: ``parses the `## Depends on` section into `#refs` `` →
  ``parses the `## Depends on` section into refs``; ``the OPEN/CLOSED
  state of every `#ref` `` → ``…of every ref``
- Report format: `#<n> — <title>` → `<ref> — <title>`; `"unblocks N: #a
  #b …"` → `"unblocks N: <ref> <ref> …"`
- Handoff prompt: ``Next: #<n> (unblocks N). Proceed to implement?
  [Enter=yes / #=other]`` → ``Next: <ref> (unblocks N). Proceed to
  implement? [Enter=yes / ref=other]``

Leave the worked examples (`#48`, `#40, #41`, `#44`) as they are — they
are illustrations of a GitHub backlog, not normative reference syntax.

- [ ] **Step 3: Verify the two `gh` lines in this file are untouched**

```bash
grep -n 'gh issue' skills/next/SKILL.md
```
Expected exactly:
`gh issue list --label "sdlc:task" --state open --json`
`gh issue view <ref> --json number,state`

- [ ] **Step 4: Verify byte-identity, then commit**

```bash
grep -rh '\bgh ' skills/ | sed 's/^[[:space:]]*//' | sort > /tmp/gh-after.txt
diff /tmp/gh-before.txt /tmp/gh-after.txt && echo "IDENTICAL"
git add skills/next/SKILL.md
git commit -m "feat(next): treat ticket references as opaque refs"
```

---

### Task 4: Generalize `implement` and `review` — branch naming and ticket resolution

**Files:**
- Modify: `skills/implement/SKILL.md` (frontmatter; step 1 prose; step 5
  branch; step 11 `git push` line)
- Modify: `skills/review/SKILL.md` (step 1 ticket resolution; step 5
  tier-B epic prose)

**Interfaces:**
- Consumes: step 0 from Task 1.
- Produces: the branch name `sdlc/<ref>-<slug>` that Task 6's `cleanup`
  prose and Task 5's handoff template both describe.

- [ ] **Step 1: `implement` — branch pattern, both occurrences**

Step 5 prose: ``branch `sdlc/<issue#>-<slug>` (slug = kebab-cased issue
title, ≤5 words)`` → ``branch `sdlc/<ref>-<slug>` (slug = kebab-cased
ticket title, ≤5 words) — `sdlc/42-add-widget` or
`sdlc/PROJ-123-add-widget` ``

Step 11 code block, the **`git`** line (not a `gh` line, so it may
change):
`git push -u origin "sdlc/<issue#>-<slug>"` →
`git push -u origin "sdlc/<ref>-<slug>"`

**Leave the three `gh` lines in that block exactly as they are**,
including `Closes #<issue>` and `Epic: #<epic>` inside the `gh pr create`
body. The JIRA PR title/body shape lives in `references/backend-jira.md`.

- [ ] **Step 2: `implement` — step 1 prose and frontmatter**

- Step 1 readiness: ``every `#ref` under its `## Depends on` heading is
  CLOSED`` → ``every ref under its `## Depends on` heading is CLOSED``
- Frontmatter description: `Use when an sdlc:task GitHub issue is ready
  to build` → `Use when an sdlc:task ticket is ready to build`, and
  `Invoke as sdlc:implement [issue#]` → `Invoke as sdlc:implement [ref]`.
  The description must still begin `Use when` — `validate-skills.sh`
  asserts it.

- [ ] **Step 3: `review` — generalize ticket resolution from the PR**

From:
```markdown
   `gh pr view <PR#> --json title,body,headRefName,files` — extract the
   linked issue from `Closes #<n>`, then
```
To:
```markdown
   `gh pr view <PR#> --json title,body,headRefName,files` — extract the
   linked ticket ref from the PR body (`Closes #<n>` on GitHub), then
```
The `gh pr view` and `gh issue view` commands themselves are unchanged.

Tier B epic prose: ``the `#<n>` under that heading`` → ``the ref under
that heading``. The `gh issue create` block below it is untouched.

- [ ] **Step 4: Confirm the approval line was NOT changed**

```bash
grep -n 'Ready for your merge decision' skills/review/SKILL.md
```
Expected: `Approval ends with: "Ready for your merge decision."` — the
JIRA variant ("…the ticket stays open until you move it") belongs to
`references/backend-jira.md` and must not appear here.

- [ ] **Step 5: Verify byte-identity, run the suite, commit**

```bash
grep -rh '\bgh ' skills/ | sed 's/^[[:space:]]*//' | sort > /tmp/gh-after.txt
diff /tmp/gh-before.txt /tmp/gh-after.txt && echo "IDENTICAL"
bash tests/validate-skills.sh
git add skills/implement/SKILL.md skills/review/SKILL.md
git commit -m "feat(implement,review): key branches and lookups on an opaque ref"
```
Expected: `IDENTICAL`; `passed=8 failed=0`.

---

### Task 5: Retarget the handoff/resume contract

**Files:**
- Modify: `skills/handoff/SKILL.md` (template `## Refs` and `## State`)
- Modify: `skills/resume/SKILL.md` (step 3 verification)
- Test: `tests/test-handoff-pickup.sh`, `tests/test-handoff-worktree.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the handoff-file contract `resume` parses. `handoff` writes
  `Ticket:`/`Backend:`; `resume` reads them. **Both files must change in
  this one commit** — `handoff/SKILL.md` says "keep these exact headings
  — sdlc:resume parses them."

- [ ] **Step 1: `handoff` — the `## Refs` block**

From:
```markdown
   - Issue: #<n> / PR: #<n> / Epic: #<n>
   - Branch: sdlc/<issue#>-<slug>
```
To:
```markdown
   - Ticket: <ref> / PR: #<n> / Epic: <ref>
   - Backend: <github|jira>
   - Branch: sdlc/<ref>-<slug>
```
`PR:` keeps `#<n>` — pull requests are always GitHub.

- [ ] **Step 2: `handoff` — the `## State` block**

From: `- Labels set: <e.g. sdlc:in-progress on #12>`
To:   `- Labels set: <e.g. sdlc:in-progress on <ref>>`

- [ ] **Step 3: `resume` — step 3 verification bullet**

From:
```markdown
   - Issue/PR labels as recorded? (`gh issue view <n> --json labels`)
```
To:
```markdown
   - Ticket labels as recorded, on the backend `## Refs` names? Where
     that is not `github`, read `references/backend-jira.md` and use its
     state lookup instead of (`gh issue view <n> --json labels`)
```
The `gh issue view <n> --json labels` text stays byte-identical. Do not
name the operation `get_state` — skills never name the operations.

- [ ] **Step 4: Run the two handoff tests — this is the acceptance gate**

```bash
bash tests/test-handoff-pickup.sh
bash tests/test-handoff-worktree.sh
```
Expected: `passed=9 failed=0` and `passed=2 failed=0`.

- [ ] **Step 5: Verify byte-identity and commit both files together**

```bash
grep -rh '\bgh ' skills/ | sed 's/^[[:space:]]*//' | sort > /tmp/gh-after.txt
diff /tmp/gh-before.txt /tmp/gh-after.txt && echo "IDENTICAL"
git add skills/handoff/SKILL.md skills/resume/SKILL.md
git commit -m "feat(handoff,resume): record the ticket ref and its backend"
```

---

### Task 6: Widen `cleanup`'s branch pattern, then verify the whole change

**Files:**
- Modify: `skills/cleanup/SKILL.md` (intro prose, line ~8)
- Test: all of `tests/`

**Interfaces:**
- Consumes: the branch shape produced in Task 4.
- Produces: nothing downstream — this is the last file.

- [ ] **Step 1: Widen the branch-pattern prose**

From: ``` `sdlc:implement` leaves an `sdlc/<issue#>-<slug>` branch and a
worktree ```
To: ``` `sdlc:implement` leaves an `sdlc/<ref>-<slug>` branch and a
worktree ```

Then extend the same sentence's paragraph so both ref forms are named
explicitly, since the acceptance criterion is that `cleanup` matches
both: add that `<ref>` is a GitHub number or a JIRA key, so the pattern
covers `sdlc/42-add-widget` and `sdlc/PROJ-123-add-widget` alike.

Note: `cleanup`'s branch classification uses `git for-each-ref`,
`git branch --merged`, and `%(upstream:track)` — none of which filter on
the `sdlc/` prefix. So this is a documentation-only edit; there is no
regex in the file to widen.

- [ ] **Step 2: Full suite**

```bash
for t in tests/test-*.sh tests/validate-skills.sh; do
  bash "$t" >/tmp/o 2>&1; echo "$t exit=$? $(tail -1 /tmp/o)"
done
```
Expected: every line `exit=0` with `failed=0`.

- [ ] **Step 3: Final byte-identity proof**

```bash
grep -rh '\bgh ' skills/ | sed 's/^[[:space:]]*//' | sort > /tmp/gh-after.txt
diff /tmp/gh-before.txt /tmp/gh-after.txt && echo "IDENTICAL — 27 gh commands unchanged"
```

- [ ] **Step 4: Prove no JIRA specifics leaked into any skill**

```bash
grep -rniE 'jql|statusCategory|cloud_?id|atlassian|Blocks link|create_epic|create_task|link_dependency|list_open_tasks|get_state|mark_in_review|ticket_url' skills/
```
Expected: **no output.** The only permitted mentions of JIRA in `skills/`
are the two `references/backend-*.md` filenames in step 0, the
`<github|jira>` value in `handoff`'s template and `ticket`'s gate line,
and `resume`'s pointer to the adapter.

- [ ] **Step 5: Confirm the reference files were never edited**

```bash
git diff --stat main -- references/ bin/ tests/
```
Expected: **empty.** This plan touches `skills/` and `docs/plans/` only.

- [ ] **Step 6: Commit**

```bash
git add skills/cleanup/SKILL.md
git commit -m "feat(cleanup): match both numeric and keyed branch refs"
```

---

## Acceptance criteria → task map

| Criterion (issue #4) | Task |
|---|---|
| step 0 of ≤3 lines in ticket/next/implement/review | 1 |
| every `gh` command inline and byte-identical | 1–6 (gate in every task) |
| `ticket` gate table shows a `Backend:` header line | 2 |
| branch is `sdlc/<ref>-<slug>`, both forms; `cleanup` matches | 4, 6 |
| handoff records `Ticket: <ref>` + `Backend:`; `resume` verifies | 5 |
| JIRA specifics stay in `backend-jira.md` | 6 step 4, 6 step 5 |
| the two handoff tests still pass | 5 step 4, 6 step 2 |
