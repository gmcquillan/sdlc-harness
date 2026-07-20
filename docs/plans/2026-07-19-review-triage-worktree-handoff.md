# Review triage + worktree-aware handoff/cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `sdlc:review` triage findings into fix-now/ticket/redo tiers with every fix in a sub-agent, and make handoff/resume/cleanup worktree-aware so handoff files land where fresh sessions actually find them.

**Architecture:** Five of the six touched files are skill markdown (model instructions) or shell. The one true code change is `hooks/handoff-pickup.sh` (worktree-scanning). The handoff skill embeds two shell snippets — main-root resolution and an idempotent `info/exclude` append — which get real bash tests. Skill-prose edits are gated by `tests/validate-skills.sh` (frontmatter) plus grep-based content checks with expected output.

**Tech Stack:** Bash, `git worktree`, `gh` CLI, POSIX shell test scripts (no framework — each `tests/test-*.sh` is run directly and prints `passed=N failed=M`).

## Global Constraints

- Skill frontmatter is inviolable: `name:` must equal the directory name, and `description:` must begin with `Use when`. `tests/validate-skills.sh` enforces this — every skill task must keep it green. (verbatim from repo convention)
- The human integration gate is absolute: no skill merges, pushes to `main`/`master`, or auto-merges a PR. (spec: "No merge/push automation")
- Skills operate on the LOCAL workspace only; never touch remotes except the explicit `gh` calls already present. (spec Part 3)
- Handoff files are deleted only after an explicit confirmation gate; uncommitted work is surfaced, never removed. (spec Part 3 "Safety invariants unchanged")
- Main worktree is resolved deterministically as the first `worktree ` entry of `git worktree list --porcelain`. Use this exact command everywhere a "main root" is needed. (spec Part 2)

---

## File Structure

- `skills/review/SKILL.md` — replace step 5 with triage → gate → act; add tier definitions + Tier-B issue format; update red flags. (Part 1)
- `hooks/handoff-pickup.sh` — scan main root + every linked worktree. (Part 2)
- `tests/test-handoff-pickup.sh` — extend with a worktree case. (Part 2)
- `tests/test-handoff-worktree.sh` — NEW: unit-test the two shell snippets the handoff skill embeds (main-root resolution; idempotent `info/exclude` append). (Part 2)
- `skills/handoff/SKILL.md` — main-root write location, `info/exclude` ignore rule, `Worktree:` ref line, continuation wording. (Part 2)
- `skills/resume/SKILL.md` — multi-worktree scan + worktree re-entry. (Part 2)
- `skills/cleanup/SKILL.md` — standing-in-worktree detection, stray-handoff category, handoff sweep on worktree removal. (Part 3)

Task order: Part 1 first (fully independent), then the executable Part 2 hook + snippets (TDD), then the handoff/resume/cleanup skill prose that consumes them.

---

## Task 1: Review triage (Part 1)

**Files:**
- Modify: `skills/review/SKILL.md` (replace step 5 §46-50; extend red flags §52-58)
- Test: `tests/validate-skills.sh` (must stay green) + inline grep checks

**Interfaces:**
- Consumes: nothing from other tasks — independent.
- Produces: the `## Depends on` / `Epic: #<n>` issue conventions that `sdlc:next` and `sdlc:implement` already parse (no new interface; it reuses theirs).

- [ ] **Step 1: Write the failing content check**

Add these assertions to your scratch and run them now (they must FAIL before the edit):

```bash
cd /home/gmcquillan/src/sdlc-harness
grep -q 'Tier A' skills/review/SKILL.md && echo "A" || echo "no-A"
grep -q 'Tier B' skills/review/SKILL.md && echo "B" || echo "no-B"
grep -q 'Tier C' skills/review/SKILL.md && echo "C" || echo "no-C"
grep -qi 'triage' skills/review/SKILL.md && echo "triage" || echo "no-triage"
```
Expected before edit: `no-A`, `no-B`, `no-C`, `no-triage`.

- [ ] **Step 2: Replace step 5 with the triage flow**

In `skills/review/SKILL.md`, replace the current step 5 ("Fix mode …", lines 46-50) with:

```markdown
5. **Address findings (ONLY if the user asked you to fix, not just
   review).** Triage → gate → act. Every fix runs in a sub-agent; the main
   loop never edits files itself, no matter how small the change.

   **Triage.** Sort each *confirmed* finding (survived the skeptic step)
   into one tier:
   - **Tier A — fix now:** a bounded edit to files already in the diff (or
     immediately adjacent), no new subsystem, no plan of its own needed.
   - **Tier B — ticket it:** needs its own plan, touches a subsystem
     outside the PR's scope, or is really a *new* acceptance criterion
     rather than a defect in the current one.
   - **Tier C — recommend a fresh implementation:** the confirmed findings
     *aggregate* into a re-do — the PR's approach is wrong, or Tier-B-or-
     larger findings are numerous enough that rebuilding beats patching.
     This is a judgment call over the whole findings list, not a per-
     finding rule.

   **Gate.** Present a triage table — each confirmed finding with its tier
   and the action it implies — and WAIT for an explicit go-ahead. Issue
   creation is outward-facing; gate it like `sdlc:ticket`'s dry-run. Create
   nothing and edit nothing before the yes.

   **Act** (only what was approved):
   - **Tier A:** check out the branch (`gh pr checkout <PR#>`), then dispatch
     ONE fresh sub-agent per fix (or a small batched set) running
     `superpowers:receiving-code-review` + `superpowers:test-driven-development`.
     The main loop supervises only. When fixes land, re-run this checklist
     from step 2.
   - **Tier B:** resolve the epic from the reviewed issue's `Epic: #<n>`
     line, then create a child issue:

     ```bash
     gh issue create --label "sdlc:task" \
       --title "<short finding title>" \
       --body "Epic: #<epic>

     ## Depends on
     #<current-issue>   # include only if the fix must land after this PR

     ## Context
     Found in review of #<PR#> (<file:line>). <failure scenario>.

     ## Acceptance criteria
     - [ ] <criterion the fix must meet>
     ## Suggested direction
     <one or two lines>"
     ```
   - **Tier C:** `gh pr review <PR#> --request-changes` with the summary,
     create a Tier-B-style `sdlc:task` for the redo, and recommend
     `/sdlc:implement <issue#>` in a fresh session. Do NOT patch the branch.

   Report what was fixed, the URLs of any tickets created, and any redo
   recommendation.
```

- [ ] **Step 3: Extend the red flags**

Append to the `## Red flags` list in `skills/review/SKILL.md`:

```markdown
- Editing files from the main loop to "just fix it quickly" → every fix
  runs in a sub-agent; the main loop is supervisor only.
- Creating tickets or pushing fixes before the triage gate → the go-ahead
  is required, exactly like sdlc:ticket's dry-run.
- Patching a branch whose approach is wrong (Tier C) instead of
  recommending a fresh sdlc:implement → you are polishing a rewrite.
```

- [ ] **Step 4: Verify content checks pass and frontmatter stays valid**

Run:
```bash
cd /home/gmcquillan/src/sdlc-harness
for t in 'Tier A' 'Tier B' 'Tier C' 'Triage' 'sub-agent' 'Epic: #'; do
  grep -q "$t" skills/review/SKILL.md && echo "ok: $t" || echo "MISSING: $t"
done
bash tests/validate-skills.sh
```
Expected: every `ok:` present, no `MISSING:`, and `validate-skills.sh` ends `passed=8 failed=0`.

- [ ] **Step 5: Commit**

```bash
git add skills/review/SKILL.md
git commit -m "feat(review): triage findings into fix/ticket/redo tiers, all fixes in sub-agents"
```

---

## Task 2: Pickup hook scans all worktrees (Part 2)

**Files:**
- Modify: `hooks/handoff-pickup.sh`
- Test: `tests/test-handoff-pickup.sh` (extend)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing consumed by other tasks — but Task 3's handoff files must be findable by this hook (verified here via a worktree fixture).

- [ ] **Step 1: Write the failing test**

Append to `tests/test-handoff-pickup.sh`, before its final `passed=`/exit
lines (add a `git config user.email/name` in the fixture so `worktree add`
works in CI):

```bash
# --- worktree scanning ---
wtrepo="$tmp/wtrepo"; mkdir -p "$wtrepo"; git -C "$wtrepo" init -q
git -C "$wtrepo" config user.email t@t; git -C "$wtrepo" config user.name t
git -C "$wtrepo" commit -q --allow-empty -m init
git -C "$wtrepo" worktree add -q "$tmp/wt-a" -b feat-a
touch "$tmp/wt-a/.handoff-2026-07-19-cccc.md"
# launched from the MAIN repo, the hook must still find the worktree's file:
hook "$wtrepo"
contains "finds handoff in linked worktree" ".handoff-2026-07-19-cccc.md"
# launched from INSIDE the worktree, it must still fire:
hook "$tmp/wt-a"
contains "fires from inside worktree"       ".handoff-2026-07-19-cccc.md"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/gmcquillan/src/sdlc-harness && bash tests/test-handoff-pickup.sh`
Expected: FAIL on "finds handoff in linked worktree" (current hook only scans the one root).

- [ ] **Step 3: Rewrite the hook's scan to cover all worktrees**

Replace the body of `hooks/handoff-pickup.sh` from the `root=` line through
the `files=` line with a scan over every worktree path:

```bash
cd "$cwd" 2>/dev/null || exit 0
# Enumerate every worktree (main tree first) and scan each root, so the
# handoff is found no matter where it was written or where claude launched.
roots=$(git worktree list --porcelain 2>/dev/null \
          | awk '/^worktree /{print $2}')
[ -n "$roots" ] || roots=$(git rev-parse --show-toplevel 2>/dev/null) || roots="$cwd"
files=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  f=$(find "$r" -maxdepth 1 -name '.handoff-*.md' 2>/dev/null)
  [ -n "$f" ] && files="$files$f"$'\n'
done <<EOF
$roots
EOF
files=$(printf '%s' "$files" | grep -v '^$' | sort -u)
```

Keep the existing `[ -n "$files" ] || exit 0` guard and the reporting block
below it unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/gmcquillan/src/sdlc-harness && bash tests/test-handoff-pickup.sh`
Expected: PASS on all cases, ending `passed=<N> failed=0`.

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-pickup.sh tests/test-handoff-pickup.sh
git commit -m "fix(handoff-pickup): scan all worktrees so handoffs are found regardless of launch dir"
```

---

## Task 3: Handoff write-side mechanics + skill (Part 2)

**Files:**
- Create: `tests/test-handoff-worktree.sh`
- Modify: `skills/handoff/SKILL.md`

**Interfaces:**
- Consumes: the main-root resolution command (Global Constraints).
- Produces: the `## Refs` `Worktree:` line format — `Worktree: <absolute path>` for a worktree, `Worktree: main` for the main tree — which Task 4 (resume) reads to decide re-entry.

- [ ] **Step 1: Write the failing test for both snippets**

Create `tests/test-handoff-worktree.sh`:

```bash
#!/usr/bin/env bash
# The two shell snippets the handoff skill embeds:
#  (1) resolve the MAIN worktree root from anywhere (incl. inside a worktree)
#  (2) idempotently add .handoff-*.md to the shared info/exclude
set -u
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

repo="$tmp/repo"; mkdir -p "$repo"; git -C "$repo" init -q
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" worktree add -q "$tmp/wt" -b feat >/dev/null 2>&1

# (1) main-root resolution, evaluated from INSIDE the worktree
main_root=$(cd "$tmp/wt" && git worktree list --porcelain \
              | awk '/^worktree /{print $2; exit}')
[ "$main_root" = "$repo" ] \
  && ok "main-root resolves to main tree from inside a worktree" \
  || bad "main-root wrong: got '$main_root' want '$repo'"

# (2) idempotent info/exclude append, run TWICE
add_exclude() {
  local excl; excl="$(git -C "$1" rev-parse --path-format=absolute \
    --git-common-dir)/info/exclude"
  grep -qxF '.handoff-*.md' "$excl" 2>/dev/null || echo '.handoff-*.md' >> "$excl"
}
add_exclude "$tmp/wt"; add_exclude "$tmp/wt"
excl="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
n=$(grep -cxF '.handoff-*.md' "$excl")
[ "$n" = "1" ] && ok "info/exclude has exactly one rule after two calls" \
                || bad "info/exclude rule count = $n (want 1)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

Make it executable: `chmod +x tests/test-handoff-worktree.sh`.

- [ ] **Step 2: Run test to verify it passes**

Run: `cd /home/gmcquillan/src/sdlc-harness && bash tests/test-handoff-worktree.sh`
Expected: PASS — `passed=2 failed=0`. (These snippets are self-contained git
commands; the test proves the exact text the skill will embed is correct
before we embed it.)

- [ ] **Step 3: Edit the handoff skill — ignore rule (step 2)**

In `skills/handoff/SKILL.md`, replace step 2 ("Ensure the ignore rule …")
with:

```markdown
2. **Ensure the ignore rule (once, shared across all worktrees).** Add
   `.handoff-*.md` to the common git dir's exclude file so it is ignored in
   the main tree and every worktree without a commit:

   ```bash
   excl="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
   grep -qxF '.handoff-*.md' "$excl" 2>/dev/null || echo '.handoff-*.md' >> "$excl"
   ```
```

- [ ] **Step 4: Edit the handoff skill — write location (step 3)**

In `skills/handoff/SKILL.md` step 3, replace the "at the repo root" filename
block with main-root resolution:

```markdown
3. **Write the handoff file at the MAIN worktree root** (never the current
   worktree — a fresh session launched in the main repo must find it):

   ```bash
   main_root=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
   f="$main_root/.handoff-$(date +%Y-%m-%d)-$(uuidgen).md"
   ```
```

- [ ] **Step 5: Edit the handoff skill — add the Worktree ref line**

In the `## Refs` block of the content template, add a `Worktree:` line
directly under `Branch:`:

```markdown
   - Branch: sdlc/<issue#>-<slug>
   - Worktree: <absolute worktree path, or "main" if written from the main tree>
```

- [ ] **Step 6: Edit the handoff skill — continuation wording**

In step 4's Default bullet, change "Start a fresh session in this directory"
to "Start a fresh session in the main repo directory (`<main_root>`)" so the
user launches where the file now lives.

- [ ] **Step 7: Verify content + frontmatter**

Run:
```bash
cd /home/gmcquillan/src/sdlc-harness
for t in 'main_root=' 'info/exclude' 'Worktree:' 'MAIN worktree root'; do
  grep -q "$t" skills/handoff/SKILL.md && echo "ok: $t" || echo "MISSING: $t"
done
bash tests/validate-skills.sh | tail -1
```
Expected: all `ok:`, and `passed=8 failed=0`.

- [ ] **Step 8: Commit**

```bash
git add tests/test-handoff-worktree.sh skills/handoff/SKILL.md
git commit -m "fix(handoff): write to main worktree root, ignore via shared info/exclude, record Worktree ref"
```

---

## Task 4: Resume reads worktrees + re-enters them (Part 2)

**Files:**
- Modify: `skills/resume/SKILL.md`

**Interfaces:**
- Consumes: the `Worktree:` ref line produced by Task 3.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Failing content check**

```bash
cd /home/gmcquillan/src/sdlc-harness
grep -q 'worktree list' skills/resume/SKILL.md && echo has || echo missing
```
Expected before edit: `missing`.

- [ ] **Step 2: Edit step 1 — scan all worktrees**

In `skills/resume/SKILL.md`, replace step 1's find command clause so it
enumerates every worktree root:

```markdown
1. **Find handoff files across every worktree** (the writer puts them at the
   main root, but scan all trees so none is missed):

   ```bash
   git worktree list --porcelain | awk '/^worktree /{print $2}' \
     | while read -r r; do ls "$r"/.handoff-*.md 2>/dev/null; done
   ```

   One file → use it. Several → list them with mtimes and ask which to
   resume (newest is the default). None → tell the user there is nothing to
   resume and stop.
```

- [ ] **Step 3: Add a worktree re-entry step**

Insert a new step between the current step 3 (verify state) and step 4
(archive), and renumber the rest:

```markdown
4. **Re-enter the recorded worktree.** If `## Refs` names a `Worktree`
   other than `main`:
   - It still exists (`git worktree list` contains the path) → operate from
     there (the phase skill's work happens inside it).
   - The path is gone but the branch exists → offer to recreate it:
     `git worktree add <path> <branch>`, then operate from there.
   - `Worktree: main` or absent → operate in the main tree.
```

- [ ] **Step 4: Verify content + frontmatter**

Run:
```bash
cd /home/gmcquillan/src/sdlc-harness
for t in 'worktree list' 'Re-enter the recorded worktree' 'git worktree add'; do
  grep -q "$t" skills/resume/SKILL.md && echo "ok: $t" || echo "MISSING: $t"
done
bash tests/validate-skills.sh | tail -1
```
Expected: all `ok:`, and `passed=8 failed=0`.

- [ ] **Step 5: Commit**

```bash
git add skills/resume/SKILL.md
git commit -m "feat(resume): scan all worktrees for handoffs and re-enter the recorded worktree"
```

---

## Task 5: Cleanup worktree awareness (Part 3)

**Files:**
- Modify: `skills/cleanup/SKILL.md`

**Interfaces:**
- Consumes: the main-root resolution command (Global Constraints); the
  `Worktree:` ref line (to sweep the right handoff when removing a worktree).
- Produces: nothing consumed downstream.

- [ ] **Step 1: Failing content check**

```bash
cd /home/gmcquillan/src/sdlc-harness
grep -qi 'standing in' skills/cleanup/SKILL.md && echo has || echo missing
grep -q '.handoff-' skills/cleanup/SKILL.md && echo has2 || echo missing2
```
Expected before edit: `missing`, `missing2`.

- [ ] **Step 2: Add standing-in-a-worktree detection to the Scan step**

In `skills/cleanup/SKILL.md`, add a bullet under step 2 ("Scan"):

```markdown
   - **Standing-in-a-worktree check:** compare `git rev-parse
     --show-toplevel` against the main root (`git worktree list --porcelain
     | awk '/^worktree /{print $2; exit}'`). If they differ, this session is
     inside a linked worktree — git cannot remove the tree you stand in.
     Report it and tell the user to re-run `sdlc:cleanup` from the main repo
     (`<main-root>`) to reclaim that worktree. Keep reporting the other
     categories normally.
   - **Stray handoffs:** scan every worktree root
     (`git worktree list --porcelain | awk '/^worktree /{print $2}'`) for
     `.handoff-*.md`. Report each under its own heading, flagged
     "un-resumed handoff — remove only if that work is done or abandoned."
```

- [ ] **Step 3: Add the stray-handoff category to Report + Execute**

In step 3 ("Report"), add "Stray handoffs" to the grouped categories. In
step 5 ("Execute"), add a bullet:

```markdown
   - **Stray handoffs:** delete confirmed `.handoff-*.md` files. When a
     worktree is removed, also delete any handoff that lived in it or that
     names its path in `## Refs`, so the pointer never outlives its target.
```

- [ ] **Step 4: Add a red flag**

Append to `## Red flags`:

```markdown
- Silently skipping the worktree you are standing in → say you cannot
  remove it and where to re-run from; do not pretend it is clean.
```

- [ ] **Step 5: Verify content + frontmatter**

Run:
```bash
cd /home/gmcquillan/src/sdlc-harness
for t in 'Standing-in-a-worktree' 'Stray handoffs' 'un-resumed handoff'; do
  grep -q "$t" skills/cleanup/SKILL.md && echo "ok: $t" || echo "MISSING: $t"
done
bash tests/validate-skills.sh | tail -1
```
Expected: all `ok:`, and `passed=8 failed=0`.

- [ ] **Step 6: Full test sweep + commit**

Run the whole suite to confirm nothing regressed:
```bash
cd /home/gmcquillan/src/sdlc-harness
for t in tests/test-*.sh tests/validate-skills.sh; do echo "== $t =="; bash "$t" | tail -1; done
```
Expected: every script ends `failed=0` (or `passed=N failed=0`).

```bash
git add skills/cleanup/SKILL.md
git commit -m "feat(cleanup): detect standing-in-worktree and sweep stray handoff files"
```

---

## Self-Review

**Spec coverage:**
- Part 1 tiers A/B/C + all-fixes-in-sub-agents + approval gate → Task 1. ✓
- Part 1 Tier-B issue format matching sdlc:next/implement → Task 1 Step 2. ✓
- Part 2 handoff→main-root write → Task 3 Step 4. ✓
- Part 2 info/exclude ignore rule → Task 3 Steps 1-3. ✓
- Part 2 Worktree ref line → Task 3 Step 5. ✓
- Part 2 pickup hook scans worktrees → Task 2. ✓
- Part 2 resume multi-worktree scan + re-entry → Task 4. ✓
- Part 3 standing-in-worktree detection → Task 5 Step 2. ✓
- Part 3 stray-handoff category → Task 5 Steps 2-3. ✓
- Part 3 handoff sweep on worktree removal → Task 5 Step 3. ✓
- Spec test bullets: "pickup finds handoff regardless of launch dir" → Task 2 test; "handoff lands in main root" + "info/exclude gets the rule" → Task 3 `test-handoff-worktree.sh`; "cleanup reports stray-handoff category" → Task 5 grep check (skill prose, not script — verified by content check, the only mechanism this repo has for skill bodies). ✓

**Placeholder scan:** No unfinished-work markers; every code/edit step shows literal content and exact commands with expected output. ✓

**Type consistency:** Main-root command is identical everywhere (`git worktree list --porcelain | awk '/^worktree /{print $2; exit}'` for single, without `exit` for the loop). `Worktree:` ref format defined in Task 3, consumed verbatim in Tasks 4 and 5. `info/exclude` snippet identical in the test (Task 3 Step 1) and the skill (Task 3 Step 3). ✓
