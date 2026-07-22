# Binding a repo to a ticket backend

Read this file in one of two situations, and only these:

- **A first bind.** `sdlc-backend.sh resolve` reported
  `action: bind-needed`, which happens at most once per repo. It means a
  JIRA-looking MCP server is configured **and** this repo has no recorded
  binding. It does **not** mean JIRA is reachable — step 2's first live
  call establishes that. Work through every step below.
- **A mid-session re-probe.** A cached tool name has stopped appearing in
  `ToolSearch` — the user upgraded their Atlassian MCP and a tool was
  renamed — and `references/backend-jira.md` sent you back here. Run
  **step 1 only**, write the refreshed map, and resume where you left
  off. A re-probe re-prompts nothing and touches no binding.

Every worktree of a repo shares one binding, because the cache is keyed
by the origin remote rather than by working-directory path (and, for a
repo with no origin, by the main repository's git directory — which
every worktree also shares).

On a first bind, work through the steps in order, then continue the run
with `references/backend-jira.md` (or with the skill's inline `gh`
commands, if the answer was GitHub).

## 1. Probe the tool map

The map is **global to the machine**, not per repo, so this runs once
ever rather than once per project. Different servers name their tools
differently — the official Atlassian remote server uses
`createJiraIssue`, the community `mcp-atlassian` uses
`jira_create_issue`, and the MCP prefix depends on the local server
name — so no hardcoded table would survive contact.

Check for an existing map first:

```bash
sdlc-backend.sh get-toolmap
```

Call it by bare name, here and everywhere below. The plugin's `bin/` is
prepended to `PATH`, so the bare name resolves to the plugin's copy from
any working directory — `which sdlc-backend.sh` confirms it. Do not add a
path prefix: `bin/sdlc-backend.sh` resolves against the user's repo, and
`${CLAUDE_PLUGIN_ROOT}` is empty in the Bash tool's environment, which
would leave `/bin/sdlc-backend.sh`.

If that prints anything but `null` and the names still appear in
`ToolSearch` results, skip to step 2.

Otherwise `ToolSearch` for JIRA tools and fill each slot from whatever
names actually exist:

```json
{"server": "atlassian",
 "probed_at": "YYYY-MM-DD",
 "ops": {"create_issue":  "mcp__atlassian__createJiraIssue",
         "search":        "mcp__atlassian__searchJiraIssuesUsingJql",
         "get_issue":     "mcp__atlassian__getJiraIssue",
         "edit_issue":    "mcp__atlassian__editJiraIssue",
         "comment":       "mcp__atlassian__addCommentToJiraIssue",
         "link_issues":   "mcp__atlassian__createJiraIssueLink",
         "list_projects": "mcp__atlassian__getVisibleJiraProjects",
         "list_sites":    "mcp__atlassian__getAccessibleAtlassianResources"}}
```

Six of these — `create_issue`, `search`, `get_issue`, `edit_issue`,
`comment`, `link_issues` — are what the adapter runs on. `list_projects`
and `list_sites` are used only at bind time, by step 2 of this file, and
either may be missing on a server pinned to one fixed site. The names
above are one server's — they are illustrative, not a table to copy.
`probed_at` is a human-readable breadcrumb and nothing more: no code
path reads it, and staleness is decided solely by whether a cached name
still appears in `ToolSearch`, never by that date's age.

**Omit a slot with no matching tool; never guess a name.** A missing
`link_issues` has a defined fallback in `backend-jira.md`; an invented
tool name just fails later, further from its cause.

### Writing the map back

```bash
printf '%s' "$toolmap_json" | sdlc-backend.sh set-toolmap
```

`set-toolmap` **replaces** the stored map; it does not merge into it
(`.jira_toolmap = $tm`). So every write must carry the *complete* object.
Piping in a one-slot fragment wipes the other seven, and the next session
finds the names missing and silently re-probes.

**On a first bind, do not run that command yet.** `ToolSearch` reports
tool names whether or not the server is authenticated, so the probe alone
proves nothing about reachability; step 2's sites lookup is the first
live call. The single write belongs at the end of step 2 — by then the
server has answered and `list_sites` is confirmed. If the server turns
out to be present but erroring or unauthenticated, **stop and report**:
nothing has been written — no tool map, no binding — so the next run
re-asks instead of inheriting a half-made decision.

**On a mid-session re-probe**, the binding already exists and the server
has already been answering, so write straight away — re-emitting every
slot, not just the renamed one — and go back to what you were doing.

## 2. Capture the cloud id and site, then list projects

**Order matters here, and it is the reverse of what you might expect.**
On the official Atlassian remote server, `list_projects`
(`getVisibleJiraProjects`) *requires* a `cloudId` argument — so the cloud
id cannot come out of that response. It comes from a sites/resources tool
(`getAccessibleAtlassianResources` on that server), which returns the
accessible sites with their `id` and `url`.

So:

1. From the same `ToolSearch` probe as step 1, find the tool that lists
   accessible Atlassian sites and call it. Record its `id` as the **cloud
   id** and its `url` as the **site** (e.g. `https://acme.atlassian.net`).
   If more than one site is accessible, ask which to use rather than
   picking the first.
2. Record that tool in the map's eighth, **optional** slot, `list_sites`,
   so a later re-probe does not have to rediscover it.
3. Pass the cloud id to `toolmap.ops.list_projects` to get the project
   list for step 5.
4. That call succeeding is the proof step 1 was waiting for, so now write
   the map — once, complete, all the slots you filled — with the
   `set-toolmap` command in step 1. If step 1 found a usable cached map
   and you skipped the probe, there is nothing new to write; leave it
   alone.

Some servers have no such tool because they are configured against a
single fixed site — the community `mcp-atlassian` takes a base URL in its
own configuration and never asks for a cloud id at all. There, take the
site from that configuration and leave the cloud id empty; `--cloud-id`
is optional on `set`.

Both values are recorded because each has its own job later, and neither
substitutes for the other:

- The **site** is what `ticket_url` builds `<site>/browse/<REF>` from,
  forever after without a live call. It is the only one `ticket_url`
  needs.
- The **cloud id** is a *call* argument. The official Atlassian remote
  server requires a `cloudId` on essentially every Jira tool call, which
  is why it must be on hand at runtime rather than looked up each time;
  the community server takes none. Pass it only if the tool's schema
  takes one. The official server also accepts a site URL as the `cloudId`
  value, so `site` can stand in when the cloud id is empty.

**The site is the fatal one.** If you cannot determine a site URL, **stop
and report** — binding a project whose site is unknown produces tickets
nobody can link to. A missing or empty `list_projects` is not fatal by
itself: on a single-fixed-site server there is often nothing to
disambiguate, so a key from step 3's sniff or typed by the user is
enough. Without a project list, step 5 simply drops the "a different
project" menu and asks for a key instead.

## 3. Sniff the repo's history for a project key

```bash
sdlc-backend.sh sniff
```

Output is one `KEY COUNT` per line, most frequent first, over the last
500 commit subjects and bodies plus local and remote branch names.

**Do not re-filter it.** The script has already applied the denylist
(so `UTF-8`, `CVE-2024-1234` and `RFC-3339` are gone) and already
suppressed anything under 3 hits. Take the top line as the candidate.

Empty output means no confident candidate: skip the history line in the
prompt and offer the project list plus staying on GitHub.

## 4. Check for work already in flight on GitHub

Before prompting, count the open pipeline issues this repo already has:

```bash
gh issue list --label "sdlc:task" --state open --json number | jq length
```

A non-zero count goes into the prompt **and makes GitHub the default
answer**, so nobody strands a half-built epic across two systems.

If that command fails — no GitHub remote, `gh` unauthenticated — treat
the count as zero, say so in the prompt, and carry on. This check is a
safeguard against splitting an epic, not a precondition for binding.

## 5. Ask — once

> History shows `PROJ` (42 refs). Use JIRA project PROJ, a different
> project, or stay on GitHub issues?

With work in flight, say so and default to GitHub:

> History shows `PROJ` (42 refs), but this repo has 7 open `sdlc:task`
> issues on GitHub. Staying on GitHub keeps that epic in one place. Use
> JIRA project PROJ, a different project, or stay on GitHub issues?

"A different project" lists the projects fetched in step 2. Ask this
once; the answer is cached and never re-asked unless someone runs
`unset`.

## 6. Record the answer

The flags are strict — `sdlc-backend.sh set` exits 2 rather than record
something it cannot use. `--backend jira` **requires** `--project`, and
`--source` is exactly one of two values.

```bash
# the sniffed key was accepted
sdlc-backend.sh set --backend jira --project PROJ \
  --cloud-id "$CLOUD_ID" --site "https://acme.atlassian.net" \
  --source git-sniff-confirmed

# a different project was chosen from the list
sdlc-backend.sh set --backend jira --project OTHER \
  --cloud-id "$CLOUD_ID" --site "https://acme.atlassian.net" \
  --source user-selected

# stay on GitHub
sdlc-backend.sh set --backend github --source user-selected
```

**Choosing GitHub here *is* cached** — it is an explicit decision, unlike
a machine with no JIRA MCP, which is never asked and never written. To
make a repo ask again:

```bash
sdlc-backend.sh unset
```

If `set` exits non-zero, surface its stderr verbatim and stop. Do not
retry with invented flag values.

## 7. Leave a memory breadcrumb — only if memory already exists

**Only if a memory directory already exists** (the plugin must stay
portable to installs without one), write a one-fact memory file and add
its `MEMORY.md` pointer line:

```markdown
---
name: <repo-name>-ticket-backend
description: <repo> files pipeline tickets in JIRA project <PROJECT>
metadata:
  type: project
---

`<host/owner/name>` is bound to the JIRA backend, project `<PROJECT>`,
site `<site>`. The binding lives in `${SDLC_HOME:-$HOME/.claude/sdlc}/repos.json`
and is shared by every worktree of this repo.
```

The cache stays authoritative. This file is a human-readable breadcrumb,
not a second source of truth — never read the binding back out of it.

## 8. Continue the run

The binding is recorded. Proceed with this run using
`references/backend-jira.md` for a JIRA answer, or the skill's inline
`gh` commands for a GitHub one. **Do not re-run `resolve`** — you already
know the outcome.

## Overriding without rebinding

`--backend github|jira` on any skill invocation overrides that single
run and **does not rewrite the binding**. It is also the escape hatch
when a JIRA MCP server is named unrecognizably: `resolve` decides
`bind-needed` versus `use-github` by matching `jira|atlassian`
case-insensitively against configured server names, so a server called
something else yields a false `use-github` and is never prompted for.

## Failure modes

| Situation | Behavior |
|---|---|
| No JIRA MCP configured at all | `resolve` returns `use-github` and **this file is never read**. Nothing is probed, prompted, or cached — so installing a JIRA MCP later still produces this prompt. |
| MCP present but erroring or unauthenticated | **Stop and report.** Write nothing to the cache; the next run re-asks. Never fall back to GitHub silently. |
| No site URL determinable — no sites tool, and none in the server's own configuration | Stop and report. Without a site there is no `ticket_url`, whatever else is known. |
| `list_projects` unavailable or empty, but the site is known | Not fatal on its own. A single-fixed-site server has nothing to disambiguate: take the key from `sniff` or ask the user to type one, and drop the project menu from step 5. Stop only if no project key can be established either way. |
| `sniff` returns nothing | Not an error. Drop the history line from the prompt and offer the project list plus GitHub. |
| A tool slot has no matching tool | Omit the slot. `backend-jira.md` defines the fallback for a missing `link_issues` and stops for a missing `search`. |
| Cached tool map is stale — a name no longer appears in `ToolSearch` | **Re-probe, never fail.** Re-run step 1 and `set-toolmap` the fresh names, re-emitting every slot (the write replaces, it does not merge). The adapter sends readers here mid-session for exactly this; a re-probe does not re-prompt and does not touch the repo binding. |
| Server named unrecognizably (no `jira`/`atlassian` in its name) | `resolve` yields a false `use-github`. Escape hatch: `--backend jira` on the invocation, or a manual `sdlc-backend.sh set`. |
| `set` exits 2 | Surface stderr verbatim and stop. Most likely a `jira` binding with no `--project`, or a `--source` outside the two accepted values. |
| Repo has open GitHub `sdlc:task` issues | Report the count in the prompt and default to GitHub. |
| Not a git repo (`resolve` or `set` exits 3) | Stop. There is no repo identity to bind. |

## Red flags

- Prompting more than once, or re-prompting on a later run — the answer
  is cached for a reason.
- Re-filtering `sniff` output — the denylist and the 3-hit floor are the
  script's job, and duplicating them means two places to keep correct.
- Guessing a tool name for an empty slot instead of omitting it.
- Piping a partial map into `set-toolmap` — it replaces the stored
  object, so a fragment silently erases every slot it omits.
- Caching a binding when the MCP errored — a wrong binding is silent and
  long-lived.
- Binding to JIRA without checking for open GitHub `sdlc:task` issues.
- Creating a memory file on an install that has no memory directory.
