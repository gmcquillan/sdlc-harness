# Cleanup Squash-Merge Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `sdlc:cleanup` classify squash-merged branches as deletable, with PR-number evidence, in repos that keep head branches after merge.

**Architecture:** Add a single read-only `gh pr list --state merged` query to the step 2 scan, building a `headRefName -> {PR number, merge SHA}` map. A branch matching that map is deletable via `-D` with the reason "PR #13 squash-merged as f3948f5". The skill's "local workspace only" invariant is narrowed to "never *mutates* a remote" to permit the read. When `gh` is unavailable the query is skipped, the map is empty, and the scan is reported as DEGRADED — behavior degrades to exactly today's local-only signals rather than failing.

**Tech Stack:** Markdown skill definition (`skills/cleanup/SKILL.md`); POSIX shell regression test in `tests/`.

## Global Constraints

- Scope is `skills/cleanup/SKILL.md` plus its new regression test. Do not touch `sdlc:implement` branch naming or the epic #1 JIRA work.
- Cleanup stays local for **mutations**: never delete or push remote branches. The only permitted remote access is the read-only `gh pr list` query.
- Shell snippets must be portable to BSD/macOS tools — no `grep -P`, no `\b` word boundaries, no GNU-only flags. (Sibling issue #16 tracks an existing `\b` portability bug elsewhere in this repo.)
- Nothing is deleted before the step 4 confirmation gate. That gate is unchanged by this work.
- `tests/validate-skills.sh` must keep passing: frontmatter fence intact, `name: cleanup` matching the directory, `description:` still beginning "Use when".

---

### Task 1: Squash-merge detection in the cleanup skill

**Files:**
- Modify: `skills/cleanup/SKILL.md` (intro lines 8–15; step 2 worktree + local-branch classification lines 28–55; step 3 report lines 56–59; safety invariants lines 77–83; red flags lines 85–93)
- Create: `tests/test-cleanup-skill.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks depend on. This is the whole change.

- [ ] **Step 1: Write the failing test**

Create `tests/test-cleanup-skill.sh`. It asserts the four behaviors the ticket
names, using fixed-string greps (`grep -qF`) so it stays portable to BSD grep.

```bash
#!/usr/bin/env bash
# Guards the squash-merge fixes in skills/cleanup/SKILL.md (issue #14).
# A squash-merged branch is not an ancestor of base and — when the repo keeps
# head branches — has no [gone] upstream, so neither local signal fires.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
f="$here/../skills/cleanup/SKILL.md"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

if [ ! -f "$f" ]; then echo "FAIL: cleanup SKILL.md missing"; exit 1; fi

# 1. The merged-PR signal is queried (AC: squash-merged branch is deletable).
grep -qF 'gh pr list --state merged' "$f" \
  && ok "queries merged PRs" \
  || bad "no 'gh pr list --state merged' query"

# 2. The report cites PR number and merge SHA (AC: report states *why*).
grep -qF 'squash-merged as' "$f" \
  && ok "reason string cites the squash commit" \
  || bad "no 'squash-merged as' evidence string"

# 3. The stale parenthetical is gone (AC: correct the stale claim).
grep -qF 'usually squash-merged, so the remote branch' "$f" \
  && bad "stale parenthetical still present" \
  || ok "stale 'remote branch is deleted' claim removed"

# 4. The red flags name the squash trap (AC: red flag section).
awk '/^## Red flags$/{n=1} n' "$f" | grep -qF 'not an ancestor' \
  && ok "red flag names the squash-merge trap" \
  || bad "no red flag about 'not an ancestor' meaning unmerged"

# 5. The invariant is mutation-scoped, permitting the read-only query.
grep -qF 'never MUTATES' "$f" \
  && ok "invariant narrowed to mutations" \
  || bad "invariant not restated in terms of mutation"

# 6. Degraded mode is defined for when gh is unavailable.
grep -qF 'DEGRADED' "$f" \
  && ok "degraded fallback defined" \
  || bad "no DEGRADED fallback when gh is unavailable"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

Make it executable:

```bash
chmod +x tests/test-cleanup-skill.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-cleanup-skill.sh`

Expected: FAIL. Assertions 1, 2, 4, 5, and 6 fail (none of that text exists
yet) and assertion 3 fails because the stale parenthetical is still on line 11.
Final line reads `passed=0 failed=6` and the exit status is non-zero.

- [ ] **Step 3: Rewrite the intro paragraph**

In `skills/cleanup/SKILL.md`, replace the paragraph currently spanning lines
8–15 (from "`sdlc:implement` leaves" through "Create a todo per checklist
item.") with:

```markdown
`sdlc:implement` leaves an `sdlc/<ref>-<slug>` branch and a worktree
per ticket, where `<ref>` is a GitHub issue number or a JIRA key — so
both `sdlc/42-add-widget` and `sdlc/PROJ-123-add-widget` are in scope.
After PRs merge, those linger — and when the repo squash-merges but keeps
head branches, they linger *invisibly*: the squash writes a new commit, so
the branch is not an ancestor of base, and the remote branch still exists,
so its upstream is not `[gone]`. Neither local signal fires. This skill
reclaims them — safely, behind a human gate.

It never MUTATES anything beyond the local workspace: it does not push,
does not delete remote branches, does not touch any remote state, and
never deletes uncommitted work. It DOES make one read-only remote query
(`gh pr list`, step 2) to learn which branches already have merged PRs.
Create a todo per checklist item.
```

- [ ] **Step 4: Add the merged-PR query and re-classify branches in step 2**

In step 2, replace the **Worktrees** bullet's clause "note its branch and
whether that branch is merged into base or has upstream `[gone]`" with:

```markdown
     note its branch and whether that branch is merged into base, has a
     merged PR, or has upstream `[gone]`.
```

Then replace the entire **Local branches** bullet (lines 44–55) with the
following, which inserts the merged-PR query ahead of the classification:

```markdown
   - **Merged PRs** (the one read-only remote query; run once, before
     classifying branches):

     ```bash
     gh pr list --state merged --limit 200 \
       --json number,headRefName,mergeCommit
     ```

     Build a map from `headRefName` to `{number, mergeCommit.oid}`. If
     `gh` is absent, unauthenticated, or the call fails (offline), skip
     it, treat the map as empty, and mark the scan **DEGRADED** — you
     MUST say so in the report, because merged branches will then be
     under-detected exactly as they were before this signal existed.
   - **Local branches**, via `git for-each-ref --format
     '%(refname:short) %(upstream:track)' refs/heads`, classified into:
     - **Merged into base:** appears in `git branch --merged <base>`.
       Safe; deletes with `-d`.
     - **PR merged:** the branch name is a key in the merged-PR map, and
       `%(upstream:track)` does NOT show `[ahead N]`. Safe to remove, but
       needs `-D`: a squash-merge writes a new commit, so the branch is
       not an ancestor of base and `-d` would refuse. State the evidence
       in the report — "PR #13 squash-merged as f3948f5".
     - **Upstream `[gone]`:** `%(upstream:track)` is `[gone]` (the
       remote branch was deleted). Safe to remove, but needs `-D` since
       it may not be merged into the local base.
     - **Unmerged / has unpushed commits:** none of the above.
       Report under "review manually" — NEVER auto-delete. A branch whose
       PR merged but which is `[ahead N]` belongs here too: those N
       commits were never in the PR, and `-D` would discard them. Say
       that is the reason. In a DEGRADED scan, add that a merged PR may
       be the real status and the user can re-run where `gh` works.
     - Always exclude: the current branch, the base branch, and any
       branch checked out in a worktree that is not itself being removed.
```

- [ ] **Step 5: Carry the reason into the report and invariants**

Replace the step 3 **Report** item so deletable branches carry their evidence
and a degraded scan announces itself:

```markdown
3. **Report** the findings grouped as: Uncommitted (per tree),
   Prunable worktrees, Stray handoffs, Deletable branches (merged /
   PR-merged / upstream-gone, each with its reason — for a PR-merged
   branch, name the PR and the squash commit), and Review-manually
   branches (each with why). If the merged-PR query could not run, say
   the scan was DEGRADED and that merged branches may be under-reported.
   If everything is clean, say so and stop.
```

In **Safety invariants**, replace the first bullet block by adding a leading
invariant that records the narrowed scope (the decision this ticket asked to
settle):

```markdown
- Remote state is never mutated. The single `gh pr list` call is
  read-only; nothing is pushed and no remote branch is deleted.
- Uncommitted work is surfaced, never removed.
```

- [ ] **Step 6: Add the squash-merge red flag**

In **Red flags**, insert as the second entry (after the `git branch -D` one):

```markdown
- Reading "not an ancestor of base" as "unmerged" without checking PR
  state → the squash-merge trap. `gh pr merge --squash` writes a new
  commit, so a fully merged branch shows as unmerged and, if the repo
  keeps head branches, has no `[gone]` upstream either. Check the merged-PR
  map before sending a branch to "review manually".
- Deleting a PR-merged branch that is `[ahead N]` → those commits were
  never in the PR; that branch is review-manually, not deletable.
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bash tests/test-cleanup-skill.sh`

Expected: PASS — final line `passed=6 failed=0`, exit status 0.

- [ ] **Step 8: Run the full suite for regressions**

Run: `for t in tests/*.sh; do printf '%-40s' "$(basename $t)"; bash "$t" >/dev/null 2>&1 && echo PASS || echo FAIL; done`

Expected: all seven suites PASS, including `validate-skills.sh` (the
frontmatter and `description: Use when…` line are untouched by this change).

- [ ] **Step 9: Commit**

```bash
git add skills/cleanup/SKILL.md tests/test-cleanup-skill.sh docs/plans/2026-07-22-cleanup-squash-merge-detection.md
git commit -m "fix(cleanup): detect squash-merged branches via merged-PR state

A squash-merge writes a new commit, so the branch is not an ancestor of
base; when the repo also keeps head branches, the upstream is not [gone].
Neither existing signal fired, so every merged branch landed in 'review
manually' and cleanup reclaimed nothing.

Adds a read-only 'gh pr list --state merged' query and narrows the
local-only invariant to 'never mutates a remote'. Branches that are
[ahead N] of their upstream stay review-manually even with a merged PR,
so unpushed commits are never discarded. Degrades to the prior local-only
signals when gh is unavailable.

Closes #14"
```

## Acceptance criteria traceability

| Ticket AC | Covered by |
|---|---|
| Squash-merged branch classified deletable | Step 4, "PR merged" class; test assertion 1 |
| Report states why ("PR #13 squash-merged as f3948f5") | Steps 4–5; test assertion 2 |
| No merged PR and no `[gone]` → still review-manually | Step 4, "Unmerged" class (unchanged default) |
| Invariant restated to permit read-only query | Steps 3, 5; test assertion 5 |
| Red flags name the squash-merge trap | Step 6; test assertion 4 |
| Nothing deleted before step 4 gate | Untouched — steps 4/5 of the skill are not edited |
| Stale parenthetical corrected | Step 3; test assertion 3 |

## Corrections made during implementation

This plan is a point-in-time record, but two of its claims are wrong and
should not be copied elsewhere:

1. **Step 4 says `-d` "would refuse" a squash-merged branch. It does
   not.** Verified against a fixture: `git branch -d` accepts a branch
   merged into its *upstream* as well as into HEAD, so while the kept
   remote branch still holds the same tip it deletes with only a warning.
   `-D` is still correct — because that incidental success stops the
   moment the remote branch is deleted or diverges — but the reason is
   different from the one written here. Shipped in `9b28bb5`.

2. **Matching the merged-PR map by branch name is unsafe.** As planned,
   the PR-merged class keyed on the local branch name, and the `[ahead
   N]` guard passes vacuously for a never-pushed branch (empty
   `%(upstream:track)`). A local branch colliding with a merged PR's
   `headRefName` — common for fork PRs (`patch-1`, `fix`, `main`) —
   would be `-D`'d and the human gate shown real PR evidence for
   unrelated work. The shipped skill matches on `%(upstream)` equalling
   `refs/remotes/origin/<headRefName>` and drops `isCrossRepository`
   PRs. It also tests `ahead` as a substring, since git writes `[ahead
   1, behind 2]` as well as `[ahead 1]`. Shipped in `4db8eda`.

3. **Guarding the `[gone]` class with "holds no commits absent from
   base" broke the case the ticket is about.** An intermediate commit
   tightened `[gone]` to require `git log <base>..<branch>` to be empty.
   That condition is false for *every* squash-merge, so the default
   GitHub merge-and-delete flow — squash, then delete the head branch —
   stopped being reclaimable unless the merged-PR map caught it first.
   It therefore regressed whenever the map is empty or incomplete: a
   DEGRADED scan, a non-GitHub remote, or a PR outside the `--limit 200`
   window. Verified with a fixture: a squash-merged branch whose remote
   was deleted reports `track=[gone]` with two commits still in
   `<base>..<branch>`.

   The shipped skill keeps the distinction but not the demotion. A
   `[gone]` branch with a non-empty `<base>..<branch>` is **deletable,
   merge unverified**: its own report group, commit subjects listed,
   confirmed one at a time at the gate rather than by a blanket "yes,
   all". The local signals genuinely cannot separate "squash-merged then
   deleted" from "deleted with real work on it" — so the human gate
   adjudicates, which is what it is for. Hiding the branch in "review
   manually" only made cleanup reclaim nothing while looking safe.

Task 1's test block is also superseded: the shipped
`tests/test-cleanup-skill.sh` has 13 assertions using `want`/`reject`/
`in_section` helpers rather than the 6 shown here. `in_section` bounds
each section at the next `## ` heading or top-level numbered step —
matching to end-of-file let a later section satisfy an assertion about
an earlier one (the red flags mention `PR-merged`, which vacuously
satisfied the step 5 assertion; verified by mutation test).
