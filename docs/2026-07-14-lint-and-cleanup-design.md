# Lint-before-push gate + `sdlc:cleanup` skill — design

Date: 2026-07-14

## Motivation

Two workflow gaps in the SDLC harness:

1. **Linting is not enforced before a PR push.** CI catches lint
   failures, but only after a push + a round trip. The most painful case
   is pushing a *fix* for a prior CI failure and having that follow-up
   push fail CI again on a lint error — a second wasted round trip. That
   follow-up push often happens in an ad-hoc session that is **not**
   running the `implement` skill, so a skill-only instruction cannot
   cover it.
2. **Branches and worktrees accumulate.** `sdlc:implement` creates a
   worktree and an `sdlc/<issue#>-<slug>` branch per issue. After PRs
   merge (usually squash-merged, so the remote branch is deleted), the
   local branch and worktree linger. There is no janitor.

## Part A — `lint-before-push` hook (enforcement backstop)

New `hooks/lint-before-push.sh`, wired as a **PreToolUse** hook with
matcher `Bash`. Fires on every Bash tool call; the script itself decides
relevance. This is the same hook-based, deterministic-enforcement pattern
as `context-tripwire` (spec P3: enforcement is a hook, not model
discipline).

### Logic

1. Read stdin JSON; extract `.tool_input.command` with `jq`.
2. If the command is **not** a `git push` invocation → `exit 0` (allow,
   silent). Detection: match a `git` word followed by a `push` word
   (tolerant of flags/remotes between them). False positives (e.g. the
   string `git push` inside an unrelated command) at worst run the linter
   once — acceptable.
3. **Escape hatch:** if `SDLC_SKIP_LINT` is set (non-empty) → allow.
   Documented, for intentional doc-only pushes or a temporarily broken
   linter.
4. `root=$(git rev-parse --show-toplevel)`; not a git repo → allow.
5. **Auto-detect the linter**, first match wins; no match → allow
   silently:
   1. `Makefile`/`makefile` with a `^lint:` target → `make lint`
   2. `package.json` with a `.scripts.lint` key → package manager from
      the lockfile: `pnpm-lock.yaml` → `pnpm run lint`; `yarn.lock` →
      `yarn lint`; else `npm run lint`
   3. `.pre-commit-config.yaml` → `pre-commit run --all-files`
6. Run the detected command in `root`, capturing combined output.
   - Exit 0 → allow (`exit 0`).
   - Non-zero → emit a deny decision:
     ```json
     {"hookSpecificOutput":{"hookEventName":"PreToolUse",
      "permissionDecision":"deny","permissionDecisionReason":"<msg>"}}
     ```
     `<msg>` = a short header + the **tail** of the lint output truncated
     to ~2000 chars + "Fix the lint errors and retry, or set
     `SDLC_SKIP_LINT=1` to bypass intentionally."

### Notes / trade-offs

- Runs on **every** `git push`, not only PR-creating ones — a hook cannot
  reliably distinguish them. The `SDLC_SKIP_LINT` escape hatch is the
  relief valve. This deliberately covers the ad-hoc CI-fix push.
- Latency: one synchronous lint run per push. `hooks.json` sets a
  ~120s timeout. A killed/timed-out hook must not wedge the session; if
  the timeout is hit the push is not blocked (fail-open), consistent with
  "a false pass is cheaper than a wedged workflow" — the escape hatch and
  CI remain as backstops.
- No network, deterministic, `set -u`. Matches existing hook style.

## Part B — `implement` skill Lint step

In `skills/implement/SKILL.md`, insert a new **step 10 "Lint"** before
Deliver; renumber Deliver 10→11 and Stop 11→12, and fix any cross
references.

> **Lint.** Run the project's linter/formatter and fix every finding
> before pushing. The `lint-before-push` hook is a backstop, not a
> substitute — running lint here surfaces failures in-loop instead of as
> a blocked push. The same gate applies to any later push that fixes CI
> on the open PR.

## Part C — `sdlc:cleanup` skill

New `skills/cleanup/SKILL.md`, prose-driven (like `implement`/`review`;
no companion script). Frontmatter `name: cleanup`, description begins
"Use when". Invoked `/sdlc:cleanup`.

### Checklist

1. **Scan (all read-only).** Detect the base branch (`main` vs
   `master`). Gather:
   - **Uncommitted changes:** `git status --porcelain` in the main
     working tree and in each worktree.
   - **Worktrees:** `git worktree list --porcelain`. Flag a worktree when
     its branch is merged into base or its upstream is `[gone]`. Also
     `git worktree prune --dry-run` for stale administrative entries.
   - **Local branches**, classified:
     - **merged into base** (`git branch --merged <base>`) — safe.
     - **upstream `[gone]`** (`%(upstream:track)` = `[gone]`) — the
       squash-merged-PR case (remote branch deleted on merge); the common
       one. Safe, but requires `-D` since it may not be merged into the
       *local* base.
     - **has unpushed/unmerged commits** — listed as "review manually",
       never auto-deleted.
     - Excluded always: current branch, base branch, any branch checked
       out in a worktree (unless that worktree is being removed too).
2. **Report** in those categories, with the deletable items and why.
3. **Confirmation gate** (the human gate): delete-all-safe, or select a
   subset. Nothing is deleted before this.
4. **Execute** on confirm:
   - Worktrees: `git worktree remove <path>` then `git worktree prune`.
   - Branches: `git branch -d` for merged; `git branch -D` for upstream
     `[gone]` (reason shown in the report).
   - **Uncommitted files: reported only, never deleted.**
5. **Report** what was removed.

### Safety invariants (stated in the skill)

- Never delete uncommitted work — it is surfaced for the human, never
  removed.
- Never delete the current branch or the base branch.
- Never force-remove a worktree with uncommitted changes without explicit
  per-item confirmation.
- No deletion of any kind before the confirmation gate.

## Part D — wiring & tests

- **`hooks/hooks.json`:** add a `PreToolUse` block, matcher `Bash`,
  command `"${CLAUDE_PLUGIN_ROOT}/hooks/lint-before-push.sh"`, timeout
  ~120s.
- **`tests/test-lint-before-push.sh`:** temp git repos exercising —
  failing linter → deny; passing linter → allow; no linter → allow;
  `SDLC_SKIP_LINT=1` → allow; non-`git push` command → allow. Asserts on
  the emitted JSON / exit behavior.
- **`tests/validate-skills.sh`:** add `cleanup` to the `expected` list.
- **`README.md`:** add a `sdlc:cleanup` row to the Skills table and a
  `lint-before-push` bullet to the Hooks section.

## Out of scope

- Configurable per-project lint command overrides beyond the three
  auto-detected signals (add later if a project needs it).
- Remote branch pruning (`git fetch --prune`) and deleting *remote*
  branches — cleanup operates on the local workspace only.
- Cleaning `.handoff-*.md` files — owned by `sdlc:resume`.
