---
name: cleanup
description: Use when a repo has accumulated stale worktrees, merged/orphaned local branches, or stray uncommitted files after SDLC work — scans read-only, reports by category, then deletes only after explicit confirmation. Never removes uncommitted work. Invoke as sdlc:cleanup.
---

# SDLC Cleanup: reclaim stale worktrees & branches

`sdlc:implement` leaves an `sdlc/<issue#>-<slug>` branch and a worktree
per issue. After PRs merge (usually squash-merged, so the remote branch
is deleted), those linger. This skill reclaims them — safely, behind a
human gate. It operates on the LOCAL workspace only; it never touches
remotes and never deletes uncommitted work. Create a todo per checklist
item.

## Checklist

1. **Detect the base branch** (local only — no network). `git
   symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed
   's@^origin/@@'`; if `origin/HEAD` isn't set locally that prints
   nothing, so fall back to whichever of `main`/`master` exists. Record
   the current branch (`git branch --show-current`).
2. **Scan (all read-only — nothing is deleted in this step).**
   - **Uncommitted changes:** `git status --porcelain` in the main
     working tree, and in each worktree path from the Worktrees scan
     below. Any output = that tree is dirty.
   - **Worktrees:** `git worktree list --porcelain`. For each (excluding
     the main tree and the one you are standing in), note its branch and
     whether that branch is merged into base or has upstream `[gone]`.
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
     '%(refname:short) %(upstream:track)' refs/heads`, classified into:
     - **Merged into base:** appears in `git branch --merged <base>`.
       Safe; deletes with `-d`.
     - **Upstream `[gone]`:** `%(upstream:track)` is `[gone]` (the
       remote branch was deleted — the squash-merged-PR case, and the
       common one). Safe to remove, but needs `-D` since it may not be
       merged into the local base.
     - **Unmerged / has unpushed commits:** neither of the above.
       Report under "review manually" — NEVER auto-delete.
     - Always exclude: the current branch, the base branch, and any
       branch checked out in a worktree that is not itself being removed.
3. **Report** the findings grouped as: Uncommitted (per tree),
   Prunable worktrees, Stray handoffs, Deletable branches (merged /
   upstream-gone, each with the reason), and Review-manually branches. If
   everything is clean, say so and stop.
4. **Confirmation gate (the human gate).** Present the deletable
   worktrees and branches and ask the user to confirm — all, or a
   selected subset. Delete NOTHING before an explicit yes.
5. **Execute** only what was confirmed:
   - Worktrees: `git worktree remove <path>` (add `--force` ONLY for a
     dirty worktree the user explicitly approved), then `git worktree
     prune`.
   - Branches: `git branch -d <branch>` for merged; `git branch -D
     <branch>` for upstream-gone (state the reason when you do).
   - **Stray handoffs:** delete confirmed `.handoff-*.md` files. When a
     worktree is removed, also delete any handoff that lived in it or that
     names its path in `## Refs`, so the pointer never outlives its target.
   - **Uncommitted files: reported only, never deleted** — leave them for
     the human.
6. **Report** exactly what was removed, and restate any dirty trees or
   review-manually branches left for the user to handle.

## Safety invariants

- Uncommitted work is surfaced, never removed.
- The current branch and the base branch are never deleted.
- A worktree with uncommitted changes is never force-removed without
  explicit per-item confirmation.
- No deletion of any kind happens before the step 4 confirmation gate.

## Red flags

- Running `git branch -D` before the user confirmed → human gate skipped.
- Treating a `[gone]` upstream as "definitely merged" without saying so →
  say the remote branch was deleted; let the human judge.
- `git clean` / deleting untracked files to "tidy up" → out of scope;
  uncommitted work is the user's.
- Silently skipping the worktree you are standing in → say you cannot
  remove it and where to re-run from; do not pretend it is clean.
