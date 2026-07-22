# PR comment fixes: `sdlc:fixes` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new pipeline skill, `sdlc:fixes <PR#>`, that triages a PR's
open review comments (inline, summary, conversation) into accept/refute,
gates on the triage table, lands accepted fixes via the same
worktree → subagent-TDD engine `sdlc:implement` uses, replies to every
thread, and never resolves one.

**Architecture:** One new skill file (model instructions, no executable
code of its own — every command it runs is an existing `gh`/`git`
primitive already used elsewhere in this repo). Two supporting files
change: `tests/validate-skills.sh` (frontmatter + `gh`-floor protection)
and `README.md` (documentation). All three are markdown/shell; there is no
new runtime code, so verification is grep-based content checks plus the
existing `tests/validate-skills.sh` script — the same mechanism every
other skill-prose change in this repo uses (see
`docs/plans/2026-07-19-review-triage-worktree-handoff.md` for precedent).

**Tech Stack:** Bash, `gh` CLI (REST + GraphQL via `gh api graphql`),
`git worktree`. No test framework — `tests/validate-skills.sh` is run
directly and prints `passed=N failed=0`.

## Global Constraints

- Skill frontmatter is inviolable: `name:` must equal the directory name,
  and `description:` must begin with `Use when`. `tests/validate-skills.sh`
  enforces this. (repo convention, verbatim)
- `sdlc:fixes` never resolves a GitHub review thread, on either accept or
  refute — replying is the skill's job, resolving is always left to the
  human reviewer. (spec: intro + step 10 + "Out of scope")
- Nothing is posted, replied to, resolved, or edited before the step 6
  gate's explicit go-ahead. (spec step 6)
- `sdlc:fixes` never creates a new PR and never merges — the human
  integration gate stays absolute. (spec intro + "Out of scope")
- `sdlc:fixes` skips ticket-backend resolution (no step 0): PR comments
  are GitHub-native regardless of which ticket backend is bound, so it is
  deliberately excluded from `validate-skills.sh`'s backend-resolution
  (`pipeline`) check list. (spec: "Why no ticket-backend resolution")
- Step 4 (isolate) must NOT invoke `superpowers:using-git-worktrees` —
  that skill always creates a *new* branch via `-b`, which is wrong when
  the PR's branch already exists on the remote. Reuse the tracking
  worktree if one exists, else `git worktree add` directly. (spec step 4,
  verbatim)
- Raw comment JSON and file contents never land in the main loop — a
  subagent fetches/normalizes comments into a condensed
  `{id, kind, author, location, body, thread_root_id}` list; the main
  loop holds only that table, the gate, and the final report. (spec:
  "Execution flow" intro)

---

## File Structure

- `skills/fixes/SKILL.md` — new skill: frontmatter (`name: fixes`,
  `description:` beginning "Use when"), an 11-step checklist mirroring the
  design doc's execution flow, and a red-flags list.
- `tests/validate-skills.sh` — add `fixes` to the `expected` frontmatter
  list (line 11); add a `fixes:7` entry to `gh_floors` (line 77); leave
  the `pipeline` var (line 32) untouched — `fixes` has no step 0.
- `README.md` — document the new skill: pipeline numbered list, ASCII
  diagram, Skills table, and the Ticket-backends closing paragraph.

Task order: the skill file first (nothing else can be verified without
it), then the test-script floor (which depends on the finished skill's
`gh`-command count), then the docs (independent of both, but naturally
last since it *describes* the finished behavior).

---

## Task 1: Create the `sdlc:fixes` skill

**Files:**
- Create: `skills/fixes/SKILL.md`

**Interfaces:**
- Consumes: nothing from other tasks — this is the first task.
- Produces: the finished skill body that Task 2's `gh`-floor count is
  measured against. Any wording edit to `SKILL.md` after Task 2 lands
  must be followed by re-running Task 2's floor computation.

- [ ] **Step 1: Write the failing check**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
test -f skills/fixes/SKILL.md && echo "exists" || echo "missing"
```
Expected before this task: `missing`.

- [ ] **Step 2: Create the skill file**

Create `skills/fixes/SKILL.md` with this exact content:

```markdown
---
name: fixes
description: Use when an SDLC pull request has open review comments (inline, review-summary, or conversation) that need to be triaged and either fixed or refuted — fetches and normalizes every thread via GraphQL (skipping already-resolved threads) and REST, filters bot noise, gates on a triage table, fixes accepted comments in subagents with TDD, then replies to every thread without ever resolving one. Never creates a PR, never merges. Invoke as sdlc:fixes <PR#>.
---

# SDLC Fixes: PR review comments → accept/refute → land

Reuses `sdlc:implement`'s execution engine (worktree → subagent fixes with
TDD → verify → lint → push), but works from a PR's open comment threads
instead of a ticket's acceptance criteria. It never creates a new PR and
never merges — and it never resolves a GitHub review thread on either
outcome; replying is this skill's job, resolving is always left to the
human reviewer, so a reviewer's concern never silently disappears from
their queue. Create a todo per checklist item.

## Checklist

1. **Preconditions.** `<PR#>` is a required argument — comments are
   PR-scoped, so there is no "pick one for me" fallback. Run `gh auth
   status` (must succeed) and `gh pr view <PR#> --json state` (must be
   `OPEN`, not merged/closed/draft) — stop and report otherwise.
2. **Gather metadata (main loop, small):** `gh pr view <PR#> --json
   number,title,headRefName,baseRefName,url` only — same discipline as
   `sdlc:review` step 1. Do NOT fetch the diff or comments into this
   context.
3. **Fetch + normalize comments in a subagent.** One subagent call
   fetches:
   - Inline review comments via GraphQL, skipping already-resolved
     threads (the REST comments endpoint has no resolution field, so
     without this cross-reference a re-run would resurface feedback a
     human already closed out):

     ```bash
     gh api graphql -f query='
       query($owner:String!,$repo:String!,$pr:Int!) {
         repository(owner:$owner, name:$repo) {
           pullRequest(number:$pr) {
             reviewThreads(first:100) {
               nodes {
                 isResolved
                 comments(first:50) {
                   nodes { databaseId author { login } path line body }
                 }
               }
             }
           }
         }
       }' -f owner=<owner> -f repo=<repo> -F pr=<PR#> \
       --jq '.data.repository.pullRequest.reviewThreads.nodes
             | map(select(.isResolved == false))'
     ```
   - Review summary bodies and general conversation comments via
     `gh pr view <PR#> --json reviews,comments`. A review with a bare
     state and no body carries nothing to act on — skip it.
   - **Bot filtering:** drop every comment/review whose author is
     `*[bot]` before triage — there's no accept/refute semantics for a CI
     status update, and nobody reads a reply posted back to a bot. Count
     the drops; the count is reported in step 11, so filtering stays
     visible, not silent.
   The subagent returns ONLY a condensed list of `{id, kind, author,
   location, body, thread_root_id}` — never the raw API payload.
4. **Isolate.** Check whether a worktree already tracks the PR's
   `headRefName` (`git worktree list --porcelain`) — the common case,
   left over from the `sdlc:implement` run that produced this PR. Found
   → operate there. Not found → create one directly:
   `git worktree add .worktrees/<headRefName> <headRefName>`. Do NOT
   invoke `superpowers:using-git-worktrees` here — that skill's flow
   always creates a *new* branch via `-b`, which is wrong when the PR's
   branch already exists on the remote.
5. **Triage each comment in subagents**, fanned out per
   `fable-harness:fan-out` — one subagent per comment (batch several
   comments landing on the same lines together). Each subagent reads the
   surrounding code itself and returns exactly one of:
   - **Accept** — a real, in-scope defect or reasonable request; include
     a one-line fix plan.
   - **Refute** — the comment's premise doesn't hold against the current
     code, is out of scope, or is a stylistic disagreement not worth
     changing; include the one-line rationale that becomes the reply.
6. **Gate.** Present the triage table (comment id, author, location,
   accept/refute, one-line reasoning/fix-plan) and WAIT for an explicit
   go-ahead — the same human gate as `sdlc:ticket`'s dry-run and
   `sdlc:review`'s Tier A/B/C. Nothing is posted, resolved, or edited
   before the yes. The user may override any individual verdict here.
7. **Act on accepted comments only**, after the gate. One fresh subagent
   per fix (or a small batched set), running
   `superpowers:receiving-code-review` +
   `superpowers:test-driven-development`. The main loop supervises only —
   it never edits files itself, matching `sdlc:review`'s existing rule.
8. **Verify.** `superpowers:verification-before-completion` in a
   subagent; every accepted comment needs evidence its fix actually
   addresses it.
9. **Lint.** Run the project's linter/formatter and fix every finding —
   same gate as `sdlc:implement` step 10.
10. **Reply and push.** Push once, after all accepted fixes land (`git
    push`). Reply to each accepted inline thread as a native threaded
    reply:

    ```bash
    gh api repos/<owner>/<repo>/pulls/<PR#>/comments \
      -F in_reply_to=<id> -f body="<reply text>"
    ```
    Reply to summary/conversation comments via
    `gh pr comment <PR#> --body "<reply text, referencing which
    comment/review it addresses>"` (no native reply mechanism for those).
    Refuted comments get the same reply treatment with the rationale from
    step 5 — no code change, and **no thread resolution, ever**, for
    either outcome.
11. **Report.** Accepted comments (fix + reply link), refuted comments
    (rationale + reply link), the bot-noise count dropped in step 3, and
    the PR URL. Never merge; suggest `/sdlc:review <PR#>` if the changes
    were substantial enough to warrant a fresh look.

## Red flags

- Resolving a GitHub review thread for any reason, on accept or refute →
  that is always the human reviewer's call, never this skill's.
- Posting a reply, pushing, or fixing anything before the step 6 gate →
  the go-ahead is required, exactly like sdlc:ticket's dry-run.
- Invoking `superpowers:using-git-worktrees` in step 4 → it always
  creates a new branch; the PR's branch already exists remotely.
- Fetching resolved threads, or skipping the GraphQL cross-reference
  entirely → every re-run resurfaces feedback a human already closed.
- Editing files from the main loop → every fix runs in a sub-agent, no
  matter how small.
- Silently dropping bot comments without reporting the count → filtering
  must stay visible.
```

- [ ] **Step 3: Verify frontmatter and content**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
head -1 skills/fixes/SKILL.md
awk '/^---$/{n++; next} n==1{print} n>=2{exit}' skills/fixes/SKILL.md
for t in 'reviewThreads' 'isResolved' 'bot' 'Gate' 'Tier A' 'in_reply_to' 'no thread resolution'; do
  grep -qi "$t" skills/fixes/SKILL.md && echo "ok: $t" || echo "MISSING: $t"
done
```
Expected: first line `---`; frontmatter block shows `name: fixes` and a
`description:` line beginning `Use when`; every `$t` in the loop prints
`ok:` (note: "Tier A" appears only via the `sdlc:ticket`'s-dry-run /
`sdlc:review`'s-Tier-A/B/C cross-reference in step 6 — that's expected,
not a copy-paste artifact).

- [ ] **Step 4: Commit**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
git add skills/fixes/SKILL.md
git commit -m "feat(fixes): add sdlc:fixes skill for triaging PR review comments"
```

---

## Task 2: Wire `fixes` into `validate-skills.sh`

**Files:**
- Modify: `tests/validate-skills.sh:11` (expected list)
- Modify: `tests/validate-skills.sh:77` (gh_floors)

**Interfaces:**
- Consumes: the finished `skills/fixes/SKILL.md` from Task 1 (its exact
  `gh`-command count).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Compute the actual gh-command floor**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
awk '/^---$/{n++; next} n>=2' skills/fixes/SKILL.md \
  | grep -oE '(^|[^[:alnum:]_-])gh [a-z]' | wc -l
```
Expected: `7` (measured against Task 1's exact file: `gh auth`, `gh pr`
×2 in steps 1–2, `gh api graphql` in step 3, `gh pr view` in step 3,
`gh api repos...` and `gh pr comment` in step 10). If Task 1's wording
changed since this plan was written, re-run this command and use
whatever it actually prints — do not reuse `7` blindly.

- [ ] **Step 2: Write the failing check**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
bash tests/validate-skills.sh | tail -1
```
Expected before this task: `passed=20 failed=0` (the `fixes` skill exists
on disk but isn't checked yet, so the count is unchanged from before
Task 1).

- [ ] **Step 3: Add `fixes` to the `expected` frontmatter list**

In `tests/validate-skills.sh`, change line 11:

```bash
expected="interview ticket next implement review handoff resume cleanup"
```

to:

```bash
expected="interview ticket next implement review handoff resume cleanup fixes"
```

- [ ] **Step 4: Add the `gh_floors` entry**

In `tests/validate-skills.sh`, change line 77:

```bash
gh_floors="ticket:7 next:4 implement:7 review:7 resume:1"
```

to:

```bash
gh_floors="ticket:7 next:4 implement:7 review:7 resume:1 fixes:7"
```

Do NOT add `fixes` to the `pipeline` variable (line 32) — `fixes` has no
step 0 / no backend resolution, and adding it there would make the
step-0 check fail (correctly) since the skill has no `0.` block.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
bash tests/validate-skills.sh
```
Expected: every line `ok:`, ending `passed=22 failed=0` (20 previous +
1 new frontmatter check for `fixes` + 1 new `gh_floors` check for
`fixes`). No `pipeline`/step-0 line for `fixes` should appear at all.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
git add tests/validate-skills.sh
git commit -m "test(validate-skills): add fixes skill frontmatter + gh-floor checks"
```

---

## Task 3: Document `sdlc:fixes` in README.md

**Files:**
- Modify: `README.md` (pipeline list, ASCII diagram, Skills table, Ticket
  backends closing paragraph)

**Interfaces:**
- Consumes: nothing from other tasks (pure documentation), but describes
  Task 1's finished behavior, so it must land after Task 1.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Write the failing check**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
grep -q 'sdlc:fixes' README.md && echo has || echo missing
```
Expected before this task: `missing`.

- [ ] **Step 2: Add `sdlc:fixes` as pipeline step 6**

In `README.md`, after the existing step 5 (`` `/sdlc:review <PR#>` ``)
and before the "At any point, `/sdlc:handoff`..." paragraph, insert:

```markdown
6. **`/sdlc:fixes <PR#>`** — triages a PR's open review comments (inline,
   summary, and conversation), gates on an accept/refute table, lands
   accepted fixes through the same worktree → subagent TDD engine as
   `implement`, and replies to every thread. **Never resolves a thread,
   never merges.**
```

- [ ] **Step 3: Add `sdlc:fixes` to the ASCII diagram**

Replace the diagram code block:

```
/sdlc:interview ──► spec ──► /sdlc:ticket ──► epic + child issues
                                                    │
                                             /sdlc:next [#]
                                                    │
  human merges ◄── /sdlc:review <PR#> ◄── PR ◄── /sdlc:implement [#]
```

with:

```
/sdlc:interview ──► spec ──► /sdlc:ticket ──► epic + child issues
                                                    │
                                             /sdlc:next [#]
                                                    │
  human merges ◄── /sdlc:review <PR#> ◄── PR ◄── /sdlc:implement [#]
                            ▲              │
                            └─ /sdlc:fixes <PR#> ◄──┘
```

- [ ] **Step 4: Add a Skills table row**

In the `## Skills` table, after the `sdlc:review <PR#>` row, insert:

```markdown
| `sdlc:fixes <PR#>` | Triage PR review comments → accept/refute gate → fix accepted via worktree + subagent TDD → reply to every thread; never resolves, never merges |
```

- [ ] **Step 5: Extend the Ticket backends closing paragraph**

In the `## Ticket backends` section, append this sentence to the existing
closing paragraph (the one starting "`tests/validate-skills.sh` enforces
the split..."):

```markdown
`sdlc:fixes` has one too, for the same reason — protecting its inline
`gh` usage — even though it isn't part of the ticket-backend list above:
PR comments are GitHub-native regardless of which ticket backend is
bound, so it has no step 0 to resolve.
```

- [ ] **Step 6: Verify content**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
for t in '/sdlc:fixes <PR#>' 'Never resolves a thread' 'sdlc:fixes has one too'; do
  grep -q "$t" README.md && echo "ok: $t" || echo "MISSING: $t"
done
```
Expected: all three print `ok:`.

- [ ] **Step 7: Full test sweep**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
for t in tests/test-*.sh tests/validate-skills.sh; do echo "== $t =="; bash "$t" | tail -1; done
```
Expected: every script ends `passed=N failed=0` (or `failed=0` for
scripts that don't print a `passed=` count); `validate-skills.sh` ends
`passed=22 failed=0` as in Task 2.

- [ ] **Step 8: Commit**

```bash
cd /Users/gmcquillan/src/sdlc-harness/.worktrees/sdlc-fixes-skill
git add README.md
git commit -m "docs(readme): document the sdlc:fixes skill"
```

---

## Self-Review

**Spec coverage:**
- Never creates a new PR, never merges → Task 1 SKILL.md intro + step 11.
  ✓
- Never resolves a thread on either accept or refute → Task 1 SKILL.md
  intro, step 10, red flags. ✓
- Three comment surfaces (inline/summary/conversation) → Task 1 step 3.
  ✓
- Bot filtering with reported count → Task 1 step 3 + step 11. ✓
- GraphQL resolved-thread filtering (REST has no resolution field) →
  Task 1 step 3. ✓
- Context discipline (subagent fetch/triage/fix, condensed list only) →
  Task 1 steps 3, 5, 7, 8. ✓
- Preconditions: required `<PR#>` arg, `gh auth status`, PR must be OPEN
  → Task 1 step 1. ✓
- Worktree reuse, not `using-git-worktrees` → Task 1 step 4 + red flags.
  ✓
- Fan-out triage per comment, accept/refute verdicts → Task 1 step 5. ✓
- Gate before any reply/resolve/push → Task 1 step 6 + red flags. ✓
- Fix only accepted comments, main loop never edits files → Task 1
  step 7 + red flags. ✓
- Verify + lint before push → Task 1 steps 8–9. ✓
- Reply mechanics (native threaded reply for inline, `gh pr comment` for
  summary/conversation) → Task 1 step 10. ✓
- Final report (accepted, refuted, bot count, PR URL, review suggestion)
  → Task 1 step 11. ✓
- No step 0 / excluded from `pipeline` var → Task 2 step 4 note + Global
  Constraints. ✓
- `expected` list + `gh_floors` entry → Task 2 steps 3–4. ✓
- README pipeline list, diagram, table, ticket-backends paragraph →
  Task 3 steps 2–5. ✓

**Placeholder scan:** No "TBD"/"implement later"/"add appropriate
handling" markers; every step shows literal file content, exact commands,
and expected output. ✓

**Type consistency:** The condensed comment shape
`{id, kind, author, location, body, thread_root_id}` is defined once (spec
§"Execution flow" intro, restated in Task 1 step 3) and referenced
identically nowhere else needs it restated with different field names.
The `gh_floors` entry name (`fixes`) matches the skill directory name
used in `expected` and in `skills/fixes/SKILL.md`'s frontmatter `name:`
field throughout. ✓
