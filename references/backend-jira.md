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

Each `gh` block in a pipeline skill is tagged with the ticketing
operation it implements:

```markdown
<!-- op: create_task -->
```

On JIRA, run this file's definition for that operation **instead of** the
tagged command. Everything else in the skill — its ordering, its gates,
its report formats — is unchanged.

Three rules make that unambiguous, because the skills' fenced blocks mix
GitHub-side and ticket-side commands:

1. **A tag marks a command, not a whole fenced block.** `implement`
   step 11 is one block holding `git push`, `gh pr create`,
   `gh issue edit`, and `gh issue comment`; only the last two are
   ticketing operations. Substitute those two and leave the rest of the
   block running exactly as written.
2. **One command may carry several tags** — run every tagged operation.
   `ticket` step 6's single `gh issue create` implements `create_task`
   *and*, through its `## Depends on` section, `link_dependency`. On
   JIRA that is two calls: create the Story, then link it.
3. **Untagged commands always run exactly as written**, even when they
   share a block with a tagged one. Those are the GitHub-side
   operations: `gh pr create`, `gh pr view`, `gh pr review`,
   `gh pr checkout`, and `gh auth status`. A JIRA binding never
   suppresses them.

Where the tags live:

| Operation | Tagged command |
|---|---|
| `create_epic` | `ticket` step 2 (the idempotency search), step 5, and the epic-body backfill in step 7 |
| `create_task` | `ticket` step 6; `review` step 5 tier B (tier C creates a tier-B-style ticket through the same block) |
| `link_dependency` | `ticket` step 6; `review` step 5 tier B |
| `list_open_tasks` | `next` step 2; `implement` step 1 |
| `get_state` | `next` step 2; `implement` step 1; `review` step 1; `resume` step 3 |
| `claim` | `implement` step 3 |
| `mark_in_review` | `implement` step 11 |
| `comment` | `implement` step 11 |
| `ticket_url` | `implement` step 11 PR body; `review` step 1 |

`ticket` step 2 is tagged `create_epic`, **not** `list_open_tasks`: it
searches for an existing *epic* across all states, which
`list_open_tasks` — scoped to open `sdlc:task` issues — can never
return. Routing it to `list_open_tasks` would make the check answer
"none" every time and file a duplicate epic on every run. Its JQL is
defined under `create_epic` below.

One deliberate exception to rule 3: **`gh label create` in `ticket`
step 3 is untagged but must be skipped.** JIRA labels come into
existence when first applied, so there is nothing to pre-create, and
running it would create four unused labels in the GitHub repo. Skip that
block; do not invent a JIRA equivalent.

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
"${CLAUDE_PLUGIN_ROOT}/bin/sdlc-backend.sh" get-toolmap
```

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
jql:  project = <project> AND issuetype = Epic AND summary ~ "<slug>"
```

A hit means the epic exists: reuse its key and create nothing. This
replaces the GitHub `gh issue list --search "<slug>"` check.

Otherwise:

```
tool: toolmap.ops.create_issue
  project:    <project>        # from resolve
  issue type: Epic
  summary:    [epic] <slug>
  description: Spec: `<spec-path>` (commit <sha>)
               ## Tasks
               - [ ] <REF> <title>       # backfilled once children exist
```

The `## Tasks` checklist is written for humans, exactly as on GitHub, with
`PROJ-123` references in place of `#123`. The authoritative parent-child
edge is the `parent` field set by `create_task`, not this list.

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
step 5 resolves the epic by reading the ref under that heading.

If the server rejects `parent` (some projects are not
team-managed, and classic projects use an Epic Link custom field
instead), fall back to a Blocks-free `link_issues` call with the server's
epic-link type, and say once that parent linkage used the fallback.

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
expand: issue links, assignee, labels, created
```

Scoped to one epic (`sdlc:next <epic ref>`), add
`AND parent = <epic ref>`.

The caller is always a subagent. **Normalize inside that subagent** to the
node shape the main loop expects — `{ref, title, dependsOn, inProgress,
inReview, assigned, ops, createdAt}` (`sdlc:next` currently names that
first field `number`; T4 generalizes it to `ref` for both backends) —
where `dependsOn` is the list of
inbound "is blocked by" refs and `inProgress` / `inReview` / `ops` are
label tests. Raw JIRA issue-link JSON must never reach the main loop;
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
  ref:      <ticket ref>
  assignee: <current user>
  labels:   add "sdlc:in-progress"
```

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
- Suppressing `gh pr` commands because the backend is JIRA — reviews stay
  on GitHub.
- Falling back to GitHub issues when JIRA errors — always stop instead.
- Reading this file on the GitHub path at all.
