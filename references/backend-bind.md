# Binding a repo to a ticket backend

Read this file **only** when `bin/sdlc-backend.sh resolve` reported
`action: bind-needed`, which happens at most once per repo. It means a
JIRA-looking MCP server is configured **and** this repo has no recorded
binding. It does **not** mean JIRA is reachable — step 1 establishes
that.

Every worktree of a repo shares one binding, because the cache is keyed
by the origin remote rather than by working-directory path.

Work through the steps in order, then continue the run with
`references/backend-jira.md` (or with the skill's inline `gh` commands,
if the answer was GitHub).

## 1. Probe the tool map

The map is **global to the machine**, not per repo, so this runs once
ever rather than once per project. Different servers name their tools
differently — the official Atlassian remote server uses
`createJiraIssue`, the community `mcp-atlassian` uses
`jira_create_issue`, and the MCP prefix depends on the local server
name — so no hardcoded table would survive contact.

Check for an existing map first:

```bash
bin/sdlc-backend.sh get-toolmap
```

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
         "list_projects": "mcp__atlassian__getVisibleJiraProjects"}}
```

**Omit a slot with no matching tool; never guess a name.** A missing
`link_issues` has a defined fallback in `backend-jira.md`; an invented
tool name just fails later, further from its cause.

Write it back exactly once:

```bash
printf '%s' "$toolmap_json" | bin/sdlc-backend.sh set-toolmap
```

If the MCP server is present but erroring or unauthenticated, **stop and
report**. Write nothing — no tool map, no binding — so the next run
re-asks instead of inheriting a half-made decision.

## 2. Capture the cloud id and site

Call `toolmap.ops.list_projects` once. Keep two values from the
response alongside the project list:

- **cloud id** — the Atlassian cloud identifier
- **site** — the base URL, e.g. `https://acme.atlassian.net`

Both are recorded at bind time so `ticket_url` can build
`<site>/browse/<REF>` forever after without a live call.

If `list_projects` is unavailable or returns nothing, **stop and
report**. Binding a project whose site URL is unknown produces tickets
nobody can link to.

## 3. Sniff the repo's history for a project key

```bash
bin/sdlc-backend.sh sniff
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
bin/sdlc-backend.sh set --backend jira --project PROJ \
  --cloud-id "$CLOUD_ID" --site "https://acme.atlassian.net" \
  --source git-sniff-confirmed

# a different project was chosen from the list
bin/sdlc-backend.sh set --backend jira --project OTHER \
  --cloud-id "$CLOUD_ID" --site "https://acme.atlassian.net" \
  --source user-selected

# stay on GitHub
bin/sdlc-backend.sh set --backend github --source user-selected
```

**Choosing GitHub here *is* cached** — it is an explicit decision, unlike
a machine with no JIRA MCP, which is never asked and never written. To
make a repo ask again:

```bash
bin/sdlc-backend.sh unset
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
| `list_projects` unavailable or empty | Stop and report — no cloud id and site means no `ticket_url`. |
| `sniff` returns nothing | Not an error. Drop the history line from the prompt and offer the project list plus GitHub. |
| A tool slot has no matching tool | Omit the slot. `backend-jira.md` defines the fallback for a missing `link_issues` and stops for a missing `search`. |
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
- Caching a binding when the MCP errored — a wrong binding is silent and
  long-lived.
- Binding to JIRA without checking for open GitHub `sdlc:task` issues.
- Creating a memory file on an install that has no memory directory.
