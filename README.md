# sdlc-harness

Human-gated SDLC pipeline for Claude Code. Each phase is a skill run in
its own (usually fresh) session; GitHub + committed docs are the state
store; a context tripwire + handoff files bridge the 150k budget.

    /sdlc:interview ──► spec ──► /sdlc:ticket ──► epic + child issues
                                                        │
                                                 /sdlc:next [#]
                                                        │
      human merges ◄── /sdlc:review <PR#> ◄── PR ◄── /sdlc:implement [#]

## Install

    /plugin marketplace add ~/src/sdlc-harness
    /plugin install sdlc@gmcquillan-sdlc

Requires: `gh` (authenticated), `jq`, `uuidgen` (util-linux; used for
handoff filenames), and the `superpowers` and `fable-harness` plugins
(skills here wrap theirs).

## Skills

| Skill | Does |
|---|---|
| `sdlc:interview` | Interview → committed spec ending in a PR-scoped Decomposition |
| `sdlc:ticket <spec>` | Decomposition → epic + `sdlc:task` child issues (dry-run gated) |
| `sdlc:next [epic#]` | Survey open tasks → rank ready ones by tickets-unblocked → confirm → hand off to `implement` |
| `sdlc:implement [#]` | Claim issue → scout-map → worktree branch → plan → TDD via subagents → PR |
| `sdlc:review <PR#>` | Fan-out review vs acceptance criteria, skeptic-verified; never merges |
| `sdlc:handoff` | Commit WIP + write `.handoff-<date>-<uuid>.md`; `--continue` chains a fresh-context subagent |
| `sdlc:resume` | Verify handoff against git, archive it, re-enter the phase |
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

Design: `docs/2026-07-13-sdlc-harness-design.md`.
