# sdlc Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `sdlc` Claude Code plugin: six SDLC-pipeline skills (interview, ticket, implement, review, handoff, resume) plus two hooks (context-tripwire, handoff-pickup) with shell tests, per `docs/2026-07-13-sdlc-harness-design.md`.

**Architecture:** Thin orchestration wrappers (spec P1): each skill is a checklist of state transitions over `gh`/`git` plus explicit "invoke `<other-skill>` now" steps. GitHub + committed docs are the state store. Hooks are plain bash reading hook-input JSON on stdin, mirroring fable-harness's hook patterns exactly.

**Tech Stack:** Markdown skills (Claude Code plugin format), bash + `jq` hooks, `gh` CLI, plain-bash test scripts (no test framework).

## Global Constraints

- Repo: `~/src/sdlc-harness`. Plugin name: `sdlc`. Version: `0.1.0`. Marketplace name: `gmcquillan-sdlc` (own marketplace, `source: "./"` — same pattern as fable-harness; the spec's "add to existing marketplace" is superseded because that marketplace lives inside the fable-harness repo).
- Hook dependencies: standard POSIX userland only — bash, `jq`, `git`, coreutils, `grep`/`sed`/`awk`/`find` (the same set fable-harness's hooks already use), plus `uuidgen` (util-linux) for handoff filenames. No new dependencies.
- Context thresholds: SOFT = `120000` tokens, HARD = `150000` tokens; estimate = transcript bytes ÷ 4.
- Handoff filename format (exact): `.handoff-$(date +%Y-%m-%d)-$(uuidgen).md`, written at the repo root, matched everywhere by glob `.handoff-*.md`.
- GitHub labels (exact strings): `sdlc:epic`, `sdlc:task`, `sdlc:in-progress`, `sdlc:in-review`.
- Branch naming: `sdlc/<issue#>-<slug>`.
- Skills never merge PRs, never push to `main`/`master`.
- Every SKILL.md has YAML frontmatter with `name:` (matching its directory) and a `description:` beginning "Use when".
- Hook cache dirs live under `$HOME/.claude/cache/<hook-name>/`, keyed by `session_id`, cleaned with `find -mtime +7 -delete` at baseline (fable-harness convention).
- Test scripts exit 0 on all-pass, exit 1 on any failure, and print `ok:`/`FAIL:` per assertion.
- Commit after every task.

---

### Task 1: Plugin scaffolding + skill-validation harness

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `.gitignore`
- Create: `tests/validate-skills.sh`

**Interfaces:**
- Produces: `tests/validate-skills.sh` — run with no args from anywhere; discovers `skills/*/SKILL.md`; later tasks make it pass by adding conforming skills. Exits 1 while `skills/` is missing or empty (this is the harness's "failing test" state).

- [ ] **Step 1: Write the validation test (it must fail first)**

`tests/validate-skills.sh`:

```bash
#!/usr/bin/env bash
# Validates every skills/*/SKILL.md: frontmatter fence present, name: matches
# its directory, description: non-empty and begins "Use when".
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
pass=0; fail=0
ok()   { echo "ok: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

expected="interview ticket implement review handoff resume"
for name in $expected; do
  f="$root/skills/$name/SKILL.md"
  if [ ! -f "$f" ]; then bad "$name: SKILL.md missing"; continue; fi
  head -1 "$f" | grep -qx -- '---' || { bad "$name: no frontmatter fence"; continue; }
  fm=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$f")
  printf '%s\n' "$fm" | grep -qx "name: $name" \
    || { bad "$name: frontmatter name != directory"; continue; }
  desc=$(printf '%s\n' "$fm" | sed -n 's/^description: //p')
  case "$desc" in
    "Use when"*) ok "$name" ;;
    "") bad "$name: empty description" ;;
    *) bad "$name: description must begin 'Use when'" ;;
  esac
done
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/validate-skills.sh`
Expected: `FAIL: interview: SKILL.md missing` (×6), `passed=0 failed=6`, exit 1.

- [ ] **Step 3: Write the manifests and .gitignore**

`.claude-plugin/plugin.json`:

```json
{
  "name": "sdlc",
  "description": "Human-gated SDLC pipeline for Claude Code: interview→spec, spec→GitHub issues, issue→implementation branch, PR review — with a 150k context tripwire and session handoff. Wraps superpowers and fable-harness skills.",
  "version": "0.1.0",
  "author": {
    "name": "Gavin McQuillan",
    "email": "gavin.mcquillan@gmail.com"
  },
  "license": "MIT",
  "homepage": "https://github.com/gmcquillan/sdlc-harness",
  "repository": "https://github.com/gmcquillan/sdlc-harness",
  "keywords": ["sdlc", "workflow", "github-issues", "context-management", "handoff", "hooks"]
}
```

`.claude-plugin/marketplace.json`:

```json
{
  "name": "gmcquillan-sdlc",
  "owner": {
    "name": "Gavin McQuillan",
    "email": "gavin.mcquillan@gmail.com"
  },
  "metadata": {
    "description": "SDLC pipeline plugin",
    "version": "1.0.0"
  },
  "plugins": [
    {
      "name": "sdlc",
      "source": "./",
      "description": "Human-gated SDLC pipeline: interview, ticket, implement, review, handoff, resume — with a 150k context tripwire.",
      "version": "0.1.0",
      "strict": true
    }
  ]
}
```

`.gitignore`:

```
.handoff-*.md
```

- [ ] **Step 4: Verify manifests parse**

Run: `jq -e .name .claude-plugin/plugin.json .claude-plugin/marketplace.json`
Expected: `"sdlc"` then `"gmcquillan-sdlc"`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/validate-skills.sh
git add .claude-plugin .gitignore tests/validate-skills.sh
git commit -m "feat: plugin scaffolding + skill validation harness"
```

---

### Task 2: context-tripwire hook + test

**Files:**
- Create: `hooks/context-tripwire.sh`
- Test: `tests/test-context-tripwire.sh`

**Interfaces:**
- Consumes: hook-input JSON on stdin with `.session_id` and `.transcript_path` (Claude Code PostToolUse/SessionStart contract).
- Produces: `context-tripwire.sh baseline` (SessionStart) and `context-tripwire.sh check` (PostToolUse). Check mode emits `{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:"..."}}` containing the word `SOFT` at ≥120k estimated tokens and `HARD` at ≥150k, each at most once per session. Cache dir: `$HOME/.claude/cache/context-tripwire/`.

- [ ] **Step 1: Write the failing test**

`tests/test-context-tripwire.sh`:

```bash
#!/usr/bin/env bash
# Thresholds, debounce, baseline-reset, and sidechain-skip for the
# context tripwire. Overrides HOME so the cache dir is sandboxed.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../hooks/context-tripwire.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
pass=0; fail=0
OUT=""; RC=0
hook() { # mode sid transcript_path -> sets OUT, RC
  OUT=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$2" "$3" \
    | bash "$script" "$1" 2>/dev/null)
  RC=$?
}
contains() { # desc needle
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "$2"; then
    echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}
empty() { # desc
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}

tp="$tmp/main.jsonl"
hook baseline s1 "$tp"

head -c 400000 /dev/zero > "$tp"                       # ≈100k tokens
hook check s1 "$tp"
empty "below soft: silent"

head -c 500000 /dev/zero > "$tp"                       # ≈125k tokens
hook check s1 "$tp"
contains "soft fires at 125k" SOFT
hook check s1 "$tp"
empty    "soft debounced"

head -c 620000 /dev/zero > "$tp"                       # ≈155k tokens
hook check s1 "$tp"
contains "hard fires at 155k" HARD
hook check s1 "$tp"
empty    "hard debounced"

hook baseline s1 "$tp"                                 # new session baseline
hook check s1 "$tp"
contains "baseline re-arms (hard refires)" HARD

side="$tmp/sidechain.jsonl"; head -c 900000 /dev/zero > "$side"
hook baseline s2 "$tp"
hook check s2 "$side"
empty "sidechain transcript ignored"

hook check s3 "$side"                                  # no baseline recorded
contains "no-baseline still checks" HARD

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-context-tripwire.sh`
Expected: every assertion FAILs (script missing — `hook` gets rc=127 from bash, so every `empty`/`contains` check fails on the `RC -eq 0` requirement), `failed=8`, exit 1.

- [ ] **Step 3: Write the hook**

`hooks/context-tripwire.sh`:

```bash
#!/usr/bin/env bash
# Context-budget tripwire (sdlc spec P3: deterministic, not model discipline).
#   context-tripwire.sh baseline — SessionStart: record the main transcript
#                                  path; clear fired-threshold markers
#   context-tripwire.sh check    — PostToolUse (all tools): estimate live
#                                  context as transcript-bytes/4; nudge a
#                                  handoff once at SOFT and once at HARD.
# The byte heuristic overestimates after compaction, which fails safe
# (early handoff, never a blown budget).
set -u
mode="${1:-check}"
input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
dir="$HOME/.claude/cache/context-tripwire"
soft=120000
hard=150000

mkdir -p "$dir" 2>/dev/null || exit 0

if [ "$mode" = "baseline" ]; then
  find "$dir" -type f -mtime +7 -delete 2>/dev/null
  printf '%s' "$tp" > "$dir/$sid.transcript"
  rm -f "$dir/$sid.soft" "$dir/$sid.hard"
  exit 0
fi

# check mode. Subagent tool calls report a sidechain transcript — that is
# the subagent's context, not this session's; never measure it. If no
# baseline exists (plugin installed mid-session), check anyway: a false
# nudge is cheaper than a silent tripwire.
main_tp=$(cat "$dir/$sid.transcript" 2>/dev/null || true)
if [ -n "$main_tp" ] && [ -n "$tp" ] && [ "$tp" != "$main_tp" ]; then
  exit 0
fi
[ -f "$tp" ] || exit 0
bytes=$(wc -c < "$tp" 2>/dev/null) || exit 0
tokens=$((bytes / 4))

fire() {
  jq -cn --arg m "$1" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
}

if [ "$tokens" -ge "$hard" ] && [ ! -f "$dir/$sid.hard" ]; then
  : > "$dir/$sid.hard"
  fire "Context tripwire HARD: estimated context ~${tokens} tokens, at or \
over the 150k budget. Invoke the sdlc:handoff skill NOW: commit WIP, write \
the handoff file, then end the turn — or pass --continue to dispatch a \
fresh-context subagent and act as supervisor only. Start no new work in \
this session."
elif [ "$tokens" -ge "$soft" ] && [ ! -f "$dir/$sid.soft" ]; then
  : > "$dir/$sid.soft"
  fire "Context tripwire SOFT: estimated context ~${tokens} tokens (120k of \
the 150k budget). Finish the current atomic step, then invoke the \
sdlc:handoff skill. Until then, delegate any remaining exploration, test \
runs, or verification to subagents — their transcripts do not enter this \
context (delegate breadth, keep judgment)."
fi
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x hooks/context-tripwire.sh && bash tests/test-context-tripwire.sh`
Expected: 8× `ok:`, `passed=8 failed=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x hooks/context-tripwire.sh tests/test-context-tripwire.sh
git add hooks/context-tripwire.sh tests/test-context-tripwire.sh
git commit -m "feat: context-tripwire hook (soft 120k / hard 150k, debounced)"
```

---

### Task 3: handoff-pickup hook + test

**Files:**
- Create: `hooks/handoff-pickup.sh`
- Test: `tests/test-handoff-pickup.sh`

**Interfaces:**
- Consumes: hook-input JSON on stdin with `.cwd` (SessionStart contract). Handoff filename glob `.handoff-*.md` from Global Constraints.
- Produces: plain-text stdout (SessionStart stdout becomes session context, same as fable-harness's `principles.md` cat). Silent (no output, exit 0) when no handoff files exist.

- [ ] **Step 1: Write the failing test**

`tests/test-handoff-pickup.sh`:

```bash
#!/usr/bin/env bash
# Zero / one / many handoff files; non-repo cwd falls back to cwd itself.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../hooks/handoff-pickup.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
OUT=""; RC=0
hook() { # cwd -> sets OUT, RC
  OUT=$(printf '{"cwd":"%s","session_id":"t"}' "$1" | bash "$script" 2>&1)
  RC=$?
}
contains() { # desc needle
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "$2"; then
    echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (got: ${OUT:-<empty>})"; fail=$((fail+1)); fi
}
empty() { # desc
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (expected empty, got: $OUT)"; fail=$((fail+1)); fi
}

repo="$tmp/repo"; mkdir -p "$repo/sub"; git -C "$repo" init -q
hook "$repo"
empty "no handoff files: silent"

touch "$repo/.handoff-2026-07-13-aaaa.md"
hook "$repo"
contains "one file: named"        ".handoff-2026-07-13-aaaa.md"
hook "$repo"
contains "instructs resume"       "sdlc:resume"
hook "$repo/sub"
contains "found from subdir"      ".handoff-2026-07-13-aaaa.md"

touch "$repo/.handoff-2026-07-14-bbbb.md"
hook "$repo"
contains "many: lists first"  ".handoff-2026-07-13-aaaa.md"
contains "many: lists second" ".handoff-2026-07-14-bbbb.md"

plain="$tmp/plain"; mkdir -p "$plain"; touch "$plain/.handoff-2026-07-13-cccc.md"
hook "$plain"
contains "non-repo cwd works" ".handoff-2026-07-13-cccc.md"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-handoff-pickup.sh`
Expected: all 7 assertions FAIL (rc check: script missing), `passed=0 failed=7`, exit 1.

- [ ] **Step 3: Write the hook**

`hooks/handoff-pickup.sh`:

```bash
#!/usr/bin/env bash
# Handoff auto-pickup. SessionStart (startup|clear): if the project root
# holds .handoff-*.md files from a previous session, tell the fresh session
# to invoke sdlc:resume — the human's only manual step is launching claude.
set -u
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$cwd"
files=$(find "$root" -maxdepth 1 -name '.handoff-*.md' 2>/dev/null | sort)
[ -n "$files" ] || exit 0
n=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
echo "SDLC handoff pickup: $n handoff file(s) from a previous session:"
printf '%s\n' "$files"
echo "Invoke the sdlc:resume skill to continue that work. It verifies the \
recorded state against git (trust git over prose) and archives the file."
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x hooks/handoff-pickup.sh && bash tests/test-handoff-pickup.sh`
Expected: 7× `ok:`, `passed=7 failed=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x hooks/handoff-pickup.sh tests/test-handoff-pickup.sh
git add hooks/handoff-pickup.sh tests/test-handoff-pickup.sh
git commit -m "feat: handoff-pickup SessionStart hook"
```

---

### Task 4: hooks.json wiring

**Files:**
- Create: `hooks/hooks.json`

**Interfaces:**
- Consumes: the two hook scripts from Tasks 2–3 via `${CLAUDE_PLUGIN_ROOT}`.
- Produces: PostToolUse (all tools) → `context-tripwire.sh check`; SessionStart `startup|clear` → `context-tripwire.sh baseline` + `handoff-pickup.sh`; SessionStart `resume|compact` → `context-tripwire.sh baseline` only (re-arm thresholds; do NOT re-announce handoff files into a continuing conversation).

- [ ] **Step 1: Write hooks.json**

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

- [ ] **Step 2: Verify it parses and references real files**

Run: `jq -e '.hooks | keys' hooks/hooks.json && ls hooks/context-tripwire.sh hooks/handoff-pickup.sh`
Expected: `["PostToolUse","SessionStart"]`; both files listed.

- [ ] **Step 3: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat: wire hooks (tripwire on PostToolUse, pickup on SessionStart)"
```

---

### Task 5: handoff skill

**Files:**
- Create: `skills/handoff/SKILL.md`

**Interfaces:**
- Consumes: handoff filename format and `.gitignore` glob from Global Constraints.
- Produces: the handoff-file markdown template below. `resume` (Task 6) parses these exact section headings: `## Phase`, `## Refs`, `## Done`, `## State`, `## Next`, `## Gotchas`.

- [ ] **Step 1: Write SKILL.md**

`skills/handoff/SKILL.md`:

````markdown
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
2. **Ensure the ignore rule.** If `.handoff-*.md` is not in the
   project's `.gitignore`, append it and commit that one-line change.
3. **Write the handoff file** at the repo root:

   ```bash
   f=".handoff-$(date +%Y-%m-%d)-$(uuidgen).md"
   ```

   Content template (keep these exact headings — sdlc:resume parses them):

   ```markdown
   # SDLC Handoff

   ## Phase
   <interview|ticket|implement|review> — step <N> of the skill checklist

   ## Refs
   - Issue: #<n> / PR: #<n> / Epic: #<n>
   - Branch: sdlc/<issue#>-<slug>
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
     to `<file>`. Start a fresh session in this directory — it will pick
     the handoff up automatically." (The handoff-pickup SessionStart hook
     injects it.)
   - **`--continue` (only if invoked with it):** dispatch ONE
     general-purpose subagent with the prompt: "Read `<repo-root>/<file>`
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
````

- [ ] **Step 2: Validate**

Run: `bash tests/validate-skills.sh`
Expected: `ok: handoff`; still `FAIL:` for the five unwritten skills.

- [ ] **Step 3: Commit**

```bash
git add skills/handoff/SKILL.md
git commit -m "feat: handoff skill (write side + supervisor rule)"
```

---

### Task 6: resume skill

**Files:**
- Create: `skills/resume/SKILL.md`

**Interfaces:**
- Consumes: handoff-file headings from Task 5 (`## Phase`, `## Refs`, `## Done`, `## State`, `## Next`, `## Gotchas`); the four phase skills it re-enters (`sdlc:interview`, `sdlc:ticket`, `sdlc:implement`, `sdlc:review`).

- [ ] **Step 1: Write SKILL.md**

`skills/resume/SKILL.md`:

````markdown
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
````

- [ ] **Step 2: Validate**

Run: `bash tests/validate-skills.sh`
Expected: `ok: handoff`, `ok: resume`; 4 FAILs remain.

- [ ] **Step 3: Commit**

```bash
git add skills/resume/SKILL.md
git commit -m "feat: resume skill (read side, verify-then-reenter)"
```

---

### Task 7: interview skill

**Files:**
- Create: `skills/interview/SKILL.md`

**Interfaces:**
- Consumes: `superpowers:brainstorming`, `fable-harness:integration-scan`.
- Produces: spec at `docs/specs/YYYY-MM-DD-<topic>.md` ending with a `## Decomposition` section whose task format Task 8's `ticket` skill parses: `### T<n>: <title>` blocks each containing `**Acceptance criteria:**` (checkbox list), `**Scope:**`, `**Depends on:**` (T-refs or "none"), `**Out of scope:**`.

- [ ] **Step 1: Write SKILL.md**

`skills/interview/SKILL.md`:

````markdown
---
name: interview
description: Use when starting a new feature or project under the SDLC pipeline — interviews the user to surface intent, wraps superpowers:brainstorming to produce a committed spec that ends with a PR-scoped, context-budgeted Decomposition section, then hands off to sdlc:ticket.
---

# SDLC Interview → Spec

Wraps `superpowers:brainstorming` for the dialogue mechanics (one
question at a time, 2–3 approaches, section-by-section approval) with
three SDLC overrides. Invoke `superpowers:brainstorming` NOW and follow
it, applying the overrides below. Create a todo per override.

## Override 1 — Interview additions

Beyond brainstorming's questions, explicitly establish: **intent** (the
problem behind the request), **users**, **non-goals**, **success
criteria**, and **constraints**. Before proposing approaches, dispatch
`fable-harness:integration-scan` — integrator subagents, one capability
statement each, in a single message — so "wire, don't build" options
surface during the interview, not after design lock-in. Keep the scan in
subagents: their transcripts must not enter this session's context.

## Override 2 — Spec must end with `## Decomposition`

An ordered task list; each task is one PR and an estimated ≤100k tokens
of implementation work (headroom under the 150k tripwire). Sizing
heuristics per task: one subsystem, ≲10 files, ≲500 LOC diff. Exact
format (sdlc:ticket parses this):

```markdown
## Decomposition

### T1: <imperative title>
**Acceptance criteria:**
- [ ] <observable, testable criterion>
- [ ] <another>
**Scope:** <files/areas expected to change>
**Depends on:** none
**Out of scope:** <explicit exclusions>

### T2: <imperative title>
**Acceptance criteria:**
- [ ] <criterion>
**Scope:** <files/areas>
**Depends on:** T1
**Out of scope:** <exclusions>
```

If any task fails the sizing heuristics, split it before presenting the
spec. Recurring oversize discovered later (mid-implement handoffs) is
feedback to tighten this section's estimates.

## Override 3 — Terminal state

Brainstorming normally ends by invoking writing-plans. **Do not.**
Per-issue planning happens inside sdlc:implement, in fresh context. After
the spec is committed to `docs/specs/YYYY-MM-DD-<topic>.md` and the user
has approved it, end with exactly this handoff:

> "Spec committed to `<path>`. Run `/sdlc:ticket <path>` (fresh session
> recommended) to create the GitHub issues."
````

- [ ] **Step 2: Validate**

Run: `bash tests/validate-skills.sh`
Expected: `ok:` ×3; 3 FAILs remain.

- [ ] **Step 3: Commit**

```bash
git add skills/interview/SKILL.md
git commit -m "feat: interview skill (brainstorming wrapper + decomposition)"
```

---

### Task 8: ticket skill

**Files:**
- Create: `skills/ticket/SKILL.md`

**Interfaces:**
- Consumes: `## Decomposition` format from Task 7; label names from Global Constraints.
- Produces: one `sdlc:epic` issue whose body contains a GitHub task list of child refs; child `sdlc:task` issues whose bodies contain the headings `## Context`, `## Acceptance criteria`, `## Scope`, `## Depends on`, `## Out of scope`, `## Epic` (Task 9's `implement` reads these).

- [ ] **Step 1: Write SKILL.md**

`skills/ticket/SKILL.md`:

````markdown
---
name: ticket
description: Use when a committed SDLC spec with a Decomposition section needs GitHub issues created — translates each decomposition task into a PR-scoped child issue under one epic issue, with a dry-run approval gate and idempotency check. Invoke as sdlc:ticket <spec-path>.
---

# SDLC Ticket: Spec → GitHub Issues

Pure translation plus `gh` calls. Create a todo per checklist item.

## Checklist

1. **Preconditions:** `gh auth status` succeeds (else stop; tell the user
   to run `! gh auth login`). The spec path argument exists and contains
   a `## Decomposition` section (else stop and say what is missing —
   re-run sdlc:interview to produce one).
2. **Idempotency check:** derive the spec slug (filename minus date and
   extension). Search: `gh issue list --label "sdlc:epic" --state all
   --search "<slug>" --json number,title`. If an epic exists, STOP and
   ask: update the existing epic in place, or abort? Never silently
   duplicate.
3. **Ensure labels** (idempotent):

   ```bash
   for l in "sdlc:epic" "sdlc:task" "sdlc:in-progress" "sdlc:in-review"; do
     gh label create "$l" --force --description "sdlc pipeline"
   done
   ```

4. **Dry-run gate:** parse every `### T<n>:` block and present a table —
   T#, title, criteria count, depends-on — plus the epic title
   (`[epic] <spec slug>`). Get explicit user approval BEFORE creating
   anything. This is a human gate; do not skip it.
5. **Create the epic** (placeholder body; task list is filled in step 7):

   ```bash
   gh issue create --label "sdlc:epic" --title "[epic] <slug>" \
     --body "Spec: \`<spec-path>\` (commit <hash>)

   Task list populated after child issues are created."
   ```

6. **Create child issues**, one per decomposition task, in T-order (so
   depends-on references point backward at existing issues). Record each
   created number to translate `T<n>` → `#<issue>`:

   ```bash
   gh issue create --label "sdlc:task" --title "<T-title>" --body "## Context
   <one paragraph> — spec §T<n> in \`<spec-path>\`

   ## Acceptance criteria
   - [ ] <copied verbatim from the spec>

   ## Scope
   <files/areas from the spec>

   ## Depends on
   <#refs translated from T-refs, or 'none'>

   ## Out of scope
   <from the spec>

   ## Epic
   #<epic-number>"
   ```

7. **Fill the epic task list** so progress renders on the epic:

   ```bash
   gh issue edit <epic#> --body "Spec: \`<spec-path>\` (commit <hash>)

   ## Tasks
   - [ ] #<child1> <title1>
   - [ ] #<child2> <title2>"
   ```

8. **Report:** epic URL, child count, and: "Run `/sdlc:implement` (fresh
   session recommended) to pick up the first unblocked issue."

## Red flags

- Creating issues before the dry-run approval → human gate violated.
- Children created out of dependency order → forward `#` references that
  don't exist yet.
````

- [ ] **Step 2: Validate**

Run: `bash tests/validate-skills.sh`
Expected: `ok:` ×4; 2 FAILs remain.

- [ ] **Step 3: Commit**

```bash
git add skills/ticket/SKILL.md
git commit -m "feat: ticket skill (epic + PR-scoped child issues)"
```

---

### Task 9: implement skill

**Files:**
- Create: `skills/implement/SKILL.md`

**Interfaces:**
- Consumes: child-issue body headings from Task 8; labels and branch format from Global Constraints; `superpowers:using-git-worktrees`, `writing-plans`, `subagent-driven-development`, `test-driven-development`, `verification-before-completion`, `requesting-code-review`; `fable-harness:systems-mapping`.
- Produces: a PR whose body contains `Closes #<issue>` plus the acceptance-criteria checklist; issue label transitions `sdlc:in-progress` → `sdlc:in-review` (Task 10's `review` reads the PR + issue).

- [ ] **Step 1: Write SKILL.md**

`skills/implement/SKILL.md`:

````markdown
---
name: implement
description: Use when an sdlc:task GitHub issue is ready to build — claims the issue, maps the subsystem via scouts, branches in a worktree, plans, executes with TDD in fresh subagents, self-reviews, and opens a PR. Never merges. Invoke as sdlc:implement [issue#].
---

# SDLC Implement: Issue → PR

The workhorse. Context discipline governs every step: **the main loop
holds judgment and state transitions; breadth goes to subagents.** If a
step will generate more than a few thousand tokens of tool output you
don't need verbatim afterward, it belongs in a subagent. Create a todo
per checklist item.

## Checklist

1. **Select the issue.** Argument given → use it. None → list candidates:
   `gh issue list --label "sdlc:task" --state open --json
   number,title,body,labels,assignees` and pick the first that is (a) not
   labeled `sdlc:in-progress` or `sdlc:in-review`, (b) unassigned, and
   (c) unblocked — every `#ref` under its `## Depends on` heading is
   CLOSED (`gh issue view <ref> --json state`). No candidate → report why
   each open task is blocked and stop.
2. **Preconditions:** clean `git status`; `gh auth status` succeeds.
   Either failure → stop and report.
3. **Claim it** (prevents double pickup by parallel sessions):
   `gh issue edit <n> --add-label "sdlc:in-progress" --add-assignee "@me"`
4. **Understand.** Read the issue body and the spec section it links —
   main loop. Then invoke `fable-harness:systems-mapping` — scout
   subagents map the affected subsystem; only their maps return to you.
   Do NOT read the subsystem file-by-file yourself.
5. **Isolate.** Invoke `superpowers:using-git-worktrees`; branch
   `sdlc/<issue#>-<slug>` (slug = kebab-cased issue title, ≤5 words).
6. **Plan.** Invoke `superpowers:writing-plans` for a per-issue plan
   scoped to the acceptance criteria; save under `docs/plans/` and COMMIT
   it to the branch — plans must survive handoffs and session death.
7. **Execute.** Invoke `superpowers:subagent-driven-development` (the
   default — each task runs in a fresh subagent, protecting this
   session's budget) with `superpowers:test-driven-development` per task.
   Fall back to inline `superpowers:executing-plans` ONLY when tasks are
   so tightly coupled that per-task subagent setup exceeds the benefit —
   and say so explicitly.
8. **Verify.** Invoke `superpowers:verification-before-completion`.
   Run full test suites in a subagent that returns a pass/fail summary
   plus failures verbatim — never page raw test logs through this
   context. Every acceptance criterion needs evidence.
9. **Self-review.** Invoke `superpowers:requesting-code-review` on the
   branch diff; fix findings before delivery (verify each finding
   technically first — no performative agreement).
10. **Deliver.**

    ```bash
    git push -u origin "sdlc/<issue#>-<slug>"
    gh pr create --title "<issue title>" --body "Closes #<issue>

    Epic: #<epic> · Spec: \`<spec-path>\` §T<n>

    ## Acceptance criteria
    - [x] <criterion — evidence: <one line>>"
    gh issue edit <n> --remove-label "sdlc:in-progress" \
      --add-label "sdlc:in-review"
    gh issue comment <n> --body "PR: <pr-url>"
    ```

11. **Stop.** Never merge; never push to main/master. Suggest:
    "Run `/sdlc:review <PR#>` in a fresh session."

## If the context tripwire fires mid-issue

Finish the current atomic step (SOFT) or stop immediately (HARD), then
invoke sdlc:handoff. The committed plan + branch + handoff file carry
everything; a mid-issue split is survivable by design.

## Red flags

- Reading file-after-file in step 4 → that is the scouts' job.
- Skipping the claim in step 3 → two sessions build the same issue.
- "Tests probably pass" in step 8 → evidence before assertions, always.
````

- [ ] **Step 2: Validate**

Run: `bash tests/validate-skills.sh`
Expected: `ok:` ×5; 1 FAIL remains.

- [ ] **Step 3: Commit**

```bash
git add skills/implement/SKILL.md
git commit -m "feat: implement skill (issue → branch → TDD → PR)"
```

---

### Task 10: review skill

**Files:**
- Create: `skills/review/SKILL.md`

**Interfaces:**
- Consumes: PR format from Task 9 (issue via `Closes #`); `fable-harness:fan-out` + `skeptic` agents; `superpowers:receiving-code-review` (fix mode).
- Produces: a `gh pr review` (approve or request-changes). Never merges.

- [ ] **Step 1: Write SKILL.md**

`skills/review/SKILL.md`:

````markdown
---
name: review
description: Use when an SDLC pull request needs review against its issue's acceptance criteria — fans out spec-compliance, correctness, and test-quality reviewers, skeptic-verifies findings, and posts a gh pr review. Never merges. Invoke as sdlc:review <PR#>.
---

# SDLC Review: PR → Verdict

The diff is reviewed by subagents; this session holds only metadata,
verdicts, and judgment. Create a todo per checklist item.

## Checklist

1. **Gather metadata (main loop, small):**
   `gh pr view <PR#> --json title,body,headRefName,files` — extract the
   linked issue from `Closes #<n>`, then
   `gh issue view <n> --json body` for the acceptance criteria and spec
   pointer. Do NOT fetch the diff into this context.
2. **Fan out reviewers** per `fable-harness:fan-out` — three subagents,
   ALL dispatched in a single message, each given the PR number, the
   acceptance criteria, and ONE dimension:
   - **Spec compliance:** does the diff satisfy every acceptance
     criterion? Anything out-of-scope smuggled in?
   - **Correctness:** logic, edge cases, error handling, concurrency.
   - **Test quality:** do tests exercise the criteria for real, or are
     they mocked facades that would pass against a stub?
   Each returns findings as `file:line — claim — severity`.
3. **Skeptic-verify significant findings:** every finding a reviewer
   rates important enough to block approval goes to a
   `fable-harness:skeptic` subagent (one finding each, dispatched in a
   single message) that tries to REFUTE it against the actual code.
   Refuted findings are dropped. No plausible-but-wrong comments reach
   the PR.
4. **Post the verdict** — comment or approve, NEVER merge:

   ```bash
   # criteria unmet or confirmed findings:
   gh pr review <PR#> --request-changes --body "<verified findings,
   grouped by dimension, each with file:line and the failure scenario>"
   # everything satisfied:
   gh pr review <PR#> --approve --body "All acceptance criteria verified:
   <one line of evidence per criterion>"
   ```

   Approval ends with: "Ready for your merge decision." The merge is
   always the human's.
5. **Fix mode (ONLY if the user asked you to fix, not just review):**
   check out the PR branch (`gh pr checkout <PR#>`), invoke
   `superpowers:receiving-code-review` on the verified findings —
   technically verify each before implementing, push fixes to the
   branch, then re-run this checklist from step 2.

## Red flags

- Pulling the full diff into the main loop "for a quick look" → that is
  the reviewers' context to spend, not yours.
- Posting reviewer findings nobody tried to refute → skeptic step is not
  optional for blocking findings.
- Merging an approved PR "to save a step" → human gate violated.
````

- [ ] **Step 2: Validate — all six skills pass**

Run: `bash tests/validate-skills.sh`
Expected: `ok:` ×6, `passed=6 failed=0`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add skills/review/SKILL.md
git commit -m "feat: review skill (fan-out + skeptic-verified PR review)"
```

---

### Task 11: README + full verification

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write README.md**

```markdown
# sdlc-harness

Human-gated SDLC pipeline for Claude Code. Each phase is a skill run in
its own (usually fresh) session; GitHub + committed docs are the state
store; a context tripwire + handoff files bridge the 150k budget.

    /sdlc:interview ──► spec ──► /sdlc:ticket ──► epic + child issues
                                                        │
      human merges ◄── /sdlc:review <PR#> ◄── PR ◄── /sdlc:implement [#]

## Install

    /plugin marketplace add ~/src/sdlc-harness
    /plugin install sdlc@gmcquillan-sdlc

Requires: `gh` (authenticated), `jq`, and the `superpowers` and
`fable-harness` plugins (skills here wrap theirs).

## Skills

| Skill | Does |
|---|---|
| `sdlc:interview` | Interview → committed spec ending in a PR-scoped Decomposition |
| `sdlc:ticket <spec>` | Decomposition → epic + `sdlc:task` child issues (dry-run gated) |
| `sdlc:implement [#]` | Claim issue → scout-map → worktree branch → plan → TDD via subagents → PR |
| `sdlc:review <PR#>` | Fan-out review vs acceptance criteria, skeptic-verified; never merges |
| `sdlc:handoff` | Commit WIP + write `.handoff-<date>-<uuid>.md`; `--continue` chains a fresh-context subagent |
| `sdlc:resume` | Verify handoff against git, archive it, re-enter the phase |

## Hooks

- **context-tripwire** (PostToolUse): estimates context (transcript
  bytes ÷ 4); nudges handoff once at 120k, hard at 150k.
- **handoff-pickup** (SessionStart): announces leftover `.handoff-*.md`
  files so fresh sessions self-resume.

## Tests

    for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t"; done

Design: `docs/2026-07-13-sdlc-harness-design.md`.
```

- [ ] **Step 2: Run everything**

Run: `bash tests/validate-skills.sh && bash tests/test-context-tripwire.sh && bash tests/test-handoff-pickup.sh`
Expected: all three end `failed=0`, overall exit 0.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with install, pipeline, and test instructions"
```

---

## Post-implementation (manual, not a plan task)

The spec's end-to-end dry run — interview a toy feature → ticket →
implement one issue → review the PR against a throwaway GitHub repo —
requires interactive dialogue with the user and a real `gh` remote. Run
it with the user after installing the plugin
(`/plugin marketplace add ~/src/sdlc-harness`); it is the acceptance
test for the pipeline as a whole.
