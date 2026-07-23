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
| `get_state` | every `gh issue view` in the pipeline, whichever `--json` fields it names: `next` step 2 `--json number,state`; `implement` step 1 `--json state`; `review` step 1 `--json body`; `resume` step 3 `--json labels` |
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
`toolmap.ops.<slot>`; the nine adapter slots are `create_issue`, `search`,
`get_issue`, `edit_issue`, `comment`, `link_issues`, `get_current_user`,
`get_transitions`, and `transition_issue`. (`list_projects`
and `list_sites` are in the map too, but they are bind-time only — no
operation here uses them.)

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
per `references/backend-bind.md` §"1. Probe the tool map" and write the
map back with `set-toolmap`. That section is a legitimate mid-session
entry point — read it for the re-probe alone, without running the rest of
the bind procedure. A stale map is re-probed, never fatal.

Argument names vary between servers as much as tool names do. The fields
named in each operation below are **semantic**: map them onto the actual
parameter names in the tool's schema from `ToolSearch`.

**Pass a cloud id only where the schema asks for one.** If the tool's
schema takes a cloud id or site id, pass the `cloud_id` you already hold
from `resolve`; a server pinned to a single site takes none at all (the
community `sooperset/mcp-atlassian` server binds its site through
`JIRA_URL` and rejects nothing because it accepts nothing). Do not invent
the argument where the schema has no slot for it, and do not omit it
where it is required — the official Atlassian remote server requires one
on **every** Jira call. That server also accepts the site URL in place of
the id, so a non-empty `site` is a usable fallback when `cloud_id` is
empty.

**`edit_issue` sets fields; it does not merge them.** Neither MCP server
this adapter targets exposes Jira's differential `update: {labels:
[{add: …}]}` form — both accept only a `fields` object, and a `labels`
value there **replaces the entire array**. Any operation that changes
labels is therefore a read-modify-write: `get_issue` for the current
labels, compute the resulting set locally, and write it whole. Sending
only the label you meant to add silently deletes every other label on the
ticket.

## The nine operations

### `create_epic`

Idempotency first — the pipeline must never file a second epic for a spec
it already ticketed:

```
tool: toolmap.ops.search
jql:  project = "<project>" AND labels = "sdlc:epic"
      AND summary ~ "<slug>"
```

**Quote `<project>`.** A Jira key is 2–10 uppercase alphanumerics and may
collide with a JQL reserved word — `IN`, `IS`, `NOT`, `OR`, `TO`, `ON`,
`BY`, `WAS`, `CF` — and `backend-bind.md` lets the user type the key by
hand, so an unquoted interpolation can turn into a parse error on a
perfectly valid project.

**Do not add `AND issuetype = Epic`.** On a site with no issue type by
that name JQL *errors* rather than returning an empty set, and the prose
around this query reads a non-hit as "no epic exists" — so the error path
and the file-a-new-epic path would be indistinguishable. The `sdlc:epic`
label is the type filter that always works.

**Reuse a hit only if its summary is exactly `[epic] <slug>`.** JQL's `~`
is fuzzy word matching — it is the only operator JQL offers on `summary`,
so the exactness test happens on the returned issue, not in the query.
Both guards matter: `labels = "sdlc:epic"` keeps hand-made epics out of
the result set, and the exact-summary test keeps a fuzzy word overlap
("auth" matching "Auth rate limiting") from adopting an unrelated epic
and filing every task in the project underneath it.

**A `~` miss is not proof of absence.** `summary ~` runs against Jira's
text index, which lags issue creation by seconds to minutes, and it
tokenizes — so a re-run moments after the epic was created can come back
empty and file the duplicate this operation exists to prevent. The
exact-summary post-filter removes false *positives*; nothing in it
recovers a false *negative*. So before concluding "no epic exists",
confirm with a second query that touches no text index:

```
tool: toolmap.ops.search
jql:  project = "<project>" AND labels = "sdlc:epic"
```

then filter those results client-side for the exact summary `[epic]
<slug>`. Only when **both** come back without an exact match may you
treat it as "no epic exists" and create one.

A qualifying hit means the epic exists. That is the "an epic exists"
branch of `ticket` step 2, which **stops and asks the user: update the
existing epic in place, or abort?** Reusing the key and creating nothing
is what "update in place" does on this backend; it is not a decision this
operation makes on its own. This replaces the GitHub `gh issue list
--search "<slug>"` check.

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

Once the children exist, backfill that checklist — this is `ticket` step
7:

```
tool: toolmap.ops.edit_issue
  ref:         <epic key>
  description: Spec: `<spec-path>` (commit <sha>)
               ## Tasks
               - [ ] <REF> <title>       # one line per child, in T-order
```

`edit_issue` **replaces the description wholesale**, which is what this
step wants — but it means the `Spec: <path> (commit <sha>)` line must be
re-emitted along with the checklist. Send only the `## Tasks` block and
the spec provenance is gone.

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

**Re-linking does not undo the wrong link.** The tool map has no unlink
slot and the Atlassian MCP servers expose no delete-link tool, so the
mis-directed link stays until a human removes it in the Jira UI. Say so
in the run — name the stray link and the two tickets — rather than
leaving a backwards edge for `next` to read. Better: calibrate the
direction once on a throwaway pair of tickets, before linking anything
real.

### `list_open_tasks`

```
tool: toolmap.ops.search
jql:  project = "<project>" AND labels = "sdlc:task" AND statusCategory != Done
expand: issue links, labels, description, created
```

**Drain the pagination before you filter anything.** JIRA search is
paged: the tool takes a page size (`maxResults`, capped server-side) and
returns a continuation token (`nextPageToken`, or a `startAt` offset on
older schemas). Keep requesting until no token comes back, and only then
scope, filter, or normalize. Two of the three scoping rows below are
client-side post-filters over whatever the search returned — run one over
page 1 alone on a project with many `sdlc:task` issues and you get a
non-empty but truncated set, which is the one shape the empty-result
cross-check cannot catch. `next` then ranks leverage over a partial
graph and reports a confident wrong answer.

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
cross-check it against the epic's own `## Tasks` checklist: read the epic
with `get_state`, then read each ref the checklist names with `get_state`
too. **Alarm only on a ref that is not Done yet is missing from the
scoped set** — that combination, and only that one, means the epic edge
could not be read; **stop and report** which mechanisms were tried.

The checklist's `- [ ]` boxes are not evidence. Nothing in the pipeline
ever ticks or prunes them — `ticket` step 7 writes every line unchecked
and no later step touches the epic body — so an epic whose tasks are all
finished still presents a non-empty checklist. Since the query above
excludes `statusCategory = Done`, its scoped set is legitimately empty
there, and an unconditional alarm would hard-stop `sdlc:next <epic>` on
every epic's normal terminal run. An epic whose named refs are all Done
(or whose checklist is empty) answers "no open tasks" and the run
continues.

This cross-check is JIRA-only; there is no GitHub counterpart to match.
`sdlc:next` step 2 runs no such check, and step 7 *reports the frontier*
for an exhausted epic rather than stopping. The check exists here because
JIRA has three possible epic-edge mechanisms and a silently unreadable
one is indistinguishable from an empty result — a failure mode the
GitHub path does not have.

The caller is always a subagent. **Normalize inside that subagent** to the
node shape the main loop expects — `{ref, title, dependsOn, inProgress,
inReview, assigned, ops, createdAt}` — where `dependsOn` is the list of
inbound "is blocked by" refs and `inProgress` / `inReview` / `ops` are
label tests. **`assigned` is always `false` on JIRA, regardless of
whether the ticket has an assignee.** The claim signal readiness gates on
is the `sdlc:in-progress` label; `claim` (below) may also set an
assignee as a courtesy to humans, but that field is never read by this
normalization — see `claim` for what it does and does not gate. Raw
JIRA issue-link JSON must never reach the main loop; avoiding that is
the entire reason the gather step is delegated.

### `get_state`

Reads one ticket. This is also the **only** operation that fetches a
ticket's contents, so it serves every "go look at that ticket" step in
the pipeline — `review` step 1 reading acceptance criteria out of the
description, and `implement` step 1 reading `## Depends on`:

```
tool: toolmap.ops.get_issue
  ref: <ticket ref>
returns: status category, labels, summary, description
```

The assignee field comes back too — `claim` (below) may have set it —
and it is fine to show a human. It is **not** part of the state this
adapter acts on for readiness: `list_open_tasks` normalizes `assigned` to
`false` unconditionally, and readiness gates on the `sdlc:in-progress`
label — see `claim` below.

**Open ⟺ `statusCategory != Done`. Never test a status name.** Projects
rename their terminal state — "Shipped", "Released", "Closed" — and
`statusCategory` is the only field that survives that, which is also what
keeps the pipeline out of custom workflow configuration entirely.

### Discovering a workflow transition

Both `claim`'s start-transition step and `sdlc:cleanup`'s close-on-merge
step need the same thing: a project-wide, human-confirmed transition
name, discovered lazily against a live ticket rather than typed blind at
bind time. This procedure is written once here; neither caller repeats
it — they reference it by this heading.

A fresh project has no sample ticket to probe at bind time, and
`get_transitions` is state-dependent — the transitions reachable from
"To Do" differ from those reachable from "In Review". So the first time
an operation needs a transition name that is not yet cached
(`workflow.start` for `claim`, `workflow.done` for close-on-merge):

1. Call `toolmap.ops.get_transitions` on the **actual ticket being acted
   on** — never a different ticket, and never a cached list from an
   earlier call.
2. Present the live options it returns for that ticket's current state
   and ask the human which one applies ("which one means start work?"
   for `claim`, "which one means done?" for close-on-merge).
3. Cache the chosen transition's **name**, not its `id` — ids are scoped
   to the source state and issue type, so an id cached from one ticket's
   probe would not resolve on the next ticket; names are stable
   project-wide. Write it with `sdlc-backend.sh set-workflow --start
   <name>` (`claim`) or `sdlc-backend.sh set-workflow --done <name>`
   (close-on-merge).
4. Match the cached name against this ticket's live options from step 1
   to find the id to pass to `toolmap.ops.transition_issue`.

Every later call — a different ticket, a different session — re-probes
`get_transitions` fresh for the specific ticket in hand and looks for the
cached name among the returned options. **If the cached name is not
among the live options** (the workflow changed, or this ticket's current
state cannot reach it), stop and report which name was expected and what
was actually offered. Never substitute a guess. Offer to re-discover:
running `set-workflow` again overwrites only the slot passed (`--start`
or `--done`), leaving the other one untouched — see Task 1's cache merge
behavior.

If the ticket is already past the state the cached transition would move
it to (edge case: reopened work already past "start"), skip the
transition and say so — this is not a failure.

The same "ask once, cache the stable identifier" pattern resolves "who am
I" for `claim`'s assignee step, except there the identifier is an
`accountId` from `get_current_user` rather than a transition name.

### `claim`

Three independent steps run alongside each other. Only the first existed
before this design; it is otherwise unchanged.

**1. The label** — a read-modify-write, because `edit_issue` replaces the
label array wholesale:

```
1. tool: toolmap.ops.get_issue      # read the current labels
     ref: <ticket ref>
2. tool: toolmap.ops.edit_issue     # write the complete resulting set
     ref:    <ticket ref>
     labels: <every label read back> + "sdlc:in-progress"
```

**Send the whole set, never just the new label.** `sdlc:task` and any
`ops` label must survive: dropping `sdlc:task` removes the ticket from
`list_open_tasks` permanently — its JQL matches on that label — and from
`sdlc:next`'s leverage graph with it, so claiming a ticket would make it
disappear from the pipeline that just claimed it.

**The label remains the pipeline's sole authoritative readiness/claim
signal, unconditionally.** Steps 2 and 3 below are best-effort additions
alongside it, never a replacement for it: a failure in either is reported
to the user but must never block the label add, and the label add must
never be skipped or delayed to retry either of them.

**2. The assignee** — independent of the label and of step 3:

If `assignee_account_id` is uncached (check the `resolve` output this
run's own step 0 already produced — do not call `resolve` again):

- Call `toolmap.ops.get_current_user`. If that slot is absent from the
  toolmap, fall back to `toolmap.ops.search`-reachable
  `lookupJiraAccountId` with a search string the human supplies (their
  name or email) — the fallback `backend-bind.md` documents for the
  missing slot.
- Show the resolved display name to the human for confirmation before
  caching anything.
- Cache the id: `sdlc-backend.sh set-assignee --account-id <id>`.
- Call `toolmap.ops.edit_issue` to set the ticket's assignee field to
  that id.

If neither `get_current_user` nor the `lookupJiraAccountId` fallback
resolves an account, skip the assignee step, say so once per session —
not once per ticket — and continue. This is not a failure, and the label
add above proceeds regardless.

**3. The start transition** — independent of the label and of step 2:

If `workflow.start` is uncached, run "Discovering a workflow transition"
above against **this** ticket, caching the name with `sdlc-backend.sh
set-workflow --start <name>`, then call `toolmap.ops.transition_issue`
with the id matching that name among this ticket's live options.

If `workflow.start` is already cached, re-probe `get_transitions` on this
ticket fresh, confirm the cached name is still among the live options
(stop and report per "Discovering a workflow transition" if it is not),
and call `toolmap.ops.transition_issue` with its id.

If the ticket is already past the state that transition would move it to
(edge case: reopened work), skip the transition and say so — this is not
a failure.

A `transition_issue` error (permission, workflow condition unmet) is
reported to the user; the label change — already applied, or applied
alongside — stands regardless.

Readiness reads exactly as it did before this design:

| | GitHub | JIRA |
|---|---|---|
| Claim is | `sdlc:in-progress` label **+** assignee | `sdlc:in-progress` label |
| Ready iff | not `in-progress`/`in-review`, **unassigned**, deps closed | not `in-progress`/`in-review`, deps closed |

So wherever `sdlc:next` and `sdlc:implement` require a ticket to be
**unassigned**, drop that clause on JIRA and gate on the absence of
`sdlc:in-progress` instead. The assignee this operation now sets is
information for a human, not a gate — a ticket's readiness never turns on
it, on either backend.

### `mark_in_review`

The same read-modify-write as `claim`:

```
1. tool: toolmap.ops.get_issue
     ref: <ticket ref>
2. tool: toolmap.ops.edit_issue
     ref:    <ticket ref>
     labels: <every label read back>, minus "sdlc:in-progress",
             plus "sdlc:in-review"
```

Again the full set: `sdlc:task` and any `ops` label are carried across
untouched. This operation runs *after* `claim`, so a set-shaped write
that forgot them here is the one that makes the loss unrecoverable — the
ticket is gone from `list_open_tasks` with no later step that would put
it back.

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

A reference is an opaque string: `123` on GitHub — written `#123` inside
issue bodies, but bare when passed to `gh` — and `PROJ-123` on JIRA.
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

**It never drives a JIRA workflow transition beyond the two configured
ones.** `claim` transitions status to a human-confirmed "start" state,
and a merged ticket is transitioned to a human-confirmed "done" state
through `sdlc:cleanup`'s close-on-merge step — both lazily discovered per
"Discovering a workflow transition" above, both fail-soft. Every *other*
state is untouched: `mark_in_review` stays a label change (`sdlc:in-review`),
never a transition — a third configured transition was considered and
declined. Status names and transition graphs vary per project outside
these two configured names, transitions fail in ways that are tedious to
recover from, and a half-transitioned ticket is worse than an untouched
one for anything not covered by the lazy-discovery guardrail above.

Approval in `sdlc:review` still ends: *"Ready for your merge decision —
the ticket stays open until you move it."* — and now, once the PR merges,
`sdlc:cleanup` offers a confirmed close transition rather than requiring
a human to move the ticket by hand.

## Failure modes

| Situation | Behavior |
|---|---|
| JIRA MCP erroring or unauthenticated | **Stop and report.** Never fall back to GitHub — filing tickets into the wrong system is worse than a hard stop. |
| A cached tool name is absent from `ToolSearch` | Re-probe per `backend-bind.md`, write back with `set-toolmap`, continue. Stale maps are never fatal. |
| `toolmap.ops.link_issues` is unset (server has no issue linking) | Fall back to parsing the `## Depends on` prose as the dependency edge, and **say so once** in the run rather than silently dropping the graph. |
| A scoped `list_open_tasks` returns nothing, and a ref named in the epic's `## Tasks` checklist is **not Done** | The epic edge is unreadable. **Stop and report** the mechanisms tried. Never answer "nothing ready" from an empty scoped set whose refs are still open. |
| A scoped `list_open_tasks` returns nothing and every checklist ref is Done | Normal — the epic is finished. Answer "no open tasks" and continue. The unticked `- [ ]` boxes mean nothing; the pipeline never ticks them. |
| `toolmap.ops.search` is unset | Stop and report. Without search there is no `list_open_tasks`, no idempotency check, and `next` cannot rank anything. |
| `resolve` said `use-github` but this file was opened | Something mis-routed. Stop, re-run `resolve`, and follow its `action`. |
| Ticket ref not found, or `project` does not exist | Stop and report. Do **not** create a replacement ticket — a wrong-project ticket is invisible work. |
| `site` or `project` is null on a `use-jira` binding | The cache entry is incomplete. Stop and report; `sdlc-backend.sh unset` makes the next run re-bind. |
| `cloud_id` is null and the tool schema requires a cloud id | Try `site` in its place — the official server accepts the site URL as `cloudId`. If `site` is also null, the cache entry is incomplete: stop and report, and `unset` to re-bind. A server whose schema takes no cloud id needs neither. |
| Cached `workflow.start`/`workflow.done` name absent from live transitions | Stop and report the expected name and the live options; do not guess a substitute. Offer to re-discover. |
| `get_current_user` slot unset and no fallback resolves an account | Skip assignee only; still apply the label; say so once per session, not once per ticket. |
| `transition_issue` call errors (permission, workflow condition unmet) | Stop and report; the label change (already applied, or applied alongside) stands regardless — labels are the pipeline's authoritative claim signal, not the Jira status. |
| Ticket already in a state the cached transition can't reach (e.g. reopened past "start") | Not a failure — skip the transition, say so, continue. |
| JIRA MCP erroring/unauthenticated | Stop and report, matching existing adapter policy — never fall back to GitHub. |
| `cleanup`'s merged-PR map has no JIRA-shaped branch (`sdlc/<ref>-`) | No close-on-merge line item is offered; existing branch-only behavior is unchanged. |

## Red flags

- Testing a status **name** instead of `statusCategory` — breaks on every
  project with a renamed terminal state.
- Letting raw JIRA JSON reach the main loop from the `list_open_tasks`
  scout — that is the context blowup the delegation exists to prevent.
- Reversing the Blocks direction — inverts the leverage ranking silently.
- Sending `edit_issue` only the label you meant to add or remove — the
  `labels` field is a whole-array replacement, so that write deletes
  `sdlc:task` and any `ops` label along with it, and the ticket vanishes
  from `list_open_tasks` for good. Read with `get_issue` first, write the
  complete set.
- Filtering or ranking a `toolmap.ops.search` result before draining
  `nextPageToken` — a truncated set looks like a small project, not like
  an error.
- Reusing an epic on a fuzzy `summary ~` hit alone — adopts a stranger's
  epic and parents the whole project under it. Require the `sdlc:epic`
  label *and* an exact `[epic] <slug>` summary.
- Scoping tasks with `AND parent = <epic ref>` on a project where the
  parent field was rejected — returns empty, and empty reads as "nothing
  ready" instead of as a failure.
- Gating readiness on an empty assignee field — on JIRA the claim is the
  `sdlc:in-progress` label; an assignee, when `claim` sets one, is
  information for a human, not a gate.
- Writing `"${CLAUDE_PLUGIN_ROOT}/bin/sdlc-backend.sh"` or
  `bin/sdlc-backend.sh` — the first expands to a path that does not
  exist, the second only works from a checkout of this plugin. Bare
  `sdlc-backend.sh`.
- Suppressing `gh pr` commands because the backend is JIRA — reviews stay
  on GitHub.
- Falling back to GitHub issues when JIRA errors — always stop instead.
- Reading this file on the GitHub path at all.
- Substituting a guessed transition name when the cached one is not among
  `get_transitions`'s live options — stop and report instead, per
  "Discovering a workflow transition".
- Blocking the label add on an assignee-lookup or transition failure —
  both are fail-soft; the label is not.
