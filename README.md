# sdlc-harness

A human-gated software-development pipeline for [Claude
Code](https://docs.claude.com/en/docs/claude-code), packaged as a plugin.
It turns a rough idea into shipped code through a chain of discrete
phases — interview, spec, tickets, implementation, review — each run as
its own skill, with a human approval gate at every step that matters.

The whole thing is built around one constraint: **a coding agent's
context window is finite, and quality degrades as it fills.** So instead
of one long session that slowly forgets its own plan, each phase runs in
a fresh (or freshly-delegated) session, and durable state lives outside
the model — in GitHub issues and committed design docs. A context
tripwire and handoff files let a session that's running low hand its work
to a clean one without losing the thread.

```
/sdlc:interview ──► spec ──► /sdlc:ticket ──► epic + child issues
                                                    │
                                             /sdlc:next [#]
                                                    │
  human merges ◄── /sdlc:review <PR#> ◄── PR ◄── /sdlc:implement [#]
                            ▲              │
                            └─ /sdlc:fixes <PR#> ◄──┘
```

## Why

Long agentic coding sessions fail in predictable ways: the agent loses
track of the plan, silently drops requirements, merges half-finished
work, or burns its context re-reading files it already understood. This
harness addresses each directly:

- **State lives outside the model.** The spec is a committed file; the
  work breakdown is GitHub issues with real dependency edges. A session
  can die at any point and the next one picks up from git + issues, not
  from a summary.
- **Breadth goes to subagents; judgment stays in the main loop.** Bulky
  exploration (mapping a subsystem, running a test suite, scanning a
  backlog) is delegated so its output never bloats the deciding session.
- **Humans gate the irreversible steps.** The pipeline never merges to a
  shared branch, never pushes, and never opens a PR without explicit
  confirmation. Approval for one step does not extend to the next.
- **Running low on context is a first-class event.** At ~120k tokens a
  tripwire nudges a handoff; the session commits its WIP, writes a
  handoff file, and a fresh session resumes exactly where it left off.

## Install

From within Claude Code:

    /plugin marketplace add gmcquillan/sdlc-harness
    /plugin install sdlc@gmcquillan-sdlc

**Requires:**

- `gh` — the [GitHub CLI](https://cli.github.com/), authenticated
  (`gh auth login`)
- `jq`
- `uuidgen` (from `util-linux`; used for handoff filenames)
- *(optional)* a JIRA MCP server — only if you want tickets in JIRA instead
  of GitHub Issues; see [Ticket backends](#ticket-backends)
- The [`superpowers`](https://github.com/obra/superpowers) and
  `fable-harness` plugins — the skills here wrap their brainstorming,
  planning, TDD, worktree, and fan-out primitives.

## The pipeline

A typical feature flows through the skills in order. Each is a slash
command; most run best in a fresh session.

1. **`/sdlc:interview`** — interviews you to pin down intent, then wraps
   the brainstorming skill to produce a committed spec that ends in a
   PR-scoped, context-budgeted **Decomposition** section.
2. **`/sdlc:ticket <spec>`** — translates that decomposition into one
   epic issue plus `sdlc:task` child issues with dependency edges, behind
   a dry-run approval gate.
3. **`/sdlc:next [epic#]`** — surveys the open tasks, ranks the
   *actionable* ones by how much they unblock (transitive dependents),
   and hands the highest-leverage ticket to `implement`.
4. **`/sdlc:implement [#]`** — claims an issue, maps the subsystem with
   scout subagents, branches in a worktree, plans, executes with TDD in
   fresh subagents, self-reviews, and opens a PR. **Never merges.**
5. **`/sdlc:review <PR#>`** — fans out reviewers against the issue's
   acceptance criteria, skeptic-verifies their findings, and posts a
   review. **Never merges** — a human does that.
6. **`/sdlc:fixes <PR#>`** — triages a PR's open review comments (inline,
   summary, and conversation), gates on an accept/refute table, lands
   accepted fixes through the same worktree → subagent TDD engine as
   `implement`, and replies to every thread. **Never resolves a thread,
   never merges.**

At any point, `/sdlc:handoff` and `/sdlc:resume` bridge a session that's
running out of context, and `/sdlc:cleanup` reclaims stale worktrees and
branches once work has merged.

## Ticket backends

Tickets live in GitHub Issues by default. Every ticket-touching skill —
`ticket`, `next`, `implement`, `review` — opens with a step 0 that runs
`bin/sdlc-backend.sh resolve` and branches on the result. **On the GitHub
path that is the entire cost: one bash call, then the skill continues with
its `gh` commands inline.** No adapter file is read, no wrapper sits between
the skill and `gh`.

A JIRA MCP server is an *optional* alternative. When one is connected and
you bind the repo to it, `resolve` returns `use-jira` and the skills follow
`references/backend-jira.md`, which maps each operation onto the cached tool
map; `references/backend-bind.md` covers the first-run binding prompt. The
binding is cached per repo, so the probe runs once, not once per skill.

On JIRA, `claim` now also sets the ticket's assignee and drives a
project-specific, human-confirmed "start" workflow transition, and a
merged ticket's status is closed via a similarly confirmed "done"
transition offered through `sdlc:cleanup` — both lazily discovered
against a live ticket rather than configured up front.

`tests/validate-skills.sh` enforces the split: step 0 must call the
resolver, both reference files must exist, no `references/backend-github.md`
may appear, and the five skills that shell out to `gh` — `ticket`, `next`,
`implement`, `review`, `resume` — must not lose inline `gh` commands. A new
skill that shells out to `gh` needs its own floor entry to get this
protection.

`sdlc:fixes` has one too, for the same reason — protecting its inline
`gh` usage — even though it isn't part of the ticket-backend list above:
PR comments are GitHub-native regardless of which ticket backend is
bound, so it has no step 0 to resolve.

## Skills

| Skill | Does |
|---|---|
| `sdlc:interview` | Interview → committed spec ending in a PR-scoped Decomposition |
| `sdlc:ticket <spec>` | Decomposition → epic + `sdlc:task` child issues (dry-run gated) |
| `sdlc:next [epic#]` | Survey open tasks → rank ready ones by tickets-unblocked → confirm → hand off to `implement` |
| `sdlc:implement [#]` | Claim issue → scout-map → worktree branch → plan → TDD via subagents → PR |
| `sdlc:review <PR#>` | Fan-out review vs acceptance criteria, skeptic-verified; never merges |
| `sdlc:fixes <PR#>` | Triage PR review comments → accept/refute gate → fix accepted via worktree + subagent TDD → reply to every thread; never resolves, never merges |
| `sdlc:handoff` | Commit WIP + write `.handoff-<date>-<uuid>.md`; `--continue` chains a fresh-context subagent |
| `sdlc:resume` | Verify handoff against git, re-enter the phase, archive once its work is done |
| `sdlc:cleanup` | Scan worktrees/branches, report, and (on confirmation) delete stale ones; never removes uncommitted work |

## Hooks

- **context-tripwire** (PostToolUse): estimates context (transcript
  bytes ÷ 4); nudges handoff once at 120k, hard at 150k.
- **handoff-pickup** (SessionStart): announces leftover `.handoff-*.md`
  files so fresh sessions self-resume.
- **lint-before-push** (PreToolUse/Bash): on any `git push`, auto-detects
  the project linter (Makefile `lint`, package.json `lint` script, or
  pre-commit) and blocks the push if it fails. Bypass with
  `SDLC_SKIP_LINT=1`; no linter detected → passes through.

## Tests

    for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t"; done

The tests cover the hooks (context tripwire thresholds, handoff pickup,
lint-before-push detection), the backend resolver (`bin/sdlc-backend.sh`),
validate every skill's frontmatter plus the ticket-backend invariants
described under [Ticket backends](#ticket-backends), and content-check the
load-bearing claims in individual skill bodies.

## Design docs

The design and implementation-plan documents live under `docs/`. Start
with `docs/2026-07-13-sdlc-harness-design.md` for the overall rationale.

## Contributing

Issues and pull requests are welcome. The repository dogfoods its own
pipeline — new skills go through interview → spec → ticket →
implement → review like anything else.

## License

MIT — see [LICENSE](LICENSE).
