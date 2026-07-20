# Review triage + worktree-aware handoff/cleanup

Date: 2026-07-19

Three coordinated changes across the SDLC skills, driven by two problems:

1. `sdlc:review` patches findings inline on the main loop, regardless of
   size. Large findings should be ticketed (and, when the fix amounts to a
   re-do, a fresh implementation recommended); and *no* fix — however small
   — should edit files from the main loop. All fixes belong in sub-agents.
2. Handoff/cleanup are worktree-confused. `sdlc:implement` runs in a
   worktree, but `sdlc:handoff` writes `.handoff-*.md` to
   `git rev-parse --show-toplevel`, which inside a worktree is the
   *worktree* path. A fresh session launched in the main repo never sees
   it, so auto-pickup silently fails. `sdlc:cleanup` can't reclaim the
   worktree it is standing in and ignores stray handoff files entirely.

## Part 1 — `sdlc:review` fix-handling (effort tiers, all fixes in sub-agents)

Replace the current step-5 "Fix mode" (inline patch on the main loop) with a
**triage → gate → act** flow. It runs only when the user asked to address
findings, and only after the verdict is posted. Every *confirmed* finding
(i.e. it survived the skeptic step) lands in exactly one tier:

- **Tier A — Fix now (sub-agent).** A localized change to code already in
  the PR's scope that needs no separate plan. Dispatched to a **fresh
  sub-agent** per fix (or a small batched set) running
  `superpowers:receiving-code-review` + `superpowers:test-driven-development`.
  The main loop stays supervisor and never edits files itself. After fixes
  land, re-run the review checklist from step 2.
- **Tier B — Ticket it.** The finding needs its own plan, touches a
  subsystem outside the PR's scope, or is a distinct new acceptance
  criterion. Create a follow-up `sdlc:task` child issue under the same epic
  (resolved from the reviewed issue's `Epic: #<n>` line), formatted to match
  what `sdlc:next` / `sdlc:implement` consume: a `## Depends on` heading
  listing `#<current-issue>` when the fix must land after this PR merges,
  acceptance criteria, and the finding's `file:line` + failure scenario +
  suggested direction.
- **Tier C — Recommend a fresh implementation.** The confirmed findings
  aggregate into a re-do: the PR's approach is wrong, or there are enough
  substantial findings that patching would exceed a rebuild. Then
  `--request-changes` with the summary, ticket the redo as an `sdlc:task`,
  and recommend `/sdlc:implement <issue#>` in a fresh session rather than
  patching the branch.

**Tier boundaries (the heuristic reviewers apply):**

- A finding is **Tier A** when the fix is expressible as a bounded edit to
  files already in the diff (or immediately adjacent), introduces no new
  subsystem, and needs no plan of its own.
- It escalates to **Tier B** the moment any of those fails: a plan is
  needed, a new/other subsystem is touched, or it is really a new
  acceptance criterion rather than a defect in the current one.
- The set escalates to **Tier C** when the *aggregate* of confirmed findings
  indicates the approach itself is wrong, or when Tier-B-or-larger findings
  are numerous enough that a fresh implementation is cheaper than patching.
  This is a judgment call the main loop makes over the full findings list —
  not a per-finding rule.

**Approval gate.** Before creating any issue or dispatching any fix, review
presents a triage table — each confirmed finding with its tier and the
action it implies (fix / ticket / recommend-redo) — and waits for an
explicit go-ahead. Issue creation is outward-facing, so it is gated in the
same spirit as `sdlc:ticket`'s dry-run. On go-ahead, execute the tiers; then
report what was fixed, what was ticketed (with issue URLs), and any redo
recommendation.

**Unchanged:** steps 1–4 (metadata, fan-out reviewers, skeptic-verify, post
verdict) are untouched. The human merge gate is absolute as before; review
never merges.

## Part 2 — Handoff file always at the main worktree root

**Write side (`sdlc:handoff`).**

- Resolve the main worktree deterministically:
  `git worktree list --porcelain` → the first `worktree ` entry is always
  the main tree. Write `.handoff-*.md` **there**, never in the current
  worktree.
- The WIP commit is unchanged: it still happens on the working branch inside
  the current worktree. Only the pointer file relocates.
- Record the worktree in `## Refs` so resume can re-enter it:
  - `Worktree: <absolute path or "main">`
  - `Branch: sdlc/<issue#>-<slug>`
- **Ignore rule.** Replace the "append to `.gitignore` and commit it" step
  with: append `.handoff-*.md` to `$(git rev-parse --git-common-dir)/info/exclude`
  if not already present. That file lives in the shared common git dir, so
  the rule applies across the main tree and every linked worktree, and it is
  never committed. This drops the commit step and fixes ignoring everywhere
  at once. (Trade-off: the ignore rule is no longer version-controlled —
  acceptable, since it is a workflow artifact rule, not project config.)

**Pickup hook (`hooks/handoff-pickup.sh`).**

- From `cwd`, enumerate all worktrees (`git worktree list --porcelain`) and
  scan the main root **and every linked worktree** (each at maxdepth 1) for
  `.handoff-*.md`. Report every file found, de-duplicated. The hook now
  fires no matter where `claude` was launched — main repo or worktree.
- Fail-open as before: any unexpected condition exits 0 silently.

**Read side (`sdlc:resume`).**

- Mirror the hook's scan: look for handoff files in the main root and all
  linked worktrees, not just `git rev-parse --show-toplevel`.
- After reading and verifying state, if `## Refs` names a `Worktree`:
  - The worktree still exists (`git worktree list` contains the path) → cd
    into it and operate there.
  - The path is gone but the branch exists → offer to recreate the worktree
    from the branch (`git worktree add <path> <branch>`) before continuing.
  - `Worktree: main` (or absent) → operate in the main tree as today.
- Archive the file out of wherever it lived (into the session scratchpad, or
  `/tmp`), so no root — main or worktree — keeps nagging future sessions.

## Part 3 — `sdlc:cleanup` worktree awareness

- **Standing-in-a-worktree detection.** Compare `git rev-parse
  --show-toplevel` against the main root (first `git worktree list
  --porcelain` entry). If they differ, the session is inside a linked
  worktree. Report explicitly: "You are inside worktree `<path>`; git cannot
  remove the worktree you are standing in. Re-run `sdlc:cleanup` from the
  main repo (`<main-root>`) to reclaim it." Continue reporting the other
  categories normally.
- **New scan category — stray handoffs.** Scan the main root and every
  linked worktree for `.handoff-*.md`. Report them under their own heading,
  flagged: "un-resumed handoff — remove only if that work is done or
  abandoned." They are deletable behind the existing step-4 confirmation
  gate, never before it.
- **Worktree removal sweeps its handoffs.** When a confirmed worktree is
  removed, also delete any `.handoff-*.md` that lived in it or that names it
  in `## Refs`, so the pointer does not outlive its target.
- **Safety invariants unchanged.** Uncommitted work is still surfaced, never
  removed. Handoff files are deleted only after explicit confirmation, like
  every other category.

## Files touched

- `skills/review/SKILL.md` — replace step 5 with the triage → gate → act
  flow; add tier definitions and the Tier-B issue format; update red flags.
- `skills/handoff/SKILL.md` — main-root resolution, `info/exclude` ignore
  rule, `Worktree:` ref line, continuation-path wording.
- `skills/resume/SKILL.md` — multi-worktree scan, worktree re-entry logic.
- `skills/cleanup/SKILL.md` — standing-in-worktree detection, stray-handoff
  category, handoff sweep on worktree removal.
- `hooks/handoff-pickup.sh` — scan main root + all linked worktrees.
- `tests/` — cover: handoff lands in main root when written from a worktree;
  `info/exclude` gets the rule; pickup hook finds a handoff regardless of
  launch dir; cleanup reports the stray-handoff category.

## Out of scope

- No change to `sdlc:implement`'s execution model — it already delegates work
  to sub-agents (`subagent-driven-development`); Part 1's "all fixes in
  sub-agents" rule is about the review fix path specifically.
- No change to the context-tripwire hook or budgets.
- No merge/push automation — the human integration gate stays absolute.
