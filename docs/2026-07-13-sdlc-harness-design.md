# sdlc-harness — Design Spec

**Date:** 2026-07-13
**Status:** Draft, pending review
**Plugin name:** `sdlc` (published in its own `gmcquillan-sdlc` marketplace, sourced from `~/src/sdlc-harness`; the original "add to the existing gmcquillan-plugins marketplace" idea was superseded during planning because that marketplace lives inside the fable-harness repo — see the implementation plan's Global Constraints)

## Purpose

A suite of Claude Code skills that manage the full software development
lifecycle as a **human-gated pipeline**: interview → spec → GitHub issues →
implementation branches → code review. Each phase is a slash command run in
its own (usually fresh) session. GitHub and committed documents are the
persistent state store, so no phase depends on conversational memory from a
prior phase.

The suite wraps existing skills rather than reimplementing them:

- **superpowers** owns the craft of each phase (brainstorming dialogue,
  plan writing/execution, TDD, verification, code-review mechanics,
  worktrees, branch finishing).
- **fable-harness** owns the operating principles (systems mapping,
  integration-first scanning, fan-out orchestration, skeptic verification)
  and provides the scout/skeptic/judge/integrator agents.
- **sdlc** (this plugin) owns only the connective tissue: phase state
  transitions, GitHub as a task queue, context-budget enforcement, and
  session handoff.

## Design principles

### P1. Thin orchestration wrappers

Each sdlc skill is a state machine over `gh`/`git` commands plus explicit
"now invoke `<other-skill>`" steps. It never copies the body of a wrapped
skill. This survives superpowers upgrades and keeps each skill small enough
to hold in context alongside real work.

### P2. Delegate breadth, keep judgment (context-budget discipline)

The 150k context budget is protected primarily by **delegating
context-hungry work to subagents**, whose tool transcripts never enter the
coordinating session's context. The tripwire (P3) is the backstop, not the
strategy.

Concretely, in every phase:

- **Exploration and mapping** — never read file-after-file in the main
  loop. Fan out `fable-harness:scout` / `Explore` agents (via
  `fable-harness:systems-mapping` and `fan-out`) and keep only the returned
  maps.
- **Integration scanning** — `fable-harness:integrator` agents, one
  capability per agent.
- **Implementation** — `superpowers:subagent-driven-development` is the
  **default** execution mode in `/sdlc:implement`; each plan task runs in a
  fresh subagent. Inline `executing-plans` is the fallback only for tightly
  coupled tasks where per-task subagent setup cost exceeds the benefit.
- **Verification and review** — test runs with large output, diff analysis,
  and finding-verification go to subagents (`skeptic` for adversarial
  checks). The main loop sees verdicts and evidence excerpts, not raw logs.
- **The main loop holds:** user dialogue, judgment calls, phase state
  transitions, and synthesis. Nothing else.

Rule of thumb baked into each skill: *if a step will generate more than a
few thousand tokens of tool output you don't need verbatim afterward, it
belongs in a subagent.*

### P3. Deterministic context tripwire

A hook — not model discipline — detects the context threshold. Skills
define only the handoff *procedure*.

### P4. Durable state beats prose

Before any handoff, WIP is committed (or stashed) to the branch. The
handoff document records pointers and next actions; git records the work.

### P5. Human gates

Ticket creation (dry-run approval), PR merge (always the human's), and the
interview/spec approvals inherited from brainstorming. `/sdlc:implement`
stops at PR-open and never merges. `/sdlc:review` comments or approves,
never merges.

## The pipeline

```
/sdlc:interview ──► spec doc (committed) ──► /sdlc:ticket ──► GH epic + child issues
                                                                     │
        human merges PR ◄── /sdlc:review <PR#> ◄── PR ◄── /sdlc:implement <issue#>
```

Within any phase, if context approaches the budget:

```
tripwire hook fires ──► /sdlc:handoff ──► .handoff-<date>-<uuid>.md
                                                │
                            ┌───────────────────┴───────────────────┐
              default: fresh session                 --continue: fresh-context
              (SessionStart hook detects file        subagent dispatched by the
               and self-invokes /sdlc:resume)        now-supervisor-only parent
                            └───────────────────┬───────────────────┘
                                                ▼
                              /sdlc:resume re-enters phase at recorded step
```

## Components

### 1. `sdlc:interview`

Wraps `superpowers:brainstorming` (one-question-at-a-time dialogue, 2–3
approaches, section-by-section design approval) with overrides:

- **Interview additions.** Explicitly probe intent, users, non-goals,
  success criteria, and constraints. Before proposing approaches, dispatch
  `fable-harness:integration-scan` (integrator subagents — P2) so
  "wire, don't build" options surface during the interview, not after.
- **Spec additions.** The spec must end with a **Decomposition** section:
  an ordered task list where each task is scoped to **one PR** and an
  estimated **≤100k tokens** of implementation work (headroom under the
  150k tripwire). Sizing heuristics per task: one subsystem, ≲10 files,
  ≲500 LOC diff, its own acceptance criteria, explicit depends-on
  references to other tasks.
- **Terminal-state override.** Brainstorming normally hands off to
  `writing-plans`. Here the terminal message is: *"Spec committed to
  `<path>`. Run `/sdlc:ticket <path>` to create the issues."* Per-issue
  planning happens later, inside `/sdlc:implement`, in fresh context.

**Output:** `docs/specs/YYYY-MM-DD-<topic>.md` in the target project,
committed.

### 2. `sdlc:ticket <spec-path>`

Pure translation plus `gh` calls; wraps no skills.

1. Parse the spec's Decomposition section.
2. Present a **dry-run table** (title, acceptance-criteria count,
   depends-on) and get explicit user approval before creating anything.
3. Create one **epic issue** (label `sdlc:epic`): links the spec (repo
   path and/or blob URL), and contains a GitHub task list
   (`- [ ] #123 <title>`) so progress renders automatically on the issue.
4. Create **child issues** (label `sdlc:task`) with body template:
   - **Context** — one paragraph + link to the spec section
   - **Acceptance criteria** — checkboxes
   - **Scope** — files/areas expected to change
   - **Depends on** — `#` references
   - **Out of scope** — explicit exclusions
   - **Epic** — `#` reference back
5. **Idempotency:** before creating, search for an existing `sdlc:epic`
   issue whose title contains the spec slug; if found, offer
   update-in-place vs. abort. Never silently duplicate.

Failure handling: `gh auth status` checked first; on failure, stop and
tell the user to run `! gh auth login`.

### 3. `sdlc:implement [issue#]`

The workhorse. Given an issue number — or, with no argument, the next
child of the epic that is unblocked (all depends-on issues closed),
unassigned, and not labeled `sdlc:in-progress`:

1. **Preconditions:** clean git state; `gh auth` works; issue not already
   `sdlc:in-progress`. Label it `sdlc:in-progress` and self-assign now
   (prevents double pickup by parallel sessions).
2. **Understand:** read the issue and its linked spec section (main loop),
   then dispatch `fable-harness:systems-mapping` — scout subagents map the
   affected subsystem; only the maps return (P2).
3. **Isolate:** `superpowers:using-git-worktrees` → branch
   `sdlc/<issue#>-<slug>`.
4. **Plan:** `superpowers:writing-plans` for a per-issue mini-plan,
   **committed to the branch** (survives handoffs and session death).
5. **Execute:** `superpowers:subagent-driven-development` (default, per
   P2) with `superpowers:test-driven-development` per task;
   `executing-plans` inline only for tightly coupled task sequences.
6. **Verify:** `superpowers:verification-before-completion` — evidence
   before assertions. Long test output is run/summarized by a subagent.
7. **Self-review:** `superpowers:requesting-code-review` on the branch
   diff; fix findings (via `receiving-code-review` rigor — verify before
   implementing).
8. **Deliver:** push branch; open PR with `Closes #<issue>`, body linking
   epic + spec + an acceptance-criteria checklist; comment on the issue
   with the PR link; swap label `sdlc:in-progress` → `sdlc:in-review`.
9. **Stop.** Never merge (P5). Suggest `/sdlc:review <PR#>` in a fresh
   session.

### 4. `sdlc:review <PR#>`

1. Fetch the PR diff, the linked issue's acceptance criteria, and the
   spec section (metadata in main loop; the diff itself is reviewed by
   subagents — P2).
2. Fan out reviewers per `fable-harness:fan-out`, one dimension each:
   - **Spec compliance** — does the change satisfy every acceptance
     criterion? Anything out-of-scope smuggled in?
   - **Correctness** — logic, edge cases, error handling.
   - **Test quality** — do the tests actually exercise the criteria
     (TDD spirit), or are they mocked facades?
3. Significant findings go through a `fable-harness:skeptic` agent before
   posting — no plausible-but-wrong review comments reach the PR.
4. Post via `gh pr review` — request-changes with inline comments, or
   approve. **Never merge** (P5).
5. **Fix mode (optional, on user request):** check out the PR branch and
   apply `superpowers:receiving-code-review` — technically verify each
   piece of feedback before implementing it; push fixes to the branch.

### 5. Context tripwire (hook) + `sdlc:handoff` + `sdlc:resume`

#### Hook: `hooks/context-tripwire.sh` (PostToolUse)

Same infrastructure pattern as fable-harness's `stub-check.sh`.

- Estimates current context from the session transcript:
  `bytes(transcript_path) ÷ 4` — a deliberately rough token heuristic;
  thresholds are set with margin to absorb its error.
- **Soft threshold, 120k:** injects additionalContext —
  *"Context ≈120k. Finish the current atomic step, then invoke
  sdlc:handoff. Delegate any remaining exploration to subagents."*
- **Hard threshold, 150k:** *"Context ≥150k. Invoke sdlc:handoff NOW."*
- **Debounce:** a marker file in the session scratchpad directory records
  which thresholds have fired; each fires at most once per session.
- Compaction caveat: after the harness compacts a session, the transcript
  file no longer equals live context; the byte heuristic overestimates,
  which fails safe (early handoff, never a blown budget). Deliberately,
  the hook also re-arms (re-baselines) on `compact`/`resume` SessionStart
  events, so a post-compaction session may be nudged to hand off again —
  consistent with this plugin's stance that handoff beats compaction.
  Drop `compact` from the baseline matcher to disable that re-nag.

#### `sdlc:handoff` (write side)

Invoked by the tripwire warning or manually at any natural boundary.

1. **Durable state first (P4):** commit WIP to the branch (a `wip:` commit
   is fine) or stash with a named stash; record which.
2. Ensure `.handoff-*.md` is present in the project's `.gitignore`
   (append if missing, commit the `.gitignore` change).
3. Write `.handoff-$(date +%Y-%m-%d)-$(uuidgen).md` at the repo root:
   - **Phase** (interview/ticket/implement/review) and skill step number
   - **Refs:** issue #, PR #, branch, epic #, spec path, plan path
   - **Done:** what was completed, *with evidence* (e.g., test summary)
   - **State:** last commit hash, stash name if any, labels set
   - **Next:** ordered, concrete next actions (imperative, specific)
   - **Gotchas:** dead ends already explored; decisions already made
     (don't re-litigate)
4. **Continuation.** No hook can flush or reload the live session's
   context window — that is owned by the harness. The handoff file is
   therefore the single source of truth, and three pickup mechanisms all
   read the same format:
   - **Default (end-of-turn):** end the turn; tell the user to start a
     fresh session. The `handoff-pickup` SessionStart hook (below) makes
     the new session self-resume — the human's only manual step is
     launching `claude`.
   - **`--continue` (fresh-context subagent, opt-in):** instead of ending
     the turn, dispatch a general-purpose agent whose prompt is *"read
     `.handoff-<x>.md` and continue per sdlc:resume."* The agent starts at
     ~0 tokens; the bloated parent receives only its final summary, so
     several 150k "generations" can chain inside one interactive session.
     **Supervisor rule:** after handoff, the parent's budget is spent — it
     may only dispatch, relay results, and dispatch again. It MUST NOT do
     further work itself ("just fix one small thing" in a 150k window is
     the failure mode this rule exists to block). If the parent session
     dies, the handoff file remains and the default path takes over.
   - **Headless respawn (`claude -p "/sdlc:resume"`):** deliberately NOT
     in v1. Fully automatic but weakest interactively — permission
     prompts must be pre-solved, visibility is poor, and claude-in-claude
     is hard to steer. Reserved for a future autonomous `/work`
     queue-drainer (see Out of scope).

#### Hook: `hooks/handoff-pickup.sh` (SessionStart)

Same infrastructure pattern as fable-harness's SessionStart principles
injection.

- Checks the repo root for `.handoff-*.md` files.
- If any exist, injects additionalContext: *"A handoff file from a
  previous session exists at `<path>` — invoke sdlc:resume."*
- If several exist, lists them all; `sdlc:resume` handles disambiguation.

#### `sdlc:resume` (read side)

1. Find `.handoff-*.md` files at the repo root; pick the newest by mtime.
   If multiple exist, list them and ask.
2. Read it; **archive it** to the session scratchpad (remove from repo
   root) so stale handoffs never accumulate.
3. Re-enter the recorded phase skill at the recorded step, with the
   recorded refs. Verify recorded state against reality first (branch
   exists, commit present, labels as stated) — trust git over prose.

## Skill/agent wrap map

| sdlc skill | Wraps (superpowers) | Wraps (fable-harness) |
|---|---|---|
| interview | brainstorming | integration-scan (integrator agents) |
| ticket | — | — |
| implement | using-git-worktrees, writing-plans, subagent-driven-development, test-driven-development, verification-before-completion, requesting-code-review | systems-mapping (scouts), fan-out |
| review | requesting-code-review (pattern), receiving-code-review (fix mode) | fan-out, skeptic |
| handoff / resume | — | — |

## Repository layout

```
sdlc-harness/
├── .claude-plugin/
│   ├── plugin.json          # name: sdlc
│   └── marketplace.json     # own marketplace: gmcquillan-sdlc (see Plugin name note above)
├── skills/
│   ├── interview/SKILL.md
│   ├── ticket/SKILL.md
│   ├── implement/SKILL.md
│   ├── review/SKILL.md
│   ├── handoff/SKILL.md
│   └── resume/SKILL.md
├── hooks/
│   ├── hooks.json           # PostToolUse → context-tripwire.sh
│   │                        # SessionStart → handoff-pickup.sh
│   ├── context-tripwire.sh
│   └── handoff-pickup.sh
├── docs/
│   └── 2026-07-13-sdlc-harness-design.md   # this file
└── README.md
```

## Error handling (cross-cutting)

- Dirty git state, failed `gh auth`, missing spec/issue, or an issue
  already `sdlc:in-progress` → **stop and report**; never plow ahead.
- Labels (`sdlc:epic`, `sdlc:task`, `sdlc:in-progress`, `sdlc:in-review`)
  are created on first use (`gh label create --force` is idempotent).
- Oversized tickets are survivable, not fatal: the tripwire + handoff
  split them mid-issue, and `/sdlc:review` flags scope creep; recurring
  oversize is feedback to tighten the Decomposition heuristics in
  `interview`.

## Testing

- Each skill is built and validated per `superpowers:writing-skills`
  (subagent-tested before deployment).
- `context-tripwire.sh` gets a shell test: synthetic transcript files at
  sizes below/between/above thresholds; assert soft fires once, hard
  fires once, debounce holds.
- `handoff-pickup.sh` gets a shell test: repo with zero, one, and several
  `.handoff-*.md` files; assert no injection / single-path injection /
  list-all injection.
- End-to-end dry run against a throwaway GitHub repo: interview a toy
  feature → ticket → implement one issue → review the PR.

## Out of scope (v1)

- GitHub Projects boards (flat epic+children suffices; revisit if
  multi-epic coordination appears).
- Autonomous queue-draining (`/work` loop) and headless respawn
  (`claude -p "/sdlc:resume"`) — human-gated per phase for now; the label
  state machine and the shared handoff-file format already support adding
  both later.
- Cross-repo epics.
- Automatic merge of approved PRs.
