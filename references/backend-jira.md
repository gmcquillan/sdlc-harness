# JIRA adapter

Read this file **only** when `sdlc-backend.sh resolve` reported
`action: use-jira`. On `use-github` the pipeline skills are already
complete as written and this file is not read at all — that is the point
of the design, not an accident. On `bind-needed`, read
`references/backend-bind.md` first.

You already hold `project`, `cloud_id`, `site`, and `toolmap` from the
same `resolve` output that sent you here. Do not run `resolve` again.

Tickets move to JIRA; **code review does not**. Branches, PRs, and
reviews stay on GitHub.

## How to use this file

The pipeline skills are written for GitHub, with their `gh` commands
inline and untouched. On JIRA, replace **only** the commands named in the
table below with this file's definition of the operation beside them.
Everything else — the skills' ordering, their gates, their report
formats, and every command not named here — is unchanged.

This table is the whole routing layer. It lives here rather than as
markers in the skills so that the GitHub path carries no trace of JIRA,
and so a change to the mapping is one edit rather than eight.

| Operation | Replaces |
|---|---|
| `create_epic` | `ticket` step 2 `gh issue list` (the idempotency search), step 5 `gh issue create`, and step 7 `gh issue edit` (the epic task-list backfill) |
| `create_task` | `ticket` step 6 `gh issue create`; `review` step 5 tier B `gh issue create` (tier C files a tier-B-style ticket through that same command) |
| `link_dependency` | no GitHub command of its own — it is the `## Depends on` section of the `create_task` commands above, which on JIRA becomes a second call once the Story exists |
| `list_open_tasks` | `next` step 2 `gh issue list`; `implement` step 1 `gh issue list` |
| `get_state` | `next` step 2 and `implement` step 1 `gh issue view <ref> --json state`; `review` step 1 `gh issue view <n> --json body`; `resume` step 3 `gh issue view <n> --json labels` |
| `claim` | `implement` step 3 `gh issue edit` |
| `mark_in_review` | `implement` step 11 `gh issue edit` |
| `comment` | `implement` step 11 `gh issue comment` |
| `ticket_url` | builds the `Ticket:` line in `implement` step 11's PR body, in place of `Closes #<n>` |

Two rows are easy to get wrong:

- **`ticket` step 2 is `create_epic`, not `list_open_tasks`.** It
  searches for an existing *epic* across all states, which
  `list_open_tasks` — scoped to open `sdlc:task` issues — can never
  return. Route it wrongly and the idempotency check answers "none" every
  run and files a duplicate epic. Its JQL is defined under `create_epic`
  below.
- **`implement` step 11 is a single fenced block holding four commands.**
  Only `gh issue edit` and `gh issue comment` are ticketing operations;
  the `git push` and `gh pr create` beside them run exactly as written.
  Substitute commands, never whole blocks.

**Commands that always run as written**, on either backend: `gh pr
create`, `gh pr view`, `gh pr review`, `gh pr checkout`, `gh auth
status`, and every `git` command. Code review stays on GitHub; a JIRA
binding never suppresses them.

**One command is skipped rather than translated:** `gh label create` in
`ticket` step 3. JIRA labels come into existence when first applied, so
there is nothing to pre-create, and running it would leave four unused
labels in the GitHub repo. Skip it; do not invent a JIRA equivalent.

## Resolving tools

The tool map is global to the machine and cached, because different JIRA
MCP servers name their tools differently and the MCP prefix depends on
the local server name.

**Use the `toolmap` you already hold from `resolve`.** It is the same
object — `{server, probed_at, ops:{…}}` — and re-reading it costs a
process for nothing. Resolve every operation below through
`toolmap.ops.<slot>`; the slots are `create_issue`, `search`,
`get_issue`, `edit_issue`, `comment`, `link_issues`, and `list_projects`.

Only after a mid-session re-probe (below) do you need to read it back:

```bash
sdlc-backend.sh get-toolmap
```

Call it by bare name, with no path in front. A plugin's `bin/` directory
is prepended to `PATH`, so `sdlc-backend.sh` resolves to the plugin's own
copy. Do **not** write `bin/sdlc-backend.sh` (the cwd is the user's repo,
not the plugin) and do not write `"${CLAUDE_PLUGIN_ROOT}/bin/…"` — that
variable is not exported into the Bash tool environment during a skill
step, so it expands to the empty string and the command becomes
`/bin/sdlc-backend.sh`, which does not exist.

That prints the cached object, or the literal `null` when none is
cached.

Before the first call of a session, confirm those cached tool names
appear in `ToolSearch` results. **If a cached name is absent, re-probe**
per `references/backend-bind.md` §"Probing the tool map" and write the
map back with `set-toolmap`. A stale map is re-probed, never fatal.

Argument names vary between servers as much as tool names do. The fields
named in each operation below are **semantic**: map them onto the actual
parameter names in the tool's schema from `ToolSearch`.

## The nine operations

### `create_epic`

Idempotency first — the pipeline must never file a second epic for a spec
it already ticketed:

```
tool: toolmap.ops.search
jql:  project = <project> AND issuetype = Epic
      AND labels = "sdlc:epic" AND summary ~ "<slug>"
```

**Reuse a hit only if its summary is exactly `[epic] <slug>`.** JQL's `~`
is fuzzy word matching — it is the only operator JQL offers on `summary`,
so the exactness test happens on the returned issue, not in the query.
Both guards matter: `labels = "sdlc:epic"` keeps hand-made epics out of
the result set, and the exact-summary test keeps a fuzzy word overlap
("auth" matching "Auth rate limiting") from adopting an unrelated epic
and filing every task in the project underneath it. No exact match →
treat it as "no epic exists" and create one.

A qualifying hit means the epic exists: reuse its key and create nothing.
This replaces the GitHub `gh issue list --search "<slug>"` check.

Otherwise:

```
tool: toolmap.ops.create_issue
  project:    <project>        # from resolve
  issue type: Epic
  labels:     ["sdlc:epic"]    # what the lookup above matches on
  summary:    [epic] <slug>    # the exact string the lookup requires
  description: Spec: `<spec-path>` (commit <sha>)
               ## Tasks
               - [ ] <REF> <title>       # backfilled once children exist
```

The `## Tasks` checklist is written for humans, exactly as on GitHub, with
`PROJ-123` references in place of `#123`. The authoritative parent-child
edge is the one `create_task` writes — the `parent` field, or whichever
fallback it names — not this list. The list is still worth keeping
current: it is what `list_open_tasks` cross-checks an empty scoped result
against.

### `create_task`

```
tool: toolmap.ops.create_issue
  project:    <project>
  issue type: Story
  parent:     <epic key>
  labels:     ["sdlc:task"]
  summary:    <task title>
  description: ## Context … ## Acceptance criteria … ## Scope …
               ## Depends on … ## Out of scope …
               ## Epic
               <epic key>
```

Keep every `##` section the GitHub path writes, including `## Depends on`
— humans read it on both backends. On JIRA the **authoritative**
dependency edge is the Blocks link from `link_dependency`; the prose is
the readable copy.

Keep the *layout* too, not just the headings: the reference goes on the
line **under** `## Epic`, never on the heading line, because `review`
step 5 resolves the epic by reading the ref under that heading — and
because that section is the epic edge of last resort (below).

**The `## Epic` section is written on every task, always**, whether or
not the `parent` field took. On GitHub there is no parent field at all
and this section *is* the epic association; on JIRA it is the same
readable fallback, so a task is never orphaned by a project layout.

If the server rejects `parent` (some projects are not team-managed, and
classic projects use an Epic Link custom field instead), fall back in
this order and **say once** which mechanism carried the epic edge:

1. A `link_issues` call using the server's **epic-link** type. Not
   Blocks — Blocks means "must finish first" and belongs to
   `link_dependency` alone; reusing it here would inject phantom
   dependencies into `next`'s leverage graph.
2. If the server exposes no epic-link type either, the `## Epic` section
   in the description is the epic edge on its own.

Whichever mechanism carried it, `list_open_tasks` must read the epic edge
back the *same* way — see the scoping table there.

### `link_dependency`

```
tool: toolmap.ops.link_issues
  type:     Blocks
  inward:   <blocker ref>      # the ticket that must finish first
  outward:  <blocked ref>      # the ticket that waits
```

Direction matters: blocker → blocked. `next` reads these back as inbound
"is blocked by" links, so a reversed link inverts the whole leverage
graph.

`inward`/`outward` are the one field pair whose meaning you cannot infer
from the name, and servers disagree about which is which. **Do not trust
the naming — check the result.** After the call, the *blocked* ticket
must display **is blocked by** `<blocker>`. If it instead shows
**blocks**, the arguments are swapped: reverse them and re-link. Confirm
this once per server, not once per link.

### `list_open_tasks`

```
tool: toolmap.ops.search
jql:  project = <project> AND labels = "sdlc:task" AND statusCategory != Done
expand: issue links, labels, description, created
```

Scoped to one epic (`sdlc:next <epic ref>`), narrow by **whichever
mechanism `create_task` actually used** for the epic edge:

| Epic edge `create_task` wrote | How to scope |
|---|---|
| `parent` field | add `AND parent = <epic ref>` to the JQL |
| epic-link issue link | keep tasks whose expanded links point at `<epic ref>` |
| `## Epic` section only | keep tasks whose description has `<epic ref>` under `## Epic` |

**Never add `AND parent = <epic ref>` unconditionally.** On a classic
project the parent field was never set, so that clause matches nothing,
`sdlc:next <epic>` reports "nothing ready", and a silent wrong answer
lands where a loud failure belongs.

When the scoping mechanism is not known up front, read the description
(`## Epic`) — it is written on every task and is therefore the one filter
that works on every project layout.

**Fail loudly, never emptily.** If the scoped set comes back empty,
cross-check it against the epic's own `## Tasks` checklist via
`get_state` — exactly as the GitHub path does. Checklist non-empty but
scoped set empty means the epic edge could not be read: **stop and
report** which mechanisms were tried. Only an epic whose checklist is
also empty may legitimately answer "no open tasks".

The caller is always a subagent. **Normalize inside that subagent** to the
node shape the main loop expects — `{ref, title, dependsOn, inProgress,
inReview, assigned, ops, createdAt}` (`sdlc:next` currently names that
first field `number`; T4 generalizes it to `ref` for both backends) —
where `dependsOn` is the list of
inbound "is blocked by" refs and `inProgress` / `inReview` / `ops` are
label tests. **`assigned` is always `false` on JIRA**: the claim is the
`sdlc:in-progress` label, not the assignee field — see `claim` below.
Raw JIRA issue-link JSON must never reach the main loop;
avoiding that is the entire reason the gather step is delegated.

### `get_state`

Reads one ticket. This is also the **only** operation that fetches a
ticket's contents, so it serves every "go look at that ticket" step in
the pipeline — `review` step 1 reading acceptance criteria out of the
description, and `implement` step 1 reading `## Depends on`:

```
tool: toolmap.ops.get_issue
  ref: <ticket ref>
returns: status category, labels, assignee, summary, description
```

**Open ⟺ `statusCategory != Done`. Never test a status name.** Projects
rename their terminal state — "Shipped", "Released", "Closed" — and
`statusCategory` is the only field that survives that, which is also what
keeps the pipeline out of custom workflow configuration entirely.

### `claim`

```
tool: toolmap.ops.edit_issue
  ref:    <ticket ref>
  labels: add "sdlc:in-progress"
```

**On JIRA the label alone is the claim. The adapter never sets an
assignee.** Atlassian Cloud wants an accountId to assign an issue, and
the bind probe defines no user-lookup slot to turn "me" into one — by
design. A live user lookup on every claim would buy nothing the label
does not already do: the label is what prevents double pickup by parallel
sessions, which is the whole job of this operation.

That makes readiness read differently on the two backends, and this is
the only place they differ:

| | GitHub | JIRA |
|---|---|---|
| Claim is | `sdlc:in-progress` label **+** assignee | `sdlc:in-progress` label |
| Ready iff | not `in-progress`/`in-review`, **unassigned**, deps closed | not `in-progress`/`in-review`, deps closed |

So wherever `sdlc:next` and `sdlc:implement` require a ticket to be
**unassigned**, drop that clause on JIRA and gate on the absence of
`sdlc:in-progress` instead. A human-set assignee is information, not a
gate; it never makes a ticket un-ready.

### `mark_in_review`

```
tool: toolmap.ops.edit_issue
  ref:    <ticket ref>
  labels: remove "sdlc:in-progress", add "sdlc:in-review"
```

This is a **label change, not a workflow transition** — see "What the
pipeline never does" below.

### `comment`

```
tool: toolmap.ops.comment
  ref:  <ticket ref>
  body: PR: <pr-url>
```

### `ticket_url`

A pure string, built from values already in hand:

```
<site>/browse/<REF>          e.g. https://acme.atlassian.net/browse/PROJ-123
```

`site` came from `resolve`, captured at bind time precisely so building a
link never costs a live call. If `site` is null the binding is
incomplete — stop and report rather than emitting a bare ref where a URL
belongs.

## Ticket references on JIRA

A reference is an opaque string: `#123` on GitHub, `PROJ-123` on JIRA.
Skills never parse it.

| Convention | GitHub | JIRA |
|---|---|---|
| Branch | `sdlc/42-add-widget` | `sdlc/PROJ-123-add-widget` |
| PR title | `<ticket title>` | `PROJ-123: <ticket title>` |
| PR body link | `Closes #42` | `Ticket: <ticket_url>` |

`Closes` becomes `Ticket:` because a JIRA key cannot auto-close from a
GitHub merge. `review` resolves its ticket from whichever of the two lines
is present, or from a key-prefixed PR title.

## What the pipeline never does

**It never drives a JIRA workflow transition.** Status names and
transition graphs vary per project, transitions fail in ways that are
tedious to recover from, and a half-transitioned ticket is worse than an
untouched one. `sdlc:in-progress` and `sdlc:in-review` are labels for
exactly this reason.

A human moves and closes the ticket when they merge. Approval in
`sdlc:review` therefore ends: *"Ready for your merge decision — the
ticket stays open until you move it."*

## Failure modes

| Situation | Behavior |
|---|---|
| JIRA MCP erroring or unauthenticated | **Stop and report.** Never fall back to GitHub — filing tickets into the wrong system is worse than a hard stop. |
| A cached tool name is absent from `ToolSearch` | Re-probe per `backend-bind.md`, write back with `set-toolmap`, continue. Stale maps are never fatal. |
| `toolmap.ops.link_issues` is unset (server has no issue linking) | Fall back to parsing the `## Depends on` prose as the dependency edge, and **say so once** in the run rather than silently dropping the graph. |
| A scoped `list_open_tasks` returns nothing but the epic's `## Tasks` checklist is non-empty | The epic edge is unreadable. **Stop and report** the mechanisms tried. Never answer "nothing ready" from an empty scoped set. |
| `toolmap.ops.search` is unset | Stop and report. Without search there is no `list_open_tasks`, no idempotency check, and `next` cannot rank anything. |
| `resolve` said `use-github` but this file was opened | Something mis-routed. Stop, re-run `resolve`, and follow its `action`. |
| Ticket ref not found, or `project` does not exist | Stop and report. Do **not** create a replacement ticket — a wrong-project ticket is invisible work. |
| `site` or `project` is null on a `use-jira` binding | The cache entry is incomplete. Stop and report; `sdlc-backend.sh unset` makes the next run re-bind. |

## Red flags

- Testing a status **name** instead of `statusCategory` — breaks on every
  project with a renamed terminal state.
- Letting raw JIRA JSON reach the main loop from the `list_open_tasks`
  scout — that is the context blowup the delegation exists to prevent.
- Reversing the Blocks direction — inverts the leverage ranking silently.
- Reusing an epic on a fuzzy `summary ~` hit alone — adopts a stranger's
  epic and parents the whole project under it. Require the `sdlc:epic`
  label *and* an exact `[epic] <slug>` summary.
- Scoping tasks with `AND parent = <epic ref>` on a project where the
  parent field was rejected — returns empty, and empty reads as "nothing
  ready" instead of as a failure.
- Gating readiness on an empty assignee field — on JIRA the claim is the
  `sdlc:in-progress` label; the adapter never assigns anyone.
- Writing `"${CLAUDE_PLUGIN_ROOT}/bin/sdlc-backend.sh"` or
  `bin/sdlc-backend.sh` — the first expands to a path that does not
  exist, the second only works from a checkout of this plugin. Bare
  `sdlc-backend.sh`.
- Suppressing `gh pr` commands because the backend is JIRA — reviews stay
  on GitHub.
- Falling back to GitHub issues when JIRA errors — always stop instead.
- Reading this file on the GitHub path at all.
