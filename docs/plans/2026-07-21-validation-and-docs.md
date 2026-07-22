# Skill Validation & Backend Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `tests/validate-skills.sh` fail loudly if the ticket-backend
branch ever rots out of the pipeline skills, and state the backend story in
the README and plugin metadata.

**Architecture:** Three independent surfaces. (1) `tests/validate-skills.sh`
grows three assertion blocks appended after the existing frontmatter loop,
reusing its `ok`/`bad`/`pass`/`fail` harness verbatim — no new files, no
refactor of what's there. (2) `README.md` gains a "Ticket backends" section.
(3) `.claude-plugin/plugin.json` and its `marketplace.json` mirror go to
`0.5.0`. The validator is itself a test, so each task's TDD cycle is
**inverted**: write the assertion, confirm it passes on the clean tree, then
*mutate a throwaway copy of the tree to break the invariant* and confirm the
assertion fails. An assertion never observed failing is not a test.

**Tech Stack:** POSIX-ish bash, `awk`, `grep -E`, `jq` (read-only checks).

## Global Constraints

Copied verbatim from `docs/2026-07-21-jira-ticket-backend-design.md` §T8 and
the constraints it inherits:

- **The GitHub path costs one bash call.** No wrapper, no indirection, no
  `references/backend-github.md`. Every existing `gh` command in every
  pipeline skill stays inline and byte-identical.
- **No skill logic changes in this task.** `skills/**/SKILL.md` is read-only
  here; if an assertion fails, fix the assertion or report the skill defect —
  do not edit the skill to satisfy the test.
- **BSD/macOS portable.** The suite must run on stock macOS: no GNU-only
  flags, no `\b` in grep (use `grep -oE '(^|[^[:alnum:]_-])…'`), no
  `timeout`, no `grep -P`, no `sed -i` without a backup arg.
- **Scope is exactly** `tests/validate-skills.sh`, `README.md`,
  `.claude-plugin/plugin.json` — plus `.claude-plugin/marketplace.json`,
  which mirrors the plugin version and would otherwise drift (see Task 4).
- The full suite must pass: `for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t"; done`

**Baseline at plan time:** 6 suites, 145 assertions, 0 failures.
Inline `gh` counts: ticket 7, next 4, implement 7, review 8, resume 1.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `tests/validate-skills.sh` | All static skill/repo invariants | Modify — append 3 blocks |
| `README.md` | User-facing docs | Modify — new section + Requires bullet |
| `.claude-plugin/plugin.json` | Plugin metadata | Modify — version + keyword |
| `.claude-plugin/marketplace.json` | Marketplace mirror of the above | Modify — version only |

No new files. The validator stays one file because every assertion in it is
the same kind of thing (a static grep over the repo) and it is invoked as a
single unit by the README's test loop.

---

### Task 1: Assert step 0 resolves the backend

**Files:**
- Modify: `tests/validate-skills.sh` (append after line 25, the `done` of the frontmatter loop, before the `echo "passed=..."` summary)
- Test: the script is the test; mutation-verified in Step 3

**Interfaces:**
- Consumes: `ok()`, `bad()`, `$root`, `$pass`, `$fail` — all already defined at the top of the file.
- Produces: shell variable `pipeline="ticket next implement review"`, reused by Task 2's `gh`-floor block.

- [ ] **Step 1: Write the assertion**

Insert immediately after the `done` that closes the existing `for name in $expected` loop, and **before** the `echo "passed=$pass failed=$fail"` line:

```bash

# --- step 0 resolves the ticket backend (spec T3, T8) -------------------
# The GitHub path must cost exactly one bash call, so each ticket-touching
# skill resolves the backend in step 0 and branches on the action. Look
# only inside the step-0 block: a mention elsewhere in the file does not
# satisfy this.
pipeline="ticket next implement review"
for name in $pipeline; do
  f="$root/skills/$name/SKILL.md"
  if [ ! -f "$f" ]; then bad "$name: SKILL.md missing (step 0)"; continue; fi
  step0=$(awk '/^0\. /{n=1} /^1\. /{n=0} n' "$f")
  if [ -z "$step0" ]; then
    bad "$name: no step 0 block"
  elif printf '%s\n' "$step0" | grep -q 'sdlc-backend\.sh resolve'; then
    ok "$name: step 0 resolves the backend"
  else
    bad "$name: step 0 does not run sdlc-backend.sh resolve"
  fi
done
```

- [ ] **Step 2: Run it — expect PASS on the clean tree**

Run: `bash tests/validate-skills.sh`
Expected: exit 0, `passed=12 failed=0`, and these four new lines:

```
ok: ticket: step 0 resolves the backend
ok: next: step 0 resolves the backend
ok: implement: step 0 resolves the backend
ok: review: step 0 resolves the backend
```

- [ ] **Step 3: Prove the assertion has teeth (mutation check)**

A passing assertion on a clean tree proves nothing. Break the invariant in a
throwaway copy and confirm the failure. **Never mutate the real tree.**

```bash
mut=$(mktemp -d)
cp -R skills tests references "$mut"/
# Remove the backend call from next's step 0 only.
awk '/^0\. \*\*Resolve the backend/{skip=3} skip>0{skip--; next} 1' \
  skills/next/SKILL.md > "$mut/skills/next/SKILL.md"
bash "$mut/tests/validate-skills.sh"; echo "exit=$?"
rm -rf "$mut"
```

Expected: `FAIL: next: no step 0 block` (or `... does not run sdlc-backend.sh resolve`), and `exit=1`.
If it prints `ok:` instead, the assertion is inert — fix it before continuing.

- [ ] **Step 4: Commit**

```bash
git add tests/validate-skills.sh
git commit -m "test: assert step 0 resolves the backend in each pipeline skill"
```

---

### Task 2: Assert the references exist and inline `gh` survives

**Files:**
- Modify: `tests/validate-skills.sh` (append after Task 1's block)

**Interfaces:**
- Consumes: `ok()`, `bad()`, `$root` from the file header; `$pipeline` is *not* reused here because the `gh` floors include `resume`, which has no step 0.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Write the reference-existence assertions**

Append after Task 1's block:

```bash

# --- the JIRA adapter references exist, and no GitHub twin --------------
for r in backend-jira backend-bind; do
  if [ -f "$root/references/$r.md" ]; then ok "references/$r.md exists"
  else bad "references/$r.md missing"; fi
done
# Spec T2: the GitHub path stays inline in the skills. A backend-github.md
# would mean the common path had started paying the adapter's cost.
if [ -e "$root/references/backend-github.md" ]; then
  bad "references/backend-github.md exists — the GitHub path must stay inline"
else
  ok "no references/backend-github.md"
fi
```

- [ ] **Step 2: Write the inline-`gh` floor assertions**

Append directly after the block from Step 1:

```bash

# --- inline gh commands survive (spec T3) -------------------------------
# Floors, not exact counts: adding gh calls is fine; losing them means the
# GitHub path grew a wrapper or an indirection. If a removal is deliberate,
# lower the floor in the same commit and say why in the message.
# The bracket class stands in for \b, which is not portable to BSD grep.
gh_floors="ticket:7 next:4 implement:7 review:8 resume:1"
for entry in $gh_floors; do
  name=${entry%%:*}; want=${entry##*:}
  f="$root/skills/$name/SKILL.md"
  if [ ! -f "$f" ]; then bad "$name: SKILL.md missing (gh floor)"; continue; fi
  got=$(grep -oE '(^|[^[:alnum:]_-])gh [a-z]' "$f" | wc -l | tr -d ' ')
  if [ "$got" -ge "$want" ]; then
    ok "$name: $got inline gh commands (floor $want)"
  else
    bad "$name: $got inline gh commands, floor is $want"
  fi
done
```

- [ ] **Step 3: Run it — expect PASS on the clean tree**

Run: `bash tests/validate-skills.sh`
Expected: exit 0, `passed=20 failed=0`, including:

```
ok: references/backend-jira.md exists
ok: references/backend-bind.md exists
ok: no references/backend-github.md
ok: ticket: 7 inline gh commands (floor 7)
ok: next: 4 inline gh commands (floor 4)
ok: implement: 7 inline gh commands (floor 7)
ok: review: 8 inline gh commands (floor 8)
ok: resume: 1 inline gh commands (floor 1)
```

- [ ] **Step 4: Prove all three assertions have teeth (mutation check)**

```bash
mut=$(mktemp -d)
cp -R skills tests references "$mut"/
rm "$mut/references/backend-bind.md"                 # missing reference
: > "$mut/references/backend-github.md"              # forbidden twin
grep -v 'gh issue' skills/review/SKILL.md > "$mut/skills/review/SKILL.md"
bash "$mut/tests/validate-skills.sh"; echo "exit=$?"
rm -rf "$mut"
```

Expected — three distinct failures and `exit=1`:

```
FAIL: references/backend-bind.md missing
FAIL: references/backend-github.md exists — the GitHub path must stay inline
FAIL: review: <n> inline gh commands, floor is 8
```

- [ ] **Step 5: Commit**

```bash
git add tests/validate-skills.sh
git commit -m "test: assert backend references exist and inline gh survives"
```

---

### Task 3: README "Ticket backends" section

**Files:**
- Modify: `README.md` — new section after "The pipeline" (ends at the `/sdlc:cleanup` paragraph, ~line 86) and before "## Skills"; plus one bullet in **Requires** (~line 53-61)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Insert the section**

Insert between the end of "## The pipeline" and the "## Skills" heading:

```markdown
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

`tests/validate-skills.sh` enforces the split: step 0 must call the
resolver, both reference files must exist, no `references/backend-github.md`
may appear, and each skill's inline `gh` command count must not drop.
```

- [ ] **Step 2: Add the Requires bullet**

In the **Requires:** list, after the `uuidgen` bullet, add:

```markdown
- *(optional)* a JIRA MCP server — only if you want tickets in JIRA instead
  of GitHub Issues; see [Ticket backends](#ticket-backends)
```

- [ ] **Step 3: Confirm the Tests command already covers the new assertions**

The new assertions live inside `tests/validate-skills.sh`, which the existing
command already runs:

Run: `grep -n 'validate-skills' README.md`
Expected: the Tests section's `for t in tests/test-*.sh tests/validate-skills.sh` line is present and unchanged.

Then update the sentence under it to describe what is now covered. Replace:

```markdown
The tests cover the hooks (context tripwire thresholds, handoff pickup,
lint-before-push detection) and validate every skill's frontmatter.
```

with:

```markdown
The tests cover the hooks (context tripwire thresholds, handoff pickup,
lint-before-push detection), the backend resolver (`bin/sdlc-backend.sh`),
and validate every skill's frontmatter plus the ticket-backend invariants
described under [Ticket backends](#ticket-backends).
```

- [ ] **Step 4: Verify the suite still passes**

Run: `for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done; echo ok`
Expected: `ok` with no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document the ticket backends and what the GitHub path costs"
```

---

### Task 4: Bump plugin metadata to 0.5.0

**Files:**
- Modify: `.claude-plugin/plugin.json` — `version` (line 4), `keywords` (line 12)
- Modify: `.claude-plugin/marketplace.json` — `plugins[0].version` (line 16)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Why marketplace.json is in scope:** it mirrors the plugin version
(`0.4.0` in both today). §T8's scope line names only `plugin.json`, but
bumping one and not the other publishes a marketplace entry pointing at the
wrong version. Both move together.

- [ ] **Step 1: Bump `plugin.json`**

Change `"version": "0.4.0"` to `"version": "0.5.0"`, and change the keywords line:

```json
  "keywords": ["sdlc", "workflow", "github-issues", "jira", "context-management", "handoff", "hooks"]
```

- [ ] **Step 2: Bump `marketplace.json`**

Change `plugins[0].version` from `"0.4.0"` to `"0.5.0"`. Leave
`metadata.version` (`1.0.0`) alone — that versions the marketplace, not the
plugin.

- [ ] **Step 3: Verify both files are valid JSON and agree**

```bash
jq -e '.version == "0.5.0" and (.keywords | index("jira") != null)' .claude-plugin/plugin.json
jq -e '.plugins[0].version == "0.5.0"' .claude-plugin/marketplace.json
```

Expected: both print `true` and exit 0.

- [ ] **Step 4: Run the full suite**

Run: `for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done; echo done`
Expected: `done` with no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: bump plugin to 0.5.0 with a jira keyword"
```

---

## Acceptance criteria → task map

| §T8 criterion | Task |
|---|---|
| `validate-skills.sh` asserts ticket/next/implement/review run the resolver in step 0 | 1 |
| `validate-skills.sh` asserts both `references/*.md` exist and no skill lost inline `gh` | 2 |
| README "Ticket backends" section: one-bash-call cost, JIRA MCP optional, tests command covers the new test | 3 |
| `plugin.json` at `0.5.0` with a `jira` keyword | 4 |
| The full suite passes | 1–4, final check in 4 |
