---
name: handoff
description: Use when the context tripwire fires (SOFT or HARD), or at any natural boundary before ending a long session mid-phase — commits WIP, writes a .handoff-<date>-<uuid>.md continuation file, and either ends the turn or (--continue) dispatches a fresh-context subagent.
---

# SDLC Handoff (write side)

Your context budget is spent. Durable state beats prose: git carries the
work, the handoff file carries the pointers. Create a todo per checklist
item.

**No hook can flush this session's live context.** The handoff file is
the single source of truth; every pickup mechanism reads the same format.

## Checklist

1. **Commit WIP first.** On the working branch:
   `git add -A && git commit -m "wip: handoff checkpoint"` — or, if the
   tree mixes unrelated changes, `git stash push -m "sdlc-handoff"` and
   record the stash name. Never leave state only in your context.
2. **Ensure the ignore rule (once, shared across all worktrees).** Add
   `.handoff-*.md` to the common git dir's exclude file so it is ignored in
   the main tree and every worktree without a commit:

   ```bash
   excl="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
   grep -qxF '.handoff-*.md' "$excl" 2>/dev/null || echo '.handoff-*.md' >> "$excl"
   ```
3. **Write the handoff file at the MAIN worktree root** (never the current
   worktree — a fresh session launched in the main repo must find it):

   ```bash
   main_root=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
   f="$main_root/.handoff-$(date +%Y-%m-%d)-$(uuidgen).md"
   ```

   Content template (keep these exact headings — sdlc:resume parses them):

   ```markdown
   # SDLC Handoff

   ## Phase
   <interview|ticket|implement|review> — step <N> of the skill checklist

   ## Refs
   - Issue: #<n> / PR: #<n> / Epic: #<n>
   - Branch: sdlc/<issue#>-<slug>
   - Worktree: <absolute worktree path, or "main" if written from the main tree>
   - Spec: docs/specs/<file>.md
   - Plan: <path, if one exists>

   ## Done
   <What is complete, WITH evidence — e.g. "14/14 tests pass (pytest -q)".
   Claims without evidence are worthless to the next session.>

   ## State
   - Last commit: <hash> <subject>
   - Stash: <name or "none">
   - Labels set: <e.g. sdlc:in-progress on #12>

   ## Next
   1. <Ordered, imperative, specific actions. "Implement the retry branch
      of fetch_page() per plan task 3", not "continue implementation".>

   ## Gotchas
   <Dead ends already explored; decisions already made — do not
   re-litigate them.>
   ```

4. **Choose the continuation path:**
   - **Default:** end the turn. Tell your human partner: "Handoff written
     to `<file>`. Start a fresh session in the main repo directory
     (`<main_root>`) — it will pick the handoff up automatically." (The
     handoff-pickup SessionStart hook injects it.)
   - **`--continue` (only if invoked with it):** dispatch ONE
     general-purpose subagent with the prompt: "Read `<file>`
     and continue the work per the sdlc:resume skill." Then follow the
     supervisor rule below.

## Supervisor rule (--continue only)

After handoff, this session's budget is spent. You may ONLY: dispatch the
continuation subagent, relay its final summary to the user, and dispatch
again (with a fresh handoff file, written by the subagent) if more work
remains. You MUST NOT edit files, run builds, or "just fix one small
thing" yourself — that failure mode is exactly what this rule blocks.

## Red flags

- Writing the handoff file before committing WIP → state loss if the
  session dies between the two.
- Vague Next steps ("keep going") → the next session re-derives
  everything you already know. Be specific enough that a stranger could
  execute step 1 without reading anything else.
