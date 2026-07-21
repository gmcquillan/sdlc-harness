# JIRA adapter and bind reference documents — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write the two prose contracts — `references/backend-jira.md` and
`references/backend-bind.md` — that let the pipeline skills act on a
JIRA-bound repo without any of that prose leaking onto the GitHub path.

**Architecture:** Two markdown files at plugin root, outside `skills/` so
skill discovery never loads them. `backend-jira.md` is the hot path: read
once per session when `sdlc-backend.sh resolve` reports
`action: use-jira`. `backend-bind.md` is the cold path: read once per repo,
ever, when `action` is `bind-needed`. Neither is read on `use-github` —
that is the constraint the whole design exists to protect. There is
deliberately **no `backend-github.md`**.

**Tech Stack:** Markdown prose. The only executable dependency is
`bin/sdlc-backend.sh` (bash + jq, already shipped in T1). MCP tool calls
are described, not made — bash cannot call MCP tools, so nothing here is
machine-verifiable beyond content assertions and the existing suite.

## Global Constraints

Values copied verbatim from `docs/2026-07-21-jira-ticket-backend-design.md`
and from the shipped `bin/sdlc-backend.sh`. Every task's requirements
implicitly include this section.

- **Spec:** `docs/2026-07-21-jira-ticket-backend-design.md` §T2. Issue #3.
- **File locations:** `references/backend-jira.md`, `references/backend-bind.md`
  — plugin root, NOT under `skills/`.
- **No `references/backend-github.md`.** Creating one fails the task.
- **The nine operations**, exact spelling, are the entire ticketing
  vocabulary: `create_epic` · `create_task` · `link_dependency` ·
  `list_open_tasks` · `get_state` · `claim` · `mark_in_review` ·
  `comment` · `ticket_url`.
- **The seven tool-map slots**, exact spelling, are what a probe fills:
  `create_issue`, `search`, `get_issue`, `edit_issue`, `comment`,
  `link_issues`, `list_projects`. Note `comment` is both an operation
  name and a tool slot; always disambiguate a slot as
  `toolmap.ops.<slot>`.
- **`resolve` JSON keys**, exact: `repo`, `action`, `backend`, `project`,
  `cloud_id`, `site`, `toolmap`. `action` ∈
  `use-github` | `use-jira` | `bind-needed`.
- **`sdlc-backend.sh` exit codes:** `3` = not a git repo, `2` = usage error.
- **`set` is strict** (it `die`s, exit 2, otherwise):
  `--backend jira` REQUIRES `--project`; `--source` accepts ONLY
  `git-sniff-confirmed` or `user-selected`.
- **`sniff` output** is `KEY COUNT` per line, already denylisted and
  already floored at 3 hits — the prose must not re-implement that filter.
- **Closed means `statusCategory = Done`**, never a status name.
- **Ticket references are opaque strings:** `#123` on GitHub,
  `PROJ-123` on JIRA.
- **House style:** match `skills/*/SKILL.md` — imperative voice, numbered
  steps, tables for mappings, fenced blocks for exact commands, a closing
  failure/red-flag section. No `references/` precedent exists; these two
  files establish it.
- **Never silently fall back to GitHub** when JIRA is bound and erroring.
  Filing tickets into the wrong system is worse than a hard stop.

---

## File Structure

| File | Responsibility | Read when |
|---|---|---|
| `references/backend-jira.md` | The adapter. Defines all nine operations against `toolmap.ops.*`, plus the ref format, the open test, and per-operation failure behavior. | Every session where `action: use-jira` |
| `references/backend-bind.md` | The one-time bind procedure: tool-map probe, sniff, the prompt, the `set` calls, the memory breadcrumb. | Only on `action: bind-needed` |

Split by responsibility, not by layer: bind prose is read once per repo
and would otherwise be re-read every JIRA session for no benefit. That
separation is an explicit cost constraint in the spec, not a stylistic
choice.

---

### Task 1: `references/backend-jira.md` — the adapter

**Files:**
- Create: `references/backend-jira.md`
- Test: none. No test file is in scope (spec T2 Scope lists only the two
  reference files; `tests/validate-skills.sh` assertions are T8's
  deliverable). Verification is the content checklist in Step 2 below,
  run as greps.

**Interfaces:**
- Consumes: `bin/sdlc-backend.sh resolve` output — the keys `project`,
  `cloud_id`, `site`, and `toolmap` (whose shape is
  `{server, probed_at, ops:{...7 slots...}}`); and `get-toolmap`, which
  prints that object or the literal `null`.
- Produces: the `<!-- op: NAME -->` tag vocabulary that T3–T7 will place
  on each inline `gh` block, and the nine operation definitions those
  tags resolve to. T3–T7 depend on these exact names.

- [ ] **Step 1: Write the file**

Required contents, in order:

1. **Preamble** — one paragraph: this file is read only when `resolve`
   reports `action: use-jira`; if it is being read on `use-github`,
   something is wrong; the reader already has `project`, `cloud_id`,
   `site`, and `toolmap` from that same `resolve` output and must not
   re-run it.
2. **How to use this file** — the substitution rule: each `gh` block in a
   pipeline skill is tagged `<!-- op: NAME -->`; on JIRA, run this file's
   definition for `NAME` instead of the tagged block; untagged `gh`
   blocks (PR operations — `gh pr create`, `gh pr review`,
   `gh pr checkout`, `gh pr view`) are GitHub-side and **always run
   as written**, because code review never moves to JIRA.
3. **Tool resolution** — a fenced block showing the read:
   ```
   toolmap=$(bin/sdlc-backend.sh get-toolmap)
   ```
   and the rule: resolve each slot to a real tool name via
   `toolmap.ops.<slot>`; before first use, confirm those names appear in
   `ToolSearch` results; if any cached name is absent, re-probe per
   `references/backend-bind.md` §"Probing the tool map" and write the map
   back with `set-toolmap` — re-probe, never fail.
4. **The nine operations** — one subsection each, with a fenced
   pseudo-call naming the tool slot and its arguments. Exact semantics:

   | Operation | JIRA behavior |
   |---|---|
   | `create_epic` | `toolmap.ops.create_issue`, project = `project`, issue type `Epic`, summary `[epic] <slug>`. Idempotency precondition: first run `toolmap.ops.search` with JQL `project = <K> AND issuetype = Epic AND summary ~ "<slug>"`; a hit means the epic exists — reuse its key, create nothing. |
   | `create_task` | `toolmap.ops.create_issue`, issue type `Story`, `parent` = epic key, label `sdlc:task`. Description carries the same `## Context` / `## Acceptance criteria` / `## Scope` / `## Depends on` / `## Out of scope` / `## Epic` sections written on GitHub. |
   | `link_dependency` | `toolmap.ops.link_issues`, link type **Blocks**, direction blocker → blocked. |
   | `list_open_tasks` | `toolmap.ops.search`, JQL `project = <K> AND labels = "sdlc:task" AND statusCategory != Done`, expanded with issue links, assignee, labels, and created date. |
   | `get_state` | open ⟺ `statusCategory != Done`. Read one issue with `toolmap.ops.get_issue`. |
   | `claim` | `toolmap.ops.edit_issue`: assignee = current user, add label `sdlc:in-progress`. |
   | `mark_in_review` | `toolmap.ops.edit_issue`: remove `sdlc:in-progress`, add `sdlc:in-review`. |
   | `comment` | `toolmap.ops.comment` on the ticket key. |
   | `ticket_url` | Pure string: `<site>/browse/<KEY>`. No live call. |

5. **Reference format** — `PROJ-123`, opaque to skills; the branch
   pattern generalizes to `sdlc/<ref>-<slug>`; on JIRA a PR body carries
   `Ticket: <ticket_url>` in place of `Closes #<n>` because a JIRA key
   cannot auto-close from a GitHub merge; the PR title is prefixed
   `PROJ-123: `.
6. **What the pipeline never does** — no workflow transitions, ever.
   Status names vary per project; a human moves and closes the ticket at
   merge. This is why `mark_in_review` is a label change and not a
   transition.
7. **Failure modes** — a table with a stated behavior for each:
   - JIRA MCP erroring or unauthenticated → **stop and report**; never
     fall back to GitHub.
   - Cached tool names absent from `ToolSearch` → re-probe and
     `set-toolmap`; do not fail.
   - MCP with no issue-linking tool (`toolmap.ops.link_issues` unset) →
     fall back to the `## Depends on` prose as the dependency edge, and
     say so **once** per session rather than silently dropping the graph.
   - `resolve` reported `use-github` → this file must not have been read;
     stop and re-resolve.
   - Ticket key not found / project key wrong → stop and report; do not
     create a replacement ticket.

- [ ] **Step 2: Verify content assertions**

Run from the worktree root:

```bash
test -f references/backend-jira.md || echo "FAIL: file missing"
test ! -e references/backend-github.md || echo "FAIL: github adapter must not exist"
for op in create_epic create_task link_dependency list_open_tasks \
          get_state claim mark_in_review comment ticket_url; do
  grep -q "$op" references/backend-jira.md || echo "FAIL: missing op $op"
done
# six of the seven slots; list_projects is bind-only and is NOT an adapter op
for slot in create_issue search get_issue edit_issue comment link_issues; do
  grep -q "toolmap.ops.$slot" references/backend-jira.md || echo "FAIL: missing slot $slot"
done
grep -q 'statusCategory != Done' references/backend-jira.md || echo "FAIL: open test"
grep -q 'Blocks' references/backend-jira.md || echo "FAIL: Blocks link type"
grep -q '<!-- op:' references/backend-jira.md || echo "FAIL: op tag vocabulary"
grep -q '/browse/' references/backend-jira.md || echo "FAIL: ticket_url form"
```

Expected: no output at all. Any `FAIL:` line means the file is incomplete.

- [ ] **Step 3: Commit**

```bash
git add references/backend-jira.md
git commit -m "docs(jira): define the nine ticketing operations as a JIRA adapter"
```

---

### Task 2: `references/backend-bind.md` — the bind procedure

**Files:**
- Create: `references/backend-bind.md`
- Test: none in scope; verification is the content checklist in Step 2.

**Interfaces:**
- Consumes: `sdlc-backend.sh sniff` (`KEY COUNT` lines, already floored
  and denylisted), `set-toolmap` (whole tool-map object on stdin),
  `get-toolmap`, and `set` with its strict flag contract.
- Produces: a populated cache entry — `backend`, `project`, `cloud_id`,
  `site`, `source` — that `resolve` reads on every subsequent run, and a
  cached `jira_toolmap` that `backend-jira.md` resolves slots against.

- [ ] **Step 1: Write the file**

Required contents, in order:

1. **Preamble** — read only on `action: bind-needed`, once per repo ever.
   `bind-needed` means a `jira`/`atlassian`-looking MCP server is
   configured **and** this repo has no recorded binding. It does not mean
   JIRA is reachable — that is step 1's job to establish.
2. **Probing the tool map** — `ToolSearch` for JIRA tools; fill each of
   the seven slots from whatever names exist (server naming differs:
   the official Atlassian remote server uses `createJiraIssue`, the
   community `mcp-atlassian` uses `jira_create_issue`, and the MCP prefix
   depends on the local server name, so no hardcoded table survives
   contact). Write it back exactly once:
   ```bash
   printf '%s' "$toolmap_json" | bin/sdlc-backend.sh set-toolmap
   ```
   with the object shape spelled out:
   ```json
   {"server":"atlassian","probed_at":"YYYY-MM-DD",
    "ops":{"create_issue":"…","search":"…","get_issue":"…",
           "edit_issue":"…","comment":"…","link_issues":"…",
           "list_projects":"…"}}
   ```
   A slot with no matching tool is omitted, not guessed —
   `backend-jira.md` states the fallback for a missing `link_issues`.
   The map is global, not per-repo, so this cost is paid once per machine.
3. **Capturing cloud id and site** — from the `list_projects` response at
   bind time, so `ticket_url` never needs a live call afterward.
4. **The sniff** — run `bin/sdlc-backend.sh sniff`; take the top line;
   its output is already denylisted and floored at 3 hits, so **do not
   re-filter**. Empty output means no confident candidate — skip straight
   to listing projects.
5. **The open-GitHub-issues warning** — before prompting, count open
   pipeline issues:
   ```bash
   gh issue list --label "sdlc:task" --state open --json number | jq length
   ```
   A non-zero count goes in the prompt and **the default answer becomes
   GitHub**, so nobody strands a half-built epic across two systems.
6. **The prompt** — asked exactly once, quoting the spec's wording:
   > History shows `PROJ` (42 refs). Use JIRA project PROJ, a different
   > project, or stay on GitHub issues?

   "A different project" lists projects via `toolmap.ops.list_projects`.
7. **Recording the answer** — the exact commands for each outcome, with
   the strict-flag contract made explicit (`--backend jira` requires
   `--project`; `--source` is exactly one of two values):
   ```bash
   # sniffed key accepted
   bin/sdlc-backend.sh set --backend jira --project PROJ \
     --cloud-id "$CLOUD_ID" --site "https://acme.atlassian.net" \
     --source git-sniff-confirmed
   # user picked a different project
   bin/sdlc-backend.sh set --backend jira --project OTHER \
     --cloud-id "$CLOUD_ID" --site "https://acme.atlassian.net" \
     --source user-selected
   # user chose to stay on GitHub — cached, because it is an explicit decision
   bin/sdlc-backend.sh set --backend github --source user-selected
   ```
   State plainly that choosing GitHub here **is** cached, unlike the
   no-MCP case, and that `sdlc-backend.sh unset` is how a repo re-asks.
8. **Per-run override** — `--backend github|jira` on a skill invocation
   overrides that run **without** rewriting the binding.
9. **Memory pointer** — after a successful bind, write a one-fact memory
   file (`type: project`) naming repo, backend, and project, and add its
   `MEMORY.md` line — **only if a memory directory already exists**, so
   the plugin stays portable. The cache stays authoritative; this is a
   human-readable breadcrumb, not a second source of truth.
10. **Continue** — after binding, proceed with `references/backend-jira.md`
    for this run; do not re-run `resolve`.
11. **Failure modes** — a stated behavior for each:
    - No JIRA MCP configured at all → `resolve` returns `use-github` and
      **this file is never read**; nothing is probed, prompted, or
      cached, so installing a JIRA MCP later still produces this prompt.
    - MCP present but erroring or unauthenticated → **stop and report**;
      write nothing to the cache, so the next run re-asks. Never fall
      back to GitHub silently.
    - `list_projects` unavailable or empty → cannot capture cloud id and
      site; report and stop rather than binding a project that cannot
      build a `ticket_url`.
    - Sniff returns nothing → skip the sniff line in the prompt and offer
      the project list plus "stay on GitHub".
    - Server named unrecognizably → `resolve` yields a false
      `use-github`; the escape hatch is `--backend jira` on the
      invocation or a manual `sdlc-backend.sh set`.
    - `set` rejects the call (exit 2) → surface the script's stderr
      verbatim; do not retry with invented flag values.

- [ ] **Step 2: Verify content assertions**

```bash
test -f references/backend-bind.md || echo "FAIL: file missing"
grep -q 'ToolSearch' references/backend-bind.md || echo "FAIL: probe"
grep -q 'set-toolmap' references/backend-bind.md || echo "FAIL: toolmap cache write"
grep -q 'git-sniff-confirmed' references/backend-bind.md || echo "FAIL: source vocab"
grep -q 'user-selected' references/backend-bind.md || echo "FAIL: source vocab"
grep -q 'cloud.id\|cloud_id' references/backend-bind.md || echo "FAIL: cloud id capture"
grep -qi 'open .*sdlc:task\|sdlc:task.*open' references/backend-bind.md \
  || echo "FAIL: open GitHub issues warning"
grep -q 'MEMORY.md' references/backend-bind.md || echo "FAIL: memory pointer"
grep -qi 'only if a memory directory' references/backend-bind.md \
  || echo "FAIL: conditional memory pointer"
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add references/backend-bind.md
git commit -m "docs(jira): specify the one-time backend bind procedure"
```

---

### Task 3: Cross-file audit against the spec

**Files:**
- Modify (only if the audit finds gaps): `references/backend-jira.md`,
  `references/backend-bind.md`

**Interfaces:**
- Consumes: both files from Tasks 1 and 2.
- Produces: nothing new — this task is the acceptance gate for issue #3's
  third criterion ("Each failure mode in the design has a stated
  behavior in one of the two files").

- [ ] **Step 1: Walk the spec's failure-mode list**

`docs/2026-07-21-jira-ticket-backend-design.md` §"Failure modes" lists
exactly five. Confirm each has a stated behavior, and record which file
states it:

| Spec failure mode | Must be stated in |
|---|---|
| No JIRA MCP → the feature is inert | `backend-bind.md` |
| Repo mid-flight with open GitHub `sdlc:task` issues | `backend-bind.md` |
| JIRA MCP present but erroring or unauthenticated → stop and report | both |
| Stale tool map → re-probe instead of failing | both |
| A JIRA MCP without issue linking → fall back to `## Depends on` prose, say so once | `backend-jira.md` |

- [ ] **Step 2: Check vocabulary consistency across both files**

```bash
# every tool slot named in bind must be a slot the adapter resolves
grep -o 'toolmap\.ops\.[a-z_]*' references/*.md | sort -u
# no GitHub adapter smuggled in
ls references/
```
Expected: only the seven known slots appear, and `ls` shows exactly
`backend-bind.md` and `backend-jira.md`.

- [ ] **Step 3: Run the full suite**

```bash
for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t"; done
```
Expected: every file reports `failed=0`. These files are prose, so the
suite proves only that nothing regressed — it cannot prove the adapter
is correct. That is exactly why the spec schedules T9 as a manual
end-to-end run against a live JIRA instance.

- [ ] **Step 4: Commit any fixes**

```bash
git add references/
git commit -m "docs(jira): close failure-mode and vocabulary gaps found in audit"
```

---

## Out of scope (do not do these here)

- Editing any `skills/*/SKILL.md`, including adding `<!-- op: … -->` tags
  — that is T3–T7. This task only *defines* the tag vocabulary.
- `tests/validate-skills.sh` assertions, `README.md`, `plugin.json` 0.5.0
  — all T8.
- Any live MCP call or JIRA instance interaction — T9, manual.
- Creating `references/backend-github.md` — forbidden by the design.
