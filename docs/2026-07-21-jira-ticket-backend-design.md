# JIRA as a ticket backend

**Date:** 2026-07-21
**Status:** approved, pending implementation

## Problem

Every ticketing step in the pipeline is hardwired to `gh`. `sdlc:ticket`
shells out to `gh issue create`, `sdlc:next` ranks `gh issue list` output,
`sdlc:implement` claims issues with `gh issue edit`, and `sdlc:review`
resolves its ticket from a `Closes #<n>` line. Teams that track work in
JIRA cannot use the pipeline without filing their work twice.

The goal: when a JIRA MCP server is connected, let a repo be bound to
JIRA for ticketing — remembering that choice, and the JIRA project the
repo uses, across sessions and across git worktrees.

## Scope

**Tickets move to JIRA; code review does not.** Epics and tasks live in
JIRA; branches, PRs, and reviews stay on GitHub. The pipeline never
drives JIRA workflow transitions — status names vary per project and
transitions fail in ways that are tedious to recover from. A human moves
and closes the ticket when they merge.

Out of scope: dual-writing to both backends, GitLab/Linear/other
backends, migrating existing GitHub issues into JIRA.

## Architecture

Three pieces, in order of how much they are trusted:

1. **`bin/sdlc-backend.sh`** — a shell utility owning everything
   deterministic: repo identity, the preference cache, and the
   git-history scan for JIRA keys. Unit-tested.
2. **`references/backend-*.md`** — adapter documents defining nine
   ticketing operations and how each backend performs them. Read by the
   model.
3. **The pipeline skills** — rewritten to speak only in those nine
   operations, so their logic (leverage ranking, readiness, human gates)
   exists once regardless of backend.

The split exists because a skill instruction like "scan git log for JIRA
keys and rank by frequency" is prose the model re-improvises every
session, while a script does it identically every time and can be proven
correct by a test.

### `bin/sdlc-backend.sh`

| Command | Behavior |
|---|---|
| `resolve` | Prints one JSON object: repo key, backend, project, cloud id, cached tool map. Exit 3 outside a git repo. |
| `sniff` | Ranked JIRA-key candidates from history, one `KEY COUNT` per line. |
| `set --backend <github\|jira> [--project K] [--cloud-id X] [--site URL]` | Binds the current repo. |
| `set-toolmap` / `get-toolmap` | Global op→tool-name map, read from / written to stdout as JSON. |
| `unset` | Drops the current repo's binding so the next run re-asks. |

**Repo key.** `git remote get-url origin` normalized to `host/owner/name`:
`git@github.com:a/b.git`, `https://github.com/a/b`, `https://github.com/a/b/`,
and `ssh://git@github.com/a/b.git` all collapse to `github.com/a/b`. With
no origin remote, the key is `path:<realpath of the parent of
git rev-parse --git-common-dir>` — which resolves a worktree to its main
repository, so every worktree of a repo shares one key under either
scheme.

This is why the cache is keyed by remote rather than stored in Claude's
per-project memory directory: that directory is keyed by working-directory
path, and this pipeline spends most of its life in worktrees at paths
that differ from the main checkout.

**Cache** at `${SDLC_HOME:-$HOME/.claude/sdlc}/repos.json`. The env
override exists so tests run against a sandbox.

```json
{ "version": 1,
  "jira_toolmap": {
    "server": "atlassian",
    "probed_at": "2026-07-21",
    "ops": {
      "create_issue":  "mcp__atlassian__createJiraIssue",
      "search":        "mcp__atlassian__searchJiraIssuesUsingJql",
      "get_issue":     "mcp__atlassian__getJiraIssue",
      "edit_issue":    "mcp__atlassian__editJiraIssue",
      "comment":       "mcp__atlassian__addCommentToJiraIssue",
      "link_issues":   "mcp__atlassian__createJiraIssueLink",
      "list_projects": "mcp__atlassian__getVisibleJiraProjects"
    }
  },
  "repos": {
    "github.com/gmcquillan/sdlc-harness": {
      "backend": "jira",
      "project": "PROJ",
      "cloud_id": "…",
      "site": "https://acme.atlassian.net",
      "bound_at": "2026-07-21",
      "source": "git-sniff-confirmed"
    }
  }
}
```

Writes go through a temp file and `mv`, so a killed session cannot leave
a truncated cache. An absent or malformed `repos.json` is treated as
empty rather than an error.

**The sniff.** Pattern `[A-Z][A-Z0-9]{1,9}-[0-9]+` over the last 500
commit subjects and bodies plus local and remote branch names, ranked by
frequency. A denylist rejects `UTF`, `ISO`, `RFC`, `CVE`, `SHA`, `MD`,
`AES`, `RSA`, `TLS`, `SSL`, `HTTP`, `UTC`, `GMT`, `X86`, `ARM`, `PEP`,
`IPV` so that `UTF-8` and `CVE-2024-1234` never become project keys.
Candidates below 3 hits are not proposed.

### Backend resolution

Step 0 of `ticket`, `next`, `implement`, and `review`:

1. `resolve` returns a cached backend → use it. No prompts, no MCP calls.
2. No binding → probe via `ToolSearch` for JIRA tools. **None found →
   GitHub, and nothing is cached**, so installing a JIRA MCP later still
   produces the bind prompt.
3. JIRA tools found and the repo is unbound → run `sniff`, then ask once:

   > History shows `PROJ` (42 refs). Use JIRA project PROJ, a different
   > project, or stay on GitHub issues?

   "A different project" lists projects via the `list_projects` tool. The
   answer is cached with `source: git-sniff-confirmed` or
   `source: user-selected`. The cloud id and site URL are captured from
   the `list_projects` response at bind time, so `ticket_url` never needs
   a live call to build a link.
4. `--backend github|jira` on any skill invocation overrides that run
   **without** rewriting the binding.

**Tool map probing.** On the first JIRA use, `ToolSearch` for JIRA tools
and fill in each tool-map slot from whatever names exist — the map is
then cached, so the fuzzy step happens once rather than every session.
Different JIRA MCP servers name their tools differently (the official
Atlassian remote server uses `createJiraIssue`, the community
`mcp-atlassian` uses `jira_create_issue`), and the MCP prefix depends on
the local server name, so no hardcoded table would survive contact. If
the cached tool names are absent from the current `ToolSearch` results,
re-probe rather than fail.

**Memory pointer.** After a bind, write a one-fact memory file
(`type: project`) naming the repo, backend, and project, and add its
MEMORY.md line — but only if a memory directory already exists, so the
plugin stays portable. The cache remains authoritative; the memory file
is a human-readable breadcrumb, not a second source of truth.

### The adapter layer

Three files at plugin root — `references/backend-resolve.md`,
`references/backend-github.md`, `references/backend-jira.md`. They live
outside `skills/` so skill discovery does not attempt to load them as
skills.

Nine operations are the entire ticketing vocabulary the pipeline knows:

`create_epic` · `create_task` · `link_dependency` · `list_open_tasks` ·
`get_state` · `claim` · `mark_in_review` · `comment` · `ticket_url`

The GitHub adapter is the current `gh` invocations, lifted verbatim out
of the skills. The JIRA adapter maps the same operations through the
cached tool map:

| Operation | JIRA |
|---|---|
| `create_epic` | `create_issue`, type Epic, summary `[epic] <slug>` |
| `create_task` | `create_issue`, type Story, `parent` = epic key, label `sdlc:task` |
| `link_dependency` | `link_issues`, type **Blocks**, blocker → blocked |
| `list_open_tasks` | JQL `project = K AND labels = "sdlc:task" AND statusCategory != Done`, expanded with issue links, assignee, labels, created |
| `get_state` | open ⟺ `statusCategory != Done` |
| `claim` | `edit_issue`: assignee = me, add label `sdlc:in-progress` |
| `mark_in_review` | `edit_issue`: `sdlc:in-progress` → `sdlc:in-review` |
| `comment` | `comment` |
| `ticket_url` | `<site>/browse/<KEY>` |

**Closed means `statusCategory = Done`, never a status name.** This is
what keeps the readiness test working on a project whose terminal state
is called "Shipped" — and what lets us stay entirely out of custom
workflow configuration.

Ticket references are `#123` on GitHub and `PROJ-123` on JIRA. Skills
treat a reference as an opaque string.

### Per-skill changes

- **`ticket`** — step 0 resolves the backend; the dry-run gate table
  gains a `Backend: JIRA (PROJ)` header line, so creation into the wrong
  system cannot be approved by accident. Creation steps become adapter
  operations. The JIRA idempotency check is a JQL search for the spec
  slug in epic summaries. The `## Depends on` markdown section is still
  written into the description on both backends for humans, but on JIRA
  the authoritative edge is the Blocks link.
- **`next`** — leverage model, readiness test, ranking, and report format
  are unchanged. The gather scout calls `list_open_tasks` and must
  normalize the result into the existing compact node shape
  (`{ref, title, dependsOn, inProgress, inReview, assigned, ops,
  createdAt}`) **inside the subagent** — JIRA's issue-link JSON must not
  reach the main loop, which is the whole reason that step is delegated.
  On JIRA, `dependsOn` comes from inbound "is blocked by" links.
- **`implement`** — selection and claiming become operations. The branch
  is `sdlc/<ref>-<slug>`, so `sdlc/PROJ-123-add-widget`. The PR title is
  prefixed `PROJ-123: `; the body's `Closes #<n>` becomes
  `Ticket: <url>`, because a JIRA key cannot auto-close from a GitHub
  merge. Base-sync and every step after delivery are unchanged.
- **`review`** — resolves its ticket from `Closes #<n>`, the `Ticket:`
  line, or a key-prefixed title. Tier B ticket creation goes through
  `create_task` + `link_dependency`. Since nothing transitions the JIRA
  ticket, approval ends: "Ready for your merge decision — the ticket
  stays open until you move it."
- **`handoff` / `resume` / `cleanup`** — the handoff file's `Issue: #<n>`
  becomes `Ticket: <ref>` plus a `Backend:` line; `resume` verifies state
  via `get_state`; `cleanup`'s branch pattern widens from
  `sdlc/<digits>-` to `sdlc/<ref>-`.
- **`interview`** — unchanged. The `T<n>` decomposition format is already
  backend-neutral.

## Failure modes

- **No JIRA MCP → the feature is inert.** No cache writes, no prompts, no
  behavior change. This is the default for every existing user.
- **Repo mid-flight with open GitHub `sdlc:task` issues.** The bind
  prompt reports the count and defaults to GitHub, so nobody strands a
  half-built epic across two systems.
- **JIRA MCP present but erroring or unauthenticated → stop and report.**
  Never silently fall back to GitHub; filing tickets into the wrong
  system is worse than a hard stop.
- **Stale tool map** — re-probe instead of failing.
- **A JIRA MCP without issue linking** — fall back to parsing the
  `## Depends on` prose, and say so once rather than silently dropping
  the dependency graph.

## Testing

`tests/test-sdlc-backend.sh`, in the style of the existing hook tests,
with `SDLC_HOME` pointed at a temp directory and throwaway git repos:

- remote normalization across all four URL forms → one key
- a `git worktree add` checkout resolves to the same key as its main repo
- no-origin repo → stable `git-common-dir` fallback key
- sniff ranking, the 3-hit floor, denylist rejection of `UTF-8`,
  `CVE-2024-1234`, `RFC-3339`
- `set` → `resolve` round trip; `unset` clears; unbound repo reports
  `backend: null`
- tool map round trip
- absent and malformed `repos.json` treated as empty, not fatal

`tests/validate-skills.sh` gains two assertions: each pipeline skill
mentions `backend-resolve`, and all three `references/*.md` exist —
guarding against a future edit silently dropping step 0.

**Not machine-verified:** bash cannot call MCP tools, so the JIRA adapter
is verified by one end-to-end manual run against a real JIRA instance —
create an epic, create two linked tasks, confirm `next` ranks them by
leverage, confirm `implement` claims one — with the output recorded in
the PR. This is written down rather than left implicit so a green suite
does not imply coverage that does not exist.

## Docs

README gains a "Ticket backends" section and lists the JIRA MCP as an
optional requirement. `plugin.json` goes to `0.5.0` and adds a `jira`
keyword.

## Decomposition

### T1: Add bin/sdlc-backend.sh with repo keying, cache, and key sniffing
**Acceptance criteria:**
- [ ] `resolve` prints JSON with repo key, backend, project, cloud id, and tool map; exits 3 outside a git repo
- [ ] All four remote URL forms normalize to one `host/owner/name` key
- [ ] A worktree resolves to the same key as its main repo; a no-origin repo gets a stable `git-common-dir` fallback key
- [ ] `sniff` ranks JIRA keys by frequency over 500 commits and branch names, applies the denylist, and suppresses candidates under 3 hits
- [ ] `set`/`unset`/`set-toolmap`/`get-toolmap` round-trip through `${SDLC_HOME:-$HOME/.claude/sdlc}/repos.json` with atomic temp-file writes
- [ ] Absent or malformed `repos.json` is treated as empty rather than fatal
- [ ] `tests/test-sdlc-backend.sh` covers every criterion above and passes
**Scope:** `bin/sdlc-backend.sh`, `tests/test-sdlc-backend.sh`
**Depends on:** none
**Out of scope:** any MCP interaction; any skill edits

### T2: Write the backend resolution and adapter reference documents
**Acceptance criteria:**
- [ ] `references/backend-resolve.md` specifies the four-step resolution order, the `ToolSearch` probe and tool-map caching, the bind prompt (including the open-GitHub-issues warning), the `--backend` override, and the conditional memory pointer
- [ ] `references/backend-github.md` defines all nine operations as the `gh` commands currently in the skills
- [ ] `references/backend-jira.md` defines all nine operations against the cached tool map, with `statusCategory != Done` as the open test and Blocks links as dependency edges
- [ ] Both adapters document the same nine operation names and the opaque-reference convention
- [ ] Each failure mode in the design has a stated behavior in `backend-resolve.md`
**Scope:** `references/backend-resolve.md`, `references/backend-github.md`, `references/backend-jira.md`
**Depends on:** T1
**Out of scope:** skill edits

### T3: Make sdlc:ticket backend-agnostic
**Acceptance criteria:**
- [ ] Step 0 resolves the backend per `references/backend-resolve.md`
- [ ] The dry-run gate table shows a `Backend:` header line naming backend and project
- [ ] Epic and task creation and the epic task list go through adapter operations, not literal `gh` calls
- [ ] The JIRA idempotency check is a JQL search of epic summaries for the spec slug
- [ ] Dependencies are recorded as `link_dependency` calls, with the `## Depends on` prose still written for humans
**Scope:** `skills/ticket/SKILL.md`
**Depends on:** T2
**Out of scope:** other skills

### T4: Make sdlc:next backend-agnostic
**Acceptance criteria:**
- [ ] Step 0 resolves the backend; gather calls `list_open_tasks`
- [ ] The scout normalizes backend output into the existing node shape inside the subagent; no raw JIRA link JSON reaches the main loop
- [ ] On JIRA, `dependsOn` derives from inbound "is blocked by" links; open/closed uses `get_state`
- [ ] Leverage model, readiness test, ranking order, and report format are unchanged
**Scope:** `skills/next/SKILL.md`
**Depends on:** T2
**Out of scope:** other skills

### T5: Make sdlc:implement backend-agnostic
**Acceptance criteria:**
- [ ] Step 0 resolves the backend; selection, claim, and mark-in-review use adapter operations
- [ ] Branch naming is `sdlc/<ref>-<slug>` and works for both `123` and `PROJ-123`
- [ ] On JIRA the PR title is prefixed `PROJ-123: ` and the body carries `Ticket: <url>` in place of `Closes #<n>`
- [ ] The PR URL is posted back to the ticket via `comment`
- [ ] Base-sync and the never-merge rule are unchanged
**Scope:** `skills/implement/SKILL.md`
**Depends on:** T2
**Out of scope:** other skills

### T6: Make sdlc:review backend-agnostic
**Acceptance criteria:**
- [ ] The reviewed ticket resolves from `Closes #<n>`, a `Ticket:` line, or a key-prefixed PR title
- [ ] Tier B ticket creation uses `create_task` + `link_dependency`
- [ ] The approval message states that the ticket stays open until the human moves it
- [ ] Fan-out, skeptic verification, and the triage gate are unchanged
**Scope:** `skills/review/SKILL.md`
**Depends on:** T2, T5
**Out of scope:** other skills

### T7: Generalize ticket references in handoff, resume, and cleanup
**Acceptance criteria:**
- [ ] The handoff file records `Ticket: <ref>` and a `Backend:` line in place of `Issue: #<n>`
- [ ] `resume` verifies recorded ticket state via `get_state` on the recorded backend
- [ ] `cleanup` matches `sdlc/<ref>-<slug>` branches for both numeric and `PROJ-123` references
- [ ] `tests/test-handoff-pickup.sh` and `tests/test-handoff-worktree.sh` still pass
**Scope:** `skills/handoff/SKILL.md`, `skills/resume/SKILL.md`, `skills/cleanup/SKILL.md`
**Depends on:** T2
**Out of scope:** other skills

### T8: Extend skill validation and update docs
**Acceptance criteria:**
- [ ] `tests/validate-skills.sh` asserts each of ticket/next/implement/review mentions `backend-resolve`
- [ ] `tests/validate-skills.sh` asserts all three `references/*.md` exist
- [ ] README gains a "Ticket backends" section, lists the JIRA MCP as optional, and its tests command covers the new test
- [ ] `plugin.json` is at `0.5.0` with a `jira` keyword
- [ ] The full suite passes
**Scope:** `tests/validate-skills.sh`, `README.md`, `.claude-plugin/plugin.json`
**Depends on:** T3, T4, T5, T6, T7
**Out of scope:** skill logic changes

### T9: End-to-end verification against a live JIRA instance
**Acceptance criteria:**
- [ ] With a JIRA MCP connected, a cold repo produces the bind prompt and caches the choice
- [ ] `ticket` creates an epic and two tasks with a Blocks link between them
- [ ] `next` ranks the unblocked task first and reports the blocked one as context
- [ ] `implement` claims the ticket, opens a correctly-titled PR, and comments the PR URL back
- [ ] Results are recorded in the PR or epic; any defect found becomes a new task
**Scope:** manual run; no code changes expected. Label this issue `ops` —
it is actioned by a human, produces no PR, and is exempt from the review
flow, per `sdlc:next`'s ops handling.
**Depends on:** T8
**Out of scope:** automated MCP testing, which bash cannot do
