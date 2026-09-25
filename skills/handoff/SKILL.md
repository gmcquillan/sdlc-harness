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
   here=$(git rev-parse --show-toplevel)
   wt=$([ "$here" = "$main_root" ] && echo main || printf '%s' "$here")
   ```

   Content template (keep these exact headings — sdlc:resume parses them):

   ```markdown
   # SDLC Handoff

   ## Phase
   <interview|ticket|implement|review> — step <N> of the skill checklist

   ## Refs
   - Ticket: <ref> / PR: #<n> / Epic: <ref>
   - Backend: <github|jira — from sdlc-backend.sh resolve; github when
     its backend field is null>
   - Branch: sdlc/<ref>-<slug>
   - Worktree: <$wt from above — the worktree's absolute path, or "main">
   - Spec: docs/specs/<file>.md
   - Plan: <path, if one exists>

   ## Done
   <What is complete, WITH evidence — e.g. "14/14 tests pass (pytest -q)".
   Claims without evidence are worthless to the next session.>

   ## State
   - Last commit: <hash> <subject>
   - Stash: <name or "none">
   - Labels set: <e.g. sdlc:in-progress on <ref>>
   Hop: <n> of <cap>

   ## Next
   1. <Ordered, imperative, specific actions. "Implement the retry branch
      of fetch_page() per plan task 3", not "continue implementation".>

   ## Gotchas
   <Dead ends already explored; decisions already made — do not
   re-litigate them.>
   ```

   The `Hop:` line is written WITHOUT a leading `- ` bullet, unlike its
   neighbors — it must be `sdlc-hopcount.sh`'s exact stdout line
   (`Hop: <n> of <cap>`) verbatim, byte-for-byte, because the script's own
   parser on the next hop looks for a line beginning literally `Hop: `.
   Only present when step 4's auto-continue check below fired for this
   hop; omit the line entirely on a manually-triggered or first-ever
   handoff.

4. **Choose the continuation path:**
   - **Find any still-present prior handoff first, regardless of which
     path this step ends up taking.** Glob for a still-present
     `.handoff-*.md` at the main worktree root (the same glob `sdlc:resume`
     uses). If this session was resumed from one, that file is
     `<prior-handoff-file>` below; if none, there is no prior file for the
     rest of this step.
   - **Auto-continue check — run this only when this invocation is a
     direct response to a context-tripwire message** (the hook's
     distinctive "Context tripwire SOFT/HARD: ..." injected text). A human
     invoking `sdlc:handoff --continue` explicitly skips this check
     entirely and goes straight to the manual `--continue` path below —
     this section only automates the *unflagged* tripwire response, it
     never overrides an explicit human flag:
     1. Run `sdlc-hopcount.sh check <phase> [<prior-handoff-file>]` (bare
        name — the plugin's `bin/` is on `PATH`, exactly as with
        `sdlc-backend.sh`/`sdlc-drift.sh`; never write a `bin/`-prefixed
        path).
     2. **Exit `0`:** write the script's exact stdout line (`Hop: <n> of
        <cap>`) into this handoff's `## State` section, then take the
        `--continue` path below automatically.
     3. **Exit `2`:** phase is `interview` or `ticket` (or unrecognized) —
        fall through to the default end-turn path below, unchanged from
        today. Do not write a `Hop:` line.
     4. **Exit `1`:** the hop cap is reached — fall through to the default
        end-turn path below, but tell the human explicitly: "Auto-continue
        hop cap (10) reached without the phase's done condition being met;
        handing back for a human to resume manually or investigate why
        it's taking this long." Do not write a `Hop:` line (there is no
        next hop).
   - **Default:** end the turn. Tell your human partner: "Handoff written
     to `<file>`. Start a fresh session in the main repo directory
     (`<main_root>`) — it will pick the handoff up automatically." (The
     handoff-pickup SessionStart hook injects it.) Leave any
     `<prior-handoff-file>` found above in place — nothing is superseding
     it, since no continuation is happening this turn.
   - **`--continue` (invoked with the flag explicitly, or triggered
     automatically by the check above):** dispatch ONE general-purpose
     subagent with the prompt: "Read `<file>` and continue the work per
     the sdlc:resume skill." Then follow the supervisor rule below. In
     EITHER case — the explicit human flag or the automatic trigger —
     once `<file>` has been written successfully and a
     `<prior-handoff-file>` was found above, delete that exact file (by
     its known path — never a wildcard, and never any other
     `.handoff-*.md` that happens to be present). This keeps at most one
     handoff file alive per chain: a manual `--continue` chain that
     skipped this would leave stale files behind just as readily as an
     unattended auto-continue chain would, and either way a later
     `sdlc:resume` — quite possibly a non-interactive dispatched subagent
     that cannot answer an interactive disambiguation question — must
     never have to pick between several live files for the same chain.

## Supervisor rule (--continue only)

After handoff, this session's budget is spent. You may ONLY: dispatch the
continuation subagent, relay its final summary to the user, and dispatch
again (with a fresh handoff file, written by the subagent) if more work
remains. You MUST NOT edit files, run builds, or "just fix one small
thing" yourself — that failure mode is exactly what this rule blocks.

## Compaction across hops

Auto-continued hops chain handoff files, one per tripwire. Each one is a
fresh document, not an amendment of the last — do not carry forward
stale content:

- Write a **fresh** handoff each hop; do not copy-paste the prior file's
  `## Done`/`## Next` verbatim and append.
- Point at durable state instead of inlining it: reference the plan doc
  path and `git log`/`git diff` ranges rather than pasting diffs or full
  file contents into `## Done`.
- Prune `## Gotchas` each hop — drop anything the current `## Next` no
  longer depends on; a Gotchas section that only grows makes each
  successive hop's file harder to trust, not easier.
- Aim for roughly 60-80 lines total. This is a soft guideline, not a
  hard gate — a handoff that needs more room to stay unambiguous should
  take it — but a handoff creeping past it on every hop is a sign
  content is being duplicated instead of pointed at.

## Red flags

- Writing the handoff file before committing WIP → state loss if the
  session dies between the two.
- Vague Next steps ("keep going") → the next session re-derives
  everything you already know. Be specific enough that a stranger could
  execute step 1 without reading anything else.
