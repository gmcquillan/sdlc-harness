# Lint-before-push gate + `sdlc:cleanup` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce linting before every `git push` via a PreToolUse hook, surface it as a step in the `implement` skill, and add a `sdlc:cleanup` skill that safely reclaims stale worktrees and branches.

**Architecture:** A new `hooks/lint-before-push.sh` PreToolUse(Bash) hook auto-detects the project linter (Makefile / package.json / pre-commit), runs it on any `git push`, and emits a `permissionDecision:"deny"` on failure — the same deterministic-hook pattern as `context-tripwire`. The `implement` skill gains a Lint step. A new prose-driven `skills/cleanup/SKILL.md` scans worktrees/branches read-only, reports, gates on human confirmation, then deletes — never touching uncommitted work.

**Tech Stack:** Bash, `jq`, `git`, Claude Code plugin hooks (`hooks.json`), Markdown SKILL files.

## Global Constraints

- Hooks are POSIX-ish Bash with `set -u`, parse the event JSON from stdin via `jq`, and emit decisions as JSON on stdout — match `hooks/context-tripwire.sh` exactly. (verbatim repo convention)
- Hook wiring uses `"${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"` in `hooks/hooks.json`.
- Every `skills/*/SKILL.md` frontmatter: `name:` equals its directory, `description:` begins with `Use when`. Enforced by `tests/validate-skills.sh`.
- Lint gate must be fail-open on hook timeout (approved): a slow/killed hook does NOT block the push; CI + `SDLC_SKIP_LINT` are the backstops.
- Cleanup never deletes uncommitted work, the current branch, or the base branch, and never deletes anything before an explicit human confirmation.
- Spec: `docs/2026-07-14-lint-and-cleanup-design.md`.

---

### Task 1: `lint-before-push` hook script + test

**Files:**
- Create: `hooks/lint-before-push.sh`
- Test: `tests/test-lint-before-push.sh`

**Interfaces:**
- Consumes: stdin JSON `{ "tool_input": { "command": "<bash string>" } }` (Claude Code PreToolUse event shape).
- Produces: on lint failure, stdout JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<msg>"}}`; otherwise no stdout and `exit 0`. Reads env var `SDLC_SKIP_LINT` (bypass when non-empty).

- [ ] **Step 1: Write the failing test**

Create `tests/test-lint-before-push.sh`:

```bash
#!/usr/bin/env bash
# lint-before-push hook: git-push gating, linter auto-detection, and
# deny/allow decisions. Each case builds a throwaway git repo so the
# detection signals (Makefile / package.json / lockfiles) are real.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../hooks/lint-before-push.sh"
pass=0; fail=0
OUT=""; RC=0

run() { # cmd_string repo_dir -> sets OUT, RC (hook runs with cwd=repo_dir)
  OUT=$( (cd "$2" && printf '{"tool_input":{"command":"%s"}}' "$1" \
    | bash "$script") 2>/dev/null )
  RC=$?
}
allow() { # desc  (allow == exit 0 with no stdout)
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}
deny() { # desc
  if printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'; then
    echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}
mkrepo() { local d; d=$(mktemp -d); git -C "$d" init -q; echo "$d"; }

# 1. Not a `git push` → allow (no repo, no linter needed).
tmp0=$(mktemp -d)
run "ls -la" "$tmp0"
allow "non-push command ignored"

# 2. `git push` but no linter detected → allow.
r=$(mkrepo)
run "git push origin master" "$r"
allow "no linter detected -> allow"

# 3. Makefile lint target that FAILS → deny.
r=$(mkrepo); printf 'lint:\n\t@exit 1\n' > "$r/Makefile"
run "git push" "$r"
deny "failing make lint -> deny push"

# 4. Makefile lint target that PASSES → allow.
r=$(mkrepo); printf 'lint:\n\t@exit 0\n' > "$r/Makefile"
run "git push" "$r"
allow "passing make lint -> allow push"

# 5. SDLC_SKIP_LINT bypasses even a failing linter.
r=$(mkrepo); printf 'lint:\n\t@exit 1\n' > "$r/Makefile"
export SDLC_SKIP_LINT=1
run "git push" "$r"
unset SDLC_SKIP_LINT
allow "SDLC_SKIP_LINT bypasses gate"

# 6. package.json with a lint script that fails → deny (npm path).
r=$(mkrepo)
printf '{"scripts":{"lint":"exit 1"}}\n' > "$r/package.json"
run "git push" "$r"
deny "failing npm lint -> deny push"

rm -rf "$tmp0"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-lint-before-push.sh`
Expected: FAIL — the hook script does not exist yet, so `bash "$script"` errors; the `allow`/`deny` assertions report FAIL. Non-zero exit.

- [ ] **Step 3: Write the hook script**

Create `hooks/lint-before-push.sh`:

```bash
#!/usr/bin/env bash
# Lint gate before every `git push` (sdlc: enforcement is a hook, not
# model discipline — same pattern as context-tripwire). PreToolUse(Bash):
# when the command is a `git push`, auto-detect the project linter, run
# it, and DENY the push on failure. Not a push, not a git repo, no linter
# detected, or SDLC_SKIP_LINT set -> allow silently. Fail-open: any
# unexpected condition allows rather than wedging the workflow.
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Gate only `git push`. Tolerate flags/remotes between the words; stop at
# a shell separator so `git commit && push` does not match.
printf '%s' "$cmd" | grep -Eq '\bgit\b[^;&|]*\bpush\b' || exit 0

# Intentional bypass (doc-only push, temporarily broken linter, etc.).
[ -n "${SDLC_SKIP_LINT:-}" ] && exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" 2>/dev/null || exit 0

# Detect the linter; first match wins. No match -> allow.
lint_cmd=""
mf=""
[ -f Makefile ] && mf=Makefile
[ -f makefile ] && mf=makefile
if [ -n "$mf" ] && grep -Eq '^lint:' "$mf"; then
  lint_cmd="make lint"
elif [ -f package.json ] && jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
  if   [ -f pnpm-lock.yaml ]; then lint_cmd="pnpm run lint"
  elif [ -f yarn.lock ];      then lint_cmd="yarn lint"
  else                             lint_cmd="npm run lint"; fi
elif [ -f .pre-commit-config.yaml ]; then
  lint_cmd="pre-commit run --all-files"
fi
[ -n "$lint_cmd" ] || exit 0

out=$(eval "$lint_cmd" 2>&1); rc=$?
[ "$rc" -eq 0 ] && exit 0   # lint passed -> allow the push

# Lint failed -> deny, feeding the tail of the output back to Claude.
tail=$(printf '%s' "$out" | tail -c 2000)
reason=$(printf 'Lint failed before push (`%s`). Fix the errors and retry, or set SDLC_SKIP_LINT=1 to bypass intentionally.\n\n%s' "$lint_cmd" "$tail")
jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
```

Then make it executable: `chmod +x hooks/lint-before-push.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-lint-before-push.sh`
Expected: PASS — `passed=6 failed=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x hooks/lint-before-push.sh tests/test-lint-before-push.sh
git add hooks/lint-before-push.sh tests/test-lint-before-push.sh
git commit -m "feat: lint-before-push hook (auto-detect linter, deny on failure)"
```

---

### Task 2: Wire the hook into `hooks.json`

**Files:**
- Modify: `hooks/hooks.json`

**Interfaces:**
- Consumes: the `hooks/lint-before-push.sh` script from Task 1.
- Produces: a live PreToolUse(Bash) registration so the gate fires on real pushes.

- [ ] **Step 1: Add the PreToolUse block**

In `hooks/hooks.json`, add a `PreToolUse` key inside `"hooks"` (alongside the existing `SessionStart` and `PostToolUse` keys). The full file becomes:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/context-tripwire.sh\" baseline"
          },
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/handoff-pickup.sh\"",
            "timeout": 10
          }
        ]
      },
      {
        "matcher": "resume|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/context-tripwire.sh\" baseline"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/lint-before-push.sh\"",
            "timeout": 120
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/context-tripwire.sh\" check"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Verify the JSON is valid**

Run: `jq . hooks/hooks.json`
Expected: pretty-prints the object with `PreToolUse` present; exit 0 (no parse error).

- [ ] **Step 3: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat: wire lint-before-push as PreToolUse(Bash) hook"
```

---

### Task 3: Add the Lint step to the `implement` skill

**Files:**
- Modify: `skills/implement/SKILL.md`

**Interfaces:**
- Consumes: nothing (prose edit).
- Produces: a Lint step so linting surfaces in-loop, with the hook as backstop; Deliver and Stop are renumbered 10→11 and 11→12.

- [ ] **Step 1: Insert the Lint step and renumber**

In `skills/implement/SKILL.md`, the current steps are `9. Self-review`, `10. Deliver`, `11. Stop`. Replace the `10.`/`11.` numbering so a new `10. Lint` sits between Self-review and Deliver. Concretely:

Insert this new step immediately after step 9 (Self-review), before the `10. **Deliver.**` line:

```markdown
10. **Lint.** Run the project's linter/formatter and fix every finding
    before pushing. The `lint-before-push` hook is a backstop, not a
    substitute — running lint here surfaces failures in-loop instead of
    as a blocked push. The same gate applies to any later push that
    fixes CI on the open PR.
```

Then change the existing `10. **Deliver.**` heading to `11. **Deliver.**` and the existing `11. **Stop.**` heading to `12. **Stop.**`. Leave the body of Deliver and Stop unchanged.

- [ ] **Step 2: Verify the renumbering is consistent**

Run: `grep -nE '^(9|10|11|12)\. ' skills/implement/SKILL.md`
Expected: exactly one line each for `9.` (Self-review), `10.` (Lint), `11.` (Deliver), `12.` (Stop), in that order.

Run: `bash tests/validate-skills.sh`
Expected: `ok: implement` present; `passed=6 failed=0` (still 6 skills at this point). Exit 0.

- [ ] **Step 3: Commit**

```bash
git add skills/implement/SKILL.md
git commit -m "docs(implement): lint before push (backstopped by the hook)"
```

---

### Task 4: `sdlc:cleanup` skill + validation

**Files:**
- Create: `skills/cleanup/SKILL.md`
- Modify: `tests/validate-skills.sh`

**Interfaces:**
- Consumes: nothing (prose skill + one-word test-list edit).
- Produces: a discoverable `cleanup` skill; `validate-skills.sh` now expects it.

- [ ] **Step 1: Add `cleanup` to the validator's expected list (failing check first)**

In `tests/validate-skills.sh`, change:

```bash
expected="interview ticket implement review handoff resume"
```

to:

```bash
expected="interview ticket implement review handoff resume cleanup"
```

- [ ] **Step 2: Run the validator to verify it now fails**

Run: `bash tests/validate-skills.sh`
Expected: FAIL — `FAIL: cleanup: SKILL.md missing`, `passed=6 failed=1`, non-zero exit.

- [ ] **Step 3: Write the cleanup skill**

Create `skills/cleanup/SKILL.md`:

```markdown
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

1. **Detect the base branch.** `git remote show origin 2>/dev/null | sed
   -n 's/.*HEAD branch: //p'`; fall back to whichever of `main`/`master`
   exists. Record the current branch (`git branch --show-current`).
2. **Scan (all read-only — nothing is deleted in this step).**
   - **Uncommitted changes:** `git status --porcelain` in the main
     working tree, and for each worktree path from step's worktree list.
     Any output = that tree is dirty.
   - **Worktrees:** `git worktree list --porcelain`. For each (excluding
     the main tree and the one you are standing in), note its branch and
     whether that branch is merged into base or has upstream `[gone]`.
     Also run `git worktree prune --dry-run` for stale administrative
     entries (worktree dirs that no longer exist on disk).
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
   Prunable worktrees, Deletable branches (merged / upstream-gone, each
   with the reason), and Review-manually branches. If everything is
   clean, say so and stop.
4. **Confirmation gate (the human gate).** Present the deletable
   worktrees and branches and ask the user to confirm — all, or a
   selected subset. Delete NOTHING before an explicit yes.
5. **Execute** only what was confirmed:
   - Worktrees: `git worktree remove <path>` (add `--force` ONLY for a
     dirty worktree the user explicitly approved), then `git worktree
     prune`.
   - Branches: `git branch -d <branch>` for merged; `git branch -D
     <branch>` for upstream-gone (state the reason when you do).
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
```

- [ ] **Step 4: Run the validator to verify it passes**

Run: `bash tests/validate-skills.sh`
Expected: PASS — `ok: cleanup` present, `passed=7 failed=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/cleanup/SKILL.md tests/validate-skills.sh
git commit -m "feat: sdlc:cleanup skill (safe worktree/branch reclamation)"
```

---

### Task 5: README updates

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing (docs).
- Produces: user-facing docs for the new skill and hook.

- [ ] **Step 1: Add the cleanup row to the Skills table**

In `README.md`, in the `## Skills` table, add this row immediately after the `sdlc:resume` row:

```markdown
| `sdlc:cleanup` | Scan worktrees/branches, report, and (on confirmation) delete stale ones; never removes uncommitted work |
```

- [ ] **Step 2: Add the lint hook to the Hooks section**

In `README.md`, in the `## Hooks` list, add this bullet after the `handoff-pickup` bullet:

```markdown
- **lint-before-push** (PreToolUse/Bash): on any `git push`, auto-detects
  the project linter (Makefile `lint`, package.json `lint` script, or
  pre-commit) and blocks the push if it fails. Bypass with
  `SDLC_SKIP_LINT=1`; no linter detected → passes through.
```

- [ ] **Step 3: Update the test-count / test line if needed**

Confirm the Tests section still runs everything:

Run: `for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t"; done`
Expected: all scripts print `failed=0` and exit 0 (test-context-tripwire, test-handoff-pickup, test-lint-before-push, validate-skills).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README rows for sdlc:cleanup and lint-before-push hook"
```

---

## Self-Review

**Spec coverage:**
- Part A (lint hook: push detection, SKIP env, repo check, 3-signal detection, deny with tail) → Task 1 (script + test). ✓
- Part A wiring (hooks.json PreToolUse, 120s timeout) → Task 2. ✓
- Part B (implement Lint step, renumber, CI-fix note) → Task 3. ✓
- Part C (cleanup skill: scan, classify, confirm, delete, safety invariants) → Task 4. ✓
- Part D (hooks.json → Task 2; test-lint-before-push → Task 1; validate-skills cleanup → Task 4; README → Task 5). ✓
- Fail-open on timeout → Global Constraints + hooks.json `timeout:120` (Claude Code kills the hook at timeout without denying). ✓

**Placeholder scan:** No deferred-work markers; every code and prose block is complete. ✓

**Type/name consistency:** `lint-before-push.sh` env var `SDLC_SKIP_LINT` and JSON keys (`hookSpecificOutput`/`permissionDecision`/`permissionDecisionReason`) are identical across the script, its test, the README, and the skill. `expected="… cleanup"` matches the `skills/cleanup/` dir and its `name: cleanup` frontmatter. ✓
