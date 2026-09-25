# Phase-Aware Auto-Continue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a context tripwire fires during `sdlc:implement` or `sdlc:review`, `sdlc:handoff` takes the `--continue` path automatically (no flag), bounded by a fixed hop cap of 10, without touching any existing human-approval gate.

**Architecture:** A new deterministic CLI, `bin/sdlc-hopcount.sh` (mirroring `bin/sdlc-drift.sh`'s minimalism and `bin/sdlc-backend.sh`'s `cmd_<name>`/dispatcher shape), owns the phase-eligibility check and the hop-count/cap arithmetic. `sdlc:handoff` step 4 calls it (bare name, via the plugin's `bin/` on `PATH` — same convention as `sdlc-backend.sh`/`sdlc-drift.sh`) and branches on its exit code; the model never computes or self-polices the cap. `sdlc:resume` needs no code change: it already reads the whole handoff file (including any `Hop:` line) as part of its existing "read it fully" step, and never needs to act on that value itself — only the *next* `sdlc:handoff` invocation (at the next tripwire) reads it back out, via the script, from the still-present prior handoff file.

**Tech Stack:** POSIX-ish `bash` (`set -u`, no bashisms beyond what the existing `bin/*.sh` already use), `grep`/`sed` for line parsing (no `jq` needed — the format is a fixed-shape single line, not JSON).

**Spec:** Issue #34 (`Phase-aware auto-continue with a hop cap in sdlc:handoff/resume`), epic #33 (`autonomous-handoff-chaining`). Both fetched live via `gh issue view 34` / `gh issue view 33` — no local spec file exists (deleted per `sdlc:ticket` step 8; the issue bodies are the complete source of truth). The refined design below (a deterministic helper script rather than prose-only `Hop:` tracking) was worked out during ticket triage and is documented in this repo's philosophy at `hooks/context-tripwire.sh`'s header comment ("sdlc spec P3: deterministic, not model discipline") — it satisfies issue #34's acceptance criteria more robustly than prose tracking would, and is not an open question.

## Global Constraints

- Cap is a fixed constant, `10`, hard-coded in `bin/sdlc-hopcount.sh` — not read from any file, not user-configurable (issue #34 AC + epic #33 non-goals).
- `interview` and `ticket` phases are never auto-continued — a tripwire there ends the turn and waits for a human, unchanged from today (epic #33 goal).
- No existing human-approval gate (`sdlc:ticket` dry-run, `sdlc:review` step 6 triage gate, never-merge, never-push-to-main) is weakened or bypassed (issue #34 AC, epic #33 non-goal).
- No scheduling/watchdog and no progress/stall detection — the cap is a flat hop count, nothing more (epic #33 non-goals).
- `hooks/context-tripwire.sh`'s thresholds and firing logic are out of scope — do not touch that file (issue #34 "Out of scope").
- No skill's internal checklist *steps* change except `skills/handoff/SKILL.md`'s step 4 — scope is `skills/handoff/SKILL.md`, `skills/resume/SKILL.md`, `README.md`, one test file (issue #34 "Scope" + "Out of scope").
- Manually invoking `sdlc:handoff --continue` in any phase must be unaffected by this change (issue #34 AC).
- Any new/modified script follows the existing `bin/*.sh` idiom: `set -u`, a `die()` that prints `<scriptname>: <msg>` to stderr, one `cmd_<name>` function per subcommand, a trailing `case` dispatcher, called by bare name (never `bin/`-prefixed) because the plugin's `bin/` directory is prepended to `PATH` (`references/backend-bind.md` explains why; `sdlc-drift.sh`/`sdlc-backend.sh` are the precedent).

## Review Focus

- **Manual `--continue` regression:** a human explicitly passing `--continue` in `interview`/`ticket`/anywhere must still work exactly as today — the new auto-check must only intercept the *unflagged* tripwire-response path, never override an explicit human flag. Task 2's step tests this by keeping the manual path's wording unconditional and gating only the *new* paragraph on "this invocation is a direct tripwire response."
- **Judgment phases must never auto-advance:** `interview` and `ticket` must fall through to the default end-turn path even when a tripwire fires mid-phase — a bug here would let unattended execution touch scope/requirements judgment the epic explicitly reserves for humans. Task 1's test suite pins this (`sdlc-hopcount.sh check interview` / `check ticket` both exit 2).
- **Cap reached must report why, not go silent or loop:** hitting the cap must fall back to the default end-turn path with a message naming the cap explicitly (issue #34 AC), not silently stop or retry. Task 1's test pins the exit-1/no-stdout contract; Task 2's step 4 wording pins the human-facing message.
- **File-supersession must delete the exact prior file, never a wildcard:** the fix in Task 2 deletes the specific prior handoff path once the new one is written — for BOTH the manual and automatic `--continue` paths, per the mid-session amendment — but a wildcard delete could destroy an unrelated, still-unresumed older handoff sitting in the same directory (this repo currently has exactly such a file, `.handoff-2026-09-15-...md`, coexisting with the one this plan implements from). The wording must reference the file by its known path only.
- **A dispatched `--continue` subagent must never block on a disambiguation question it cannot answer:** `sdlc:resume`'s newest-default rule (Task 2 step 4) must trigger specifically for `--continue` dispatches, not silently for every multi-file case — a person directly asking to resume still gets asked which file, since they can answer.
- **Malformed or absent `Hop:` input must not crash or miscount:** a prior handoff predating this feature (no `Hop:` line), a corrupted line, or a nonexistent `--prior` path must all degrade to `n=0` (hop 1), never a shell error or a wrong count. Task 1's test suite pins all three cases.

---

### Task 1: `bin/sdlc-hopcount.sh` + `tests/test-hopcount.sh`

**Files:**
- Create: `bin/sdlc-hopcount.sh`
- Create: `tests/test-hopcount.sh`

**Interfaces:**
- Consumes: nothing from other tasks (this is the foundation task).
- Produces: the CLI contract `sdlc-hopcount.sh check <phase> [prior-handoff-file]` that Task 2 calls by bare name from `skills/handoff/SKILL.md`:
  - `<phase>` ∈ `interview|ticket|implement|review` (any other string behaves like a non-eligible phase).
  - `[prior-handoff-file]` optional path.
  - Exit `2`, no stdout → phase not eligible (fall back to default end-turn path).
  - Exit `1`, no stdout → eligible, but hop cap reached (fall back to default end-turn path, report the cap as the reason).
  - Exit `0`, stdout is exactly `Hop: <n> of <cap>\n` → eligible, cap not reached (take the `--continue` path; write that exact line into the new handoff's `## State` section).

- [ ] **Step 1: Write `bin/sdlc-hopcount.sh`**

```bash
#!/usr/bin/env bash
# Deterministic hop-count/cap check for phase-aware auto-continue (sdlc
# spec P3: deterministic, not model discipline). sdlc:handoff calls this
# before deciding whether to take the --continue path automatically when
# a context tripwire fires; the model branches on the exit code below, it
# never computes the cap arithmetic itself.
#
# Unlike hooks/*.sh (which fail open with a silent exit 0), this is a CLI:
# exit codes are its interface.
#   2 = phase is not auto-continue-eligible (interview|ticket, or unknown)
#       — no stdout; ALSO used (with a stderr message) for a genuine usage
#       error, since a usage error must fall back to the same default
#       end-turn path a caller takes for any non-eligible phase
#   1 = eligible phase, but the hop cap is reached — no stdout
#   0 = eligible phase, cap not reached — stdout is exactly one line:
#       "Hop: <next> of <cap>"
set -u

CAP=10

die() { printf 'sdlc-hopcount: %s\n' "$1" >&2; exit "${2:-1}"; }

cmd_check() {
  local phase="${1:-}" prior="${2:-}"
  [ -n "$phase" ] || die "check requires a phase" 2
  case "$phase" in
    implement|review) : ;;
    # A recognized-but-ineligible phase (interview|ticket) or any unknown
    # string is a routine, expected outcome for this check, not a bug —
    # exit silently, no stderr noise for something the caller triggers on
    # every interview/ticket tripwire.
    *) exit 2 ;;
  esac

  # Malformed, absent, or missing-file Hop input all degrade to n=0 (the
  # first hop of a chain) rather than erroring: a prior handoff predating
  # this feature has no Hop line at all, and that must not be treated any
  # differently from a fresh implement/review run with no prior handoff.
  local n=0 line
  if [ -n "$prior" ] && [ -f "$prior" ]; then
    line=$(grep -m1 -E '^Hop: [0-9]+ of [0-9]+$' "$prior" 2>/dev/null || true)
    if [ -n "$line" ]; then
      n=$(printf '%s' "$line" | sed -E 's/^Hop: ([0-9]+) of [0-9]+$/\1/')
    fi
  fi

  local next=$((n + 1))
  [ "$next" -le "$CAP" ] || exit 1
  printf 'Hop: %d of %d\n' "$next" "$CAP"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  "") die "usage: sdlc-hopcount.sh check <phase> [prior-handoff-file]" 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x bin/sdlc-hopcount.sh
```

- [ ] **Step 3: Write `tests/test-hopcount.sh`**

```bash
#!/usr/bin/env bash
# bin/sdlc-hopcount.sh — phase eligibility gate and hop-count/cap
# arithmetic for auto-continue. Exit codes are the whole interface; see
# the script's header comment for the contract.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
SUT="$here/../bin/sdlc-hopcount.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { # want got desc
  [ "$1" = "$2" ] && ok "$3" || bad "$3 (want '$1' got '$2')"
}

run() { # phase [prior] -> sets OUT, RC
  OUT=$("$SUT" check "$@" 2>/dev/null); RC=$?
}

# --- non-eligible phases: exit 2, no stdout -----------------------------
for phase in interview ticket bogus; do
  run "$phase"
  eq "2" "$RC" "phase '$phase' exits 2"
  eq "" "$OUT" "phase '$phase' prints nothing"
done

# --- eligible phase, no prior file: first hop ---------------------------
run implement
eq "0" "$RC" "no prior file exits 0"
eq "Hop: 1 of 10" "$OUT" "no prior file starts at hop 1 of 10"

run review "$tmp/does-not-exist.md"
eq "0" "$RC" "nonexistent prior path exits 0"
eq "Hop: 1 of 10" "$OUT" "nonexistent prior path starts at hop 1 of 10"

# --- prior hop increments, one below the cap -----------------------------
p9="$tmp/prior9.md"
cat > "$p9" <<'EOF'
# SDLC Handoff

## Phase
implement — step 7

## State
- Last commit: abc123 wip
Hop: 9 of 10
EOF
run implement "$p9"
eq "0" "$RC" "hop 9 of 10 exits 0"
eq "Hop: 10 of 10" "$OUT" "hop 9 of 10 advances to 10 of 10"

# --- cap reached: exit 1, no stdout --------------------------------------
p10="$tmp/prior10.md"
cat > "$p10" <<'EOF'
## State
Hop: 10 of 10
EOF
run implement "$p10"
eq "1" "$RC" "hop 10 of 10 (cap) exits 1"
eq "" "$OUT" "hop 10 of 10 (cap) prints nothing"

# --- missing Hop line in an otherwise-valid prior file: treated as n=0 ---
pmiss="$tmp/nohop.md"
cat > "$pmiss" <<'EOF'
## State
- Last commit: abc123 wip
- Stash: none
EOF
run implement "$pmiss"
eq "0" "$RC" "missing Hop line exits 0"
eq "Hop: 1 of 10" "$OUT" "missing Hop line treated as n=0"

# --- malformed Hop line: treated as n=0 ----------------------------------
pbad="$tmp/badhop.md"
cat > "$pbad" <<'EOF'
Hop: banana of 10
EOF
run implement "$pbad"
eq "0" "$RC" "malformed Hop line exits 0"
eq "Hop: 1 of 10" "$OUT" "malformed Hop line treated as n=0"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 4: Make the test executable and run it**

```bash
chmod +x tests/test-hopcount.sh
bash tests/test-hopcount.sh
```

Expected: every `ok:` line, `passed=14 failed=0` (3 phases × 2 assertions + 4 scenarios × 2 assertions = 14), exit status 0.

- [ ] **Step 5: Run the full existing suite to confirm no regression**

```bash
for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t" || echo "FAILED: $t"; done
```

Expected: no `FAILED:` lines.

- [ ] **Step 6: Commit**

```bash
git add bin/sdlc-hopcount.sh tests/test-hopcount.sh
git commit -m "feat: add sdlc-hopcount.sh for deterministic auto-continue hop/cap tracking"
```

---

### Task 2: `skills/handoff/SKILL.md`, `skills/resume/SKILL.md`, `README.md`

**Depends on:** Task 1 (`sdlc-hopcount.sh` must exist and be tested before the skill wording calls it).

**Files:**
- Modify: `skills/handoff/SKILL.md` (step 3 template, step 4 checklist)
- Modify: `skills/resume/SKILL.md` (step 1 disambiguation rule)
- Modify: `README.md` (tripwire bullet under "Why", Tests section)

**Interfaces:**
- Consumes: `sdlc-hopcount.sh check <phase> [prior-handoff-file]` from Task 1 (bare name, on `PATH`).
- Produces: nothing further consumed by other tasks — this is the last task.

**Amendment (post-writing-plans, pre-execution, ruled by the user
mid-session):** the original plan only deleted a superseded prior handoff
file on the *automatic* auto-continue path, and left manual `--continue`
chains free to accumulate multiple `.handoff-*.md` files — exactly the
ambiguity `sdlc:resume`'s "several found → ask a human" step exists to
catch. That ask is fine for an interactive session but breaks a
non-interactive dispatched subagent (the `--continue` supervisor rule's
subagent), which cannot answer it. The user explicitly ruled: extend the
supersession-delete to manual `--continue` too, AND make `sdlc:resume`
default to the newest file without asking whenever it is invoked as part
of a `--continue` dispatch (belt-and-suspenders for any stray files from
before this feature, or from a chain where deletion did not happen for
some other reason). Steps 2 and 4 below are rewritten accordingly; this
does not touch the Hop-cap arithmetic in Task 1 at all.

- [ ] **Step 1: Add the `Hop:` field to the handoff file template**

In `skills/handoff/SKILL.md`, inside the checklist item 3 code fence, the `## State` block currently reads:

```markdown
   ## State
   - Last commit: <hash> <subject>
   - Stash: <name or "none">
   - Labels set: <e.g. sdlc:in-progress on <ref>>
```

Change it to:

```markdown
   ## State
   - Last commit: <hash> <subject>
   - Stash: <name or "none">
   - Labels set: <e.g. sdlc:in-progress on <ref>>
   Hop: <n> of <cap>
```

   The `Hop:` line is written WITHOUT a leading `- ` bullet, unlike its
   neighbors — it must be `sdlc-hopcount.sh`'s exact stdout line
   (`Hop: <n> of <cap>`) verbatim, byte-for-byte, because the script's own
   parser on the next hop looks for a line beginning literally `Hop: `
   (see Task 1's `grep -m1 -E '^Hop: [0-9]+ of [0-9]+$'`). Only present
   when step 4's auto-continue check fired for this hop (see step 4
   below); omit the line entirely on a manually-triggered or first-ever
   handoff.

- [ ] **Step 2: Rewrite checklist step 4 with the auto-continue decision point**

In `skills/handoff/SKILL.md`, the current step 4 reads:

```markdown
4. **Choose the continuation path:**
   - **Default:** end the turn. Tell your human partner: "Handoff written
     to `<file>`. Start a fresh session in the main repo directory
     (`<main_root>`) — it will pick the handoff up automatically." (The
     handoff-pickup SessionStart hook injects it.)
   - **`--continue` (only if invoked with it):** dispatch ONE
     general-purpose subagent with the prompt: "Read `<file>`
     and continue the work per the sdlc:resume skill." Then follow the
     supervisor rule below.
```

Replace it with:

```markdown
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
```

- [ ] **Step 3: Add the compaction guidance**

In `skills/handoff/SKILL.md`, immediately after the "## Supervisor rule (--continue only)" section and before "## Red flags", insert a new section:

```markdown
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
```

- [ ] **Step 4: Make `sdlc:resume` default to the newest handoff, without
  asking, when invoked from a `--continue` dispatch**

First, confirm what still needs no change: `sdlc:resume` already reads
the entire handoff file, so any `Hop:` line in `## State` is already
visible to it as part of "read it fully" (checklist step 2) — it needs no
special-cased extraction because it never acts on the value itself (only
the *next* `sdlc:handoff` invocation does, via `sdlc-hopcount.sh`, from
the file that is still on disk). Step 6's archive timing is unaffected:
`sdlc:handoff`'s file-supersession delete (Task 2 step 2 above) is a
*different* code path — the current `sdlc:handoff` invocation deleting
the file it was itself resumed from, not `sdlc:resume` archiving a file
whose work it just finished. These two deletions never collide because
they are triggered by different, non-overlapping conditions (a new
tripwire firing vs. the phase's own done condition being met).

What DOES need to change, per the user's mid-session ruling: the
supersession delete above should make multiple live handoff files rare,
but not impossible — a pre-existing unrelated file (like this repo's own
`.handoff-2026-09-15-...md`), or a chain where deletion failed partway,
can still leave more than one on disk. When `sdlc:resume` is invoked as
part of a `--continue` dispatch (the dispatching prompt reads "Read
`<file>` and continue the work per the sdlc:resume skill" — a directive
to continue specific, already-identified work, not a person's open-ended
"resume my work" ask), there is no synchronous human able to answer an
`AskUserQuestion` disambiguation prompt; asking would stall the subagent
indefinitely.

In `skills/resume/SKILL.md` checklist step 1, the current text reads:

```markdown
   One file → use it. Several → list them with mtimes and ask which to
   resume (newest is the default). None → tell the user there is nothing to
   resume and stop.
```

Change it to:

```markdown
   One file → use it. Several, and this is a `--continue` dispatch (the
   invoking prompt names a specific file to continue, not an open-ended
   human request to resume) → skip the ask, use the newest by mtime
   automatically, and say which file was picked in the final summary so
   the human can verify after the fact — a dispatched subagent has no
   synchronous human to answer a disambiguation question. Several,
   otherwise → list them with mtimes and ask which to resume (newest is
   the default). None → tell the user there is nothing to resume and
   stop.
```

- [ ] **Step 5: Update `README.md`'s tripwire bullet**

In `README.md`, under "## Why", the current bullet reads:

```markdown
- **Running low on context is a first-class event.** At ~200k tokens a
  tripwire nudges a handoff; the session commits its WIP, writes a
  handoff file, and a fresh session resumes exactly where it left off.
```

Change it to:

```markdown
- **Running low on context is a first-class event.** At ~200k tokens a
  tripwire nudges a handoff; the session commits its WIP, writes a
  handoff file, and a fresh session resumes exactly where it left off.
  During `implement`/`review` this repeats automatically, up to a fixed
  hop cap of 10, so the mechanical execution-heavy phases don't need a
  human to notice and restart every tripwire; `interview`/`ticket` always
  stop and wait for a human, since those phases involve scope and
  requirements judgment.
```

- [ ] **Step 6: Update `README.md`'s Tests section**

The current Tests section reads:

```markdown
## Tests

    for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t"; done

The tests cover the hooks (context tripwire thresholds, handoff pickup,
lint-before-push detection), the backend resolver (`bin/sdlc-backend.sh`),
validate every skill's frontmatter plus the ticket-backend invariants
described under [Ticket backends](#ticket-backends), and content-check the
load-bearing claims in individual skill bodies.
```

Change the prose paragraph (command block unchanged — the existing glob
already picks up the new test file) to:

```markdown
The tests cover the hooks (context tripwire thresholds, handoff pickup,
lint-before-push detection), the backend resolver (`bin/sdlc-backend.sh`),
the auto-continue hop-count/cap gate (`bin/sdlc-hopcount.sh`), validate
every skill's frontmatter plus the ticket-backend invariants described
under [Ticket backends](#ticket-backends), and content-check the
load-bearing claims in individual skill bodies.
```

- [ ] **Step 7: Run the full suite**

```bash
for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t" || echo "FAILED: $t"; done
```

Expected: no `FAILED:` lines (frontmatter for `handoff`/`resume` is
unchanged, so `validate-skills.sh` still passes).

- [ ] **Step 8: Commit**

```bash
git add skills/handoff/SKILL.md skills/resume/SKILL.md README.md
git commit -m "docs: wire phase-aware auto-continue and hop cap into sdlc:handoff/resume"
```

---

## Post-plan (not part of either task — sdlc:implement steps 8-12)

Once both tasks are committed: verify the full suite once more, self-
review the branch against issue #34's acceptance criteria line-by-line,
lint, push, and open a PR titled to reference `Closes #34` / `Epic: #33`.
Remove `sdlc:in-progress` and add `sdlc:in-review` on issue #34, comment
the PR URL on it, and stop — never merge.
