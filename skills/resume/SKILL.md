---
name: resume
description: Use when a session starts and the handoff-pickup hook reports .handoff-*.md files (or the user asks to resume prior SDLC work) — reads the newest handoff, verifies its recorded state against git, re-enters the recorded phase skill, and only archives it once that work is verifiably complete.
---

# SDLC Resume (read side)

Pick up exactly where a previous session left off. Create a todo per
checklist item.

## Checklist

1. **Find handoff files across every worktree** (the writer puts them at the
   main root, but scan all trees so none is missed):

   ```bash
   git worktree list --porcelain | awk '/^worktree /{print $2}' \
     | while read -r r; do ls "$r"/.handoff-*.md 2>/dev/null; done
   ```

   One file → use it. Several → list them with mtimes and ask which to
   resume (newest is the default). None → tell the user there is nothing to
   resume and stop.
2. **Read it fully.** The `## Gotchas` section is binding: decisions
   recorded there are settled — do not re-litigate them.
3. **Verify state against reality — trust git over prose:**
   - Branch in `## Refs` exists? (`git branch --list <branch>`)
   - Last-commit hash in `## State` present? (`git cat-file -e <hash>`)
   - Stash named there still exists? (`git stash list`)
   - Ticket labels as recorded? Read the `Backend:` line in `## Refs`.
     On `github`, or with no such line, run
     `gh issue view <n> --json labels`. On any other backend run
     `sdlc-backend.sh resolve` — the adapter expects its caller to hold
     that output — and branch on its `action`, not on the recorded line:
     `use-jira` → follow `references/backend-jira.md`; anything else →
     the binding changed since the handoff, so say so and verify on the
     backend `resolve` reports.
   Where reality disagrees with the file, reality wins; note the
   discrepancy to the user before proceeding.
4. **Re-enter the recorded worktree.** Read the `Worktree:` line in
   `## Refs`:
   - It still exists (`git worktree list` contains the path) → operate from
     there (the phase skill's work happens inside it).
   - The path is gone but the branch exists → offer to recreate it:
     `git worktree add <path> <branch>`, then operate from there.
   - `Worktree: main` or absent → operate in the main tree.
5. **Re-enter the phase:** invoke the skill named in `## Phase`
   (sdlc:interview, sdlc:ticket, sdlc:implement, or sdlc:review), skip to
   the recorded checklist step, and execute `## Next` in order. Do not
   touch the handoff file yet — it is the only durable record of this
   work until it is done.
6. **Archive the file, and only the file, once `## Next` is fully
   executed** (or the phase's own "done" condition — PR opened/merged,
   ticket transitioned, etc. — is met): move it into the session
   scratchpad directory (or `/tmp` if none). It must leave the repo root
   — the pickup hook keys off that glob. If the session ends, is
   cleared, or is interrupted before that point, leave the file in the
   repo root — a future session's pickup hook must still find it.

## Red flags

- Starting work before step 3 → you may build on a branch that was
  rebased, deleted, or merged since the handoff was written.
- Archiving before step 5's work is verifiably complete → the scratchpad
  directory is session-specific and not visible to future sessions; if
  the session is interrupted between archiving and finishing, the
  handoff is effectively lost, not just relocated.
- Leaving the handoff file in the repo root after the work is genuinely
  done → every future session gets nagged about a handoff that is
  already done. Archive promptly once done, just not before.
