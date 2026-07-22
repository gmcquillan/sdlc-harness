---
name: cleanup
description: Use when a repo has accumulated stale worktrees, merged/orphaned local branches, or stray uncommitted files after SDLC work — scans read-only, reports by category, then deletes only after explicit confirmation. Never removes uncommitted work. Invoke as sdlc:cleanup.
---

# SDLC Cleanup: reclaim stale worktrees & branches

`sdlc:implement` leaves an `sdlc/<ref>-<slug>` branch and a worktree
per ticket, where `<ref>` is a GitHub issue number or a JIRA key — so
both `sdlc/42-add-widget` and `sdlc/PROJ-123-add-widget` are in scope.
After PRs merge, those linger — and when the repo squash-merges but keeps
head branches, they linger *invisibly*: the squash writes a new commit, so
the branch is not an ancestor of base, and the remote branch still exists,
so its upstream is not `[gone]`. Neither local signal fires. This skill
reclaims them — safely, behind a human gate.

It never MUTATES anything beyond the local workspace: it does not push,
does not delete remote branches, does not modify any remote state, and
never deletes uncommitted work. It DOES make one read-only remote query
(`gh pr list`, step 2) to learn which branches already have merged PRs.
Create a todo per checklist item.

## Checklist

1. **Detect the base branch** (local only — no network). `git
   symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed
   's@^origin/@@'`; if `origin/HEAD` isn't set locally that prints
   nothing, so fall back to whichever of `main`/`master` exists. Record
   the current branch (`git branch --show-current`).
2. **Scan (all read-only — nothing is deleted in this step).**
   - **Merged PRs** (the one read-only remote query; run this FIRST, so
     the branch and worktree scans below can consult its map):

     ```bash
     command -v gh >/dev/null 2>&1 && \
       gh pr list --state merged --limit 200 \
         --json number,headRefName,mergeCommit,isCrossRepository
     ```

     Build a map from `headRefName` to `{number, mergeCommit.oid}`,
     **skipping every PR whose `isCrossRepository` is true**: a fork PR's
     `headRefName` is a branch name inside the fork (`patch-1`, `fix`,
     `main` — names that collide with local branches by coincidence, not
     identity), so keeping them would attach real PR evidence to an
     unrelated local branch.

     If `gh` is absent, unauthenticated, or the call fails (offline, or
     the remote is not GitHub), skip it, treat the map as empty, and mark
     the scan **DEGRADED** — you MUST say so in the report, because
     merged branches will then be under-detected exactly as they were
     before this signal existed. Distinguish the two cases when you
     report: "gh unavailable — merged-PR detection skipped" versus "not a
     GitHub remote — merged-PR detection does not apply."

     The `--limit 200` window is a ceiling, not a guarantee: a branch
     whose PR is older than the 200 most recent merges falls back to the
     local signals and lands in review-manually. Say so if it bites.
   - **Uncommitted changes:** `git status --porcelain` in the main
     working tree, and in each worktree path from the Worktrees scan
     below. Any output = that tree is dirty.
   - **Worktrees:** `git worktree list --porcelain`. For each (excluding
     the main tree and the one you are standing in), note its branch and
     whether that branch is merged into base, has a merged PR, or has
     upstream `[gone]`.
     Also run `git worktree prune --dry-run` for stale administrative
     entries (worktree dirs that no longer exist on disk).
   - **Standing-in-a-worktree check:** compare `git rev-parse
     --show-toplevel` against the main root (`git worktree list --porcelain
     | awk '/^worktree /{print $2; exit}'`). If they differ, this session is
     inside a linked worktree — git cannot remove the tree you stand in.
     Report it and tell the user to re-run `sdlc:cleanup` from the main repo
     (`<main-root>`) to reclaim that worktree. Keep reporting the other
     categories normally.
   - **Stray handoffs:** scan every worktree root
     (`git worktree list --porcelain | awk '/^worktree /{print $2}'`) for
     `.handoff-*.md`. Report each under its own heading, flagged
     "un-resumed handoff — remove only if that work is done or abandoned."
   - **Local branches**, via `git for-each-ref --format
     '%(refname:short) %(upstream) %(upstream:track)' refs/heads`.
     **Evaluate the classes in the order listed; first match wins** — a
     branch can satisfy more than one, and the order decides which reason
     and which delete flag you report.
     - **Merged into base:** appears in `git branch --merged <base>`.
       Safe; deletes with `-d`.
     - **PR merged:** ALL THREE must hold — (a) the branch's
       `%(upstream)` is exactly `refs/remotes/origin/<headRefName>` for
       an entry in the merged-PR map (match on the tracked upstream, NOT
       on the local branch name — a never-pushed local branch has an
       empty `%(upstream)` and must never match), (b) that entry survived
       the `isCrossRepository` filter, and (c) `%(upstream:track)`
       reports NO ahead count — beware that git writes both `[ahead 1]`
       and `[ahead 1, behind 2]`, so test for the substring `ahead`, not
       for a literal `[ahead N]`. Safe to remove, but use `-D`: a
       squash-merge writes a new commit, so the branch is not an ancestor
       of the local base. (`-d` may *incidentally* succeed while the kept
       remote branch still points at the same tip, since git also accepts
       "merged to upstream" — but that stops holding the moment the
       remote branch is deleted or moves, so do not rely on it.) State
       the evidence in the report — "PR #13 squash-merged as f3948f5".
     - **Upstream `[gone]`:** `%(upstream:track)` is `[gone]` — the
       remote branch was deleted. Needs `-D` either way, since the branch
       may not be an ancestor of the local base. Deleting the remote also
       erased the ahead count, so `[gone]` alone cannot tell you whether
       the branch still holds unique work. Split on `git log --oneline
       <base>..<branch>`:
       - EMPTY → **deletable.** Say the remote branch was deleted.
       - NON-EMPTY → **deletable, merge unverified.** A squash-merge
         whose head branch was then deleted leaves exactly this shape —
         the squash wrote a new commit, so the merged work is in base
         under a different SHA — and so does a branch whose remote was
         deleted with real work still on it. The two are
         indistinguishable locally. This is the ordinary result of the
         default GitHub merge-and-delete flow, so do NOT bury it in
         "review manually": report it as its own group with the commit
         subjects listed, and let the human judge at the gate.
     - **Unmerged / has unpushed commits:** none of the above.
       Report under "review manually" — NEVER auto-delete. Two cases land
       here for reasons worth stating explicitly: a branch whose PR
       merged but which is ahead of its upstream (those commits were
       never in the PR, and `-D` would discard them), and a branch whose
       name resembles a merged PR's but which does not track it. In a
       DEGRADED scan, add that a merged PR may be the real status and the
       user can re-run where `gh` works.
     - Always exclude: the current branch, the base branch, and any
       branch checked out in a worktree that is not itself being removed.
3. **Report** the findings grouped as: Uncommitted (per tree),
   Prunable worktrees, Stray handoffs, Deletable branches (merged /
   PR-merged / upstream-gone, each with its reason — for a PR-merged
   branch, name the PR and the squash commit), Deletable-but-unverified
   branches (upstream `[gone]` while still holding commits absent from
   base — list those commits), and Review-manually branches (each with
   why). Keep the unverified group visually separate from the verified
   deletable ones. If the merged-PR query could not run, say the scan was
   DEGRADED and that merged branches may be under-reported. If everything
   is clean, say so and stop.
4. **Confirmation gate (the human gate).** Present the deletable
   worktrees, branches, and stray handoffs and ask the user to confirm — all, or a
   selected subset. Delete NOTHING before an explicit yes. Deletable-but-
   unverified branches are confirmed ONE AT A TIME, with their commits
   shown — a blanket "yes, all" never sweeps them up.
5. **Execute** only what was confirmed:
   - Worktrees: `git worktree remove <path>` (add `--force` ONLY for a
     dirty worktree the user explicitly approved), then `git worktree
     prune`.
   - Branches: `git branch -d <branch>` for merged into base; `git branch
     -D <branch>` for PR-merged, for upstream-gone, and for deletable-but-
     unverified — none of those is guaranteed to be an ancestor of the
     local base. State the reason when you do ("PR #13 squash-merged as
     f3948f5").
   - **Stray handoffs:** delete confirmed `.handoff-*.md` files. When a
     worktree is removed, also delete any handoff that lived in it or that
     names its path in `## Refs`, so the pointer never outlives its target.
   - **Uncommitted files: reported only, never deleted** — leave them for
     the human.
6. **Report** exactly what was removed, and restate any dirty trees or
   review-manually branches left for the user to handle.

## Safety invariants

- Remote state is never mutated. The single `gh pr list` call is
  read-only; nothing is pushed and no remote branch is deleted.
- Uncommitted work is surfaced, never removed.
- The current branch and the base branch are never deleted.
- A worktree with uncommitted changes is never force-removed without
  explicit per-item confirmation.
- No deletion of any kind happens before the step 4 confirmation gate.

## Red flags

- Running `git branch -D` before the user confirmed → human gate skipped.
- Reading "not an ancestor of base" as "unmerged" without checking PR
  state → the squash-merge trap. `gh pr merge --squash` writes a new
  commit, so a fully merged branch shows as unmerged and, if the repo
  keeps head branches, has no `[gone]` upstream either. Check the
  merged-PR map before sending a branch to "review manually".
- Deleting a PR-merged branch that is ahead of its upstream → those
  commits were never in the PR; that branch is review-manually, not
  deletable. Test for `ahead` anywhere in `%(upstream:track)`: git writes
  `[ahead 1, behind 2]` as well as `[ahead 1]`.
- Matching a merged PR by branch NAME instead of by tracked upstream →
  a never-pushed local branch (empty `%(upstream)`) or a fork PR's
  `headRefName` can collide by coincidence, and the human gate would then
  be shown real PR evidence for unrelated work. Match on
  `%(upstream)` and drop `isCrossRepository` PRs.
- Treating a `[gone]` upstream as "definitely merged" without saying so →
  say the remote branch was deleted; let the human judge.
- Filing a `[gone]` branch that still holds commits under "review
  manually" as though it were unmerged → that is the ordinary shape of
  the default merge-and-delete flow, and hiding it there is how cleanup
  stops reclaiming anything. It is deletable-but-unverified: show the
  commits and let the human decide.
- `git clean` / deleting untracked files to "tidy up" → out of scope;
  uncommitted work is the user's.
- Silently skipping the worktree you are standing in → say you cannot
  remove it and where to re-run from; do not pretend it is clean.
