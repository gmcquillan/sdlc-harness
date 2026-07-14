---
name: resume
description: Use when a session starts and the handoff-pickup hook reports .handoff-*.md files (or the user asks to resume prior SDLC work) — reads the newest handoff, verifies its recorded state against git, archives it, and re-enters the recorded phase skill.
---

# SDLC Resume (read side)

Pick up exactly where a previous session left off. Create a todo per
checklist item.

## Checklist

1. **Find handoff files:** `ls .handoff-*.md` at the repo root
   (`git rev-parse --show-toplevel`). One file → use it. Several → list
   them with mtimes and ask the user which to resume (newest is the
   default suggestion). None → tell the user there is nothing to resume
   and stop.
2. **Read it fully.** The `## Gotchas` section is binding: decisions
   recorded there are settled — do not re-litigate them.
3. **Verify state against reality — trust git over prose:**
   - Branch in `## Refs` exists? (`git branch --list <branch>`)
   - Last-commit hash in `## State` present? (`git cat-file -e <hash>`)
   - Stash named there still exists? (`git stash list`)
   - Issue/PR labels as recorded? (`gh issue view <n> --json labels`)
   Where reality disagrees with the file, reality wins; note the
   discrepancy to the user before proceeding.
4. **Archive the file** so stale handoffs never accumulate: move it into
   the session scratchpad directory (or `/tmp` if none). It must leave
   the repo root — the pickup hook keys off that glob.
5. **Re-enter the phase:** invoke the skill named in `## Phase`
   (sdlc:interview, sdlc:ticket, sdlc:implement, or sdlc:review), skip to
   the recorded checklist step, and execute `## Next` in order.

## Red flags

- Starting work before step 3 → you may build on a branch that was
  rebased, deleted, or merged since the handoff was written.
- Leaving the handoff file in the repo root → every future session gets
  nagged about a handoff that is already done.
