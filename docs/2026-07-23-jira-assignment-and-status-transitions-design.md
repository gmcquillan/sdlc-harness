# JIRA ticket assignment and status transitions

**Date:** 2026-07-23
**Status:** proposed

## Problem

The JIRA adapter (`docs/2026-07-21-jira-ticket-backend-design.md`, shipped in
PR #13) deliberately never sets an assignee and never drives a JIRA workflow
transition. Both constraints were reasoned, not accidental: no user-lookup
tool existed to turn "me" into an Atlassian `accountId`, and guessing a
transition name across projects with differently-named workflows risked a
half-transitioned ticket, which the original design judged worse than an
untouched one.

Both reasons are now stale. The connected Atlassian MCP server exposes
`atlassianUserInfo` (current user), `lookupJiraAccountId` (search fallback),
`getTransitionsForJiraIssue` (lists the transitions actually reachable from a
ticket's current state), and `transitionJiraIssue`. Meanwhile the GitHub path
already does both things this design adds: `implement` step 3 self-assigns
(`gh issue edit --add-assignee "@me"`), and a merged PR auto-closes its
linked issue via `Closes #<n>`. A JIRA-bound ticket has no equivalent — it
sits unassigned unless a human assigns it by hand, and stays open forever
after merge unless a human remembers to close it.

## Scope

**In scope:**
- `claim` (JIRA path only): set the current user as assignee, and transition
  status to a human-confirmed "start" state, in addition to the existing
  `sdlc:in-progress` label.
- Closing a ticket after its linked PR merges: transition status to a
  human-confirmed "done" state. Triggered from `sdlc:cleanup`, which already
  detects merged PRs (`gh pr list --state merged`) and already gates
  mutations behind an explicit human confirmation.
- A lazily-discovered, per-project pair of transition names (`start`,
  `done`) and a per-project assignee `accountId`, cached in the same
  `repos.json` binding entry as `project`/`cloud_id`/`site`.

**Out of scope:**
- `mark_in_review` stays label-only (`sdlc:in-review`) — confirmed with the
  user; a third configured transition wasn't wanted.
- Any change to the GitHub path, or to `create_epic` / `create_task` /
  `link_dependency` / `list_open_tasks` / `get_state` / `comment` /
  `ticket_url`.
- Re-litigating "no workflow transitions" for any state beyond `start` and
  `done`.
- Setting an assignee or transitioning status anywhere except `claim` and
  the new close-on-merge step.

## Why lazy discovery, not upfront configuration

A fresh JIRA project has no sample ticket to probe at bind time, and
`getTransitionsForJiraIssue` is state-dependent — the transitions reachable
from "To Do" differ from those reachable from "In Review". Asking a human to
type a status name blind risks a typo that silently never matches anything.

Instead: the first time an operation needs a not-yet-cached transition, call
`getTransitionsForJiraIssue` on the **actual ticket being acted on**, present
the real options it returns for that ticket's current state, and ask which
one applies. Cache the chosen transition's **name** (not its `id` — ids are
tied to the source state and issue type; names are stable project-wide) in
the repo's binding entry. Every later call re-probes `getTransitionsForJiraIssue`
fresh for the specific ticket in hand — always current, always state-aware —
and looks for the cached name among the returned options.

**If the cached name is not among the live options** (workflow changed, or
the ticket's current state cannot reach it), stop and report which name was
expected and what was actually available. Never substitute a guess. Offer to
re-discover and re-cache.

The same pattern resolves "who am I": call `atlassianUserInfo` once (or, for
a server that exposes no such call, `lookupJiraAccountId` with a
user-provided search string), show the resolved display name for
confirmation, and cache the `accountId`.

## New toolmap slots

Three additions to `toolmap.ops.*`, alongside the seven the original adapter
already probes:

| Slot | Resolves to (official Atlassian server) |
|---|---|
| `get_current_user` | `atlassianUserInfo` |
| `get_transitions` | `getTransitionsForJiraIssue` |
| `transition_issue` | `transitionJiraIssue` |

`get_current_user` may be absent on servers with no "who am I" call — the
fallback is `lookupJiraAccountId` (already reachable through `search`-style
resolution) with a search string the human supplies once. State this
fallback explicitly in `backend-bind.md`; do not fail the whole feature for
its absence, since assignee-setting is a nice-to-have next to the labels
that already gate the pipeline.

## Cache schema addition

`repos.json`'s per-repo entry gains two optional fields, populated the first
time they're discovered rather than at bind time:

```json
{
  "repos": {
    "github.com/sqsp/owner-service": {
      "backend": "jira",
      "project": "DB",
      "cloud_id": "…",
      "site": "https://squarespace.atlassian.net",
      "assignee_account_id": "602294abbe86a000690e4e6f",
      "workflow": { "start": "In Progress", "done": "Done" }
    }
  }
}
```

`workflow.start` / `workflow.done` are absent until first discovered; their
absence is the signal that triggers the discovery prompt, not a separate
"has this been configured" flag.

## Operation changes

**`claim`** (`references/backend-jira.md`), currently a label-only
read-modify-write, gains two steps run alongside the existing label add:

1. If `assignee_account_id` is uncached, resolve via `get_current_user` (or
   the `lookupJiraAccountId` fallback), confirm with the human once, cache
   it. Set the ticket's assignee via `edit_issue`.
2. If `workflow.start` is uncached, call `get_transitions` on this ticket,
   present the live options, ask which one means "start work", cache the
   name. Look for that name among this ticket's live transitions and call
   `transition_issue` with its id. If the ticket is already past that state
   (edge case: reopened work), skip the transition and say so — this is not
   a failure.

Both steps are independent of the label add and of each other: a failure in
one (assignee lookup errors, or the cached transition name is no longer
offered) is reported but does not block the other, and never blocks the
label — the label is what the rest of the pipeline's readiness logic reads.

**Close-on-merge** (`skills/cleanup/SKILL.md`, JIRA-only addition): reuses
the merged-PR map cleanup's step 2 already builds from `gh pr list --state
merged`. For each branch already classified "PR-merged" whose ref matches
`sdlc/<JIRA-key>-<slug>`, resolve the ticket ref, call `get_state` (adapter
op) to confirm it isn't already Done, and if `workflow.done` is cached, add
"close JIRA `<ref>`" as its own confirmable line item next to that branch's
deletion in the step 4 gate — never bundled into a blanket "yes, all" the
way deletable-but-unverified branches already aren't. If `workflow.done` is
uncached, discover it the same way `claim` discovers `workflow.start`,
against this ticket specifically (it will be in whatever state PR-merged
tickets sit in — e.g. "In Review" — which is a valid state to probe
transitions from).

This is the one place this design touches a file outside the adapter:
`cleanup`'s stated invariant "does not modify any remote state" needs an
explicit carve-out — "except a confirmed JIRA ticket transition, gated
exactly like a branch deletion" — spelled out in both the skill's
description and its "Safety invariants" section.

## Failure modes

| Situation | Behavior |
|---|---|
| Cached `workflow.start`/`workflow.done` name absent from live transitions | Stop and report the expected name and the live options; do not guess a substitute. Offer to re-discover. |
| `get_current_user` slot unset and no fallback resolves an account | Skip assignee only; still apply the label; say so once per session, not once per ticket. |
| `transition_issue` call errors (permission, workflow condition unmet) | Stop and report; the label change (already applied, or applied alongside) stands regardless — labels are the pipeline's authoritative claim signal, not the Jira status. |
| Ticket already in a state the cached transition can't reach (e.g. reopened past "start") | Not a failure — skip the transition, say so, continue. |
| JIRA MCP erroring/unauthenticated | Stop and report, matching existing adapter policy — never fall back to GitHub. |
| `cleanup`'s merged-PR map has no JIRA-shaped branch (`sdlc/<ref>-`) | No close-on-merge line item is offered; existing branch-only behavior is unchanged. |

## Testing

Machine-verifiable: `bin/sdlc-backend.sh`'s cache read/write round-trip for
the two new fields, via `tests/test-sdlc-backend.sh` — same style as the
existing `set`/`resolve` round-trip tests. `tests/validate-skills.sh` gains
an assertion that `skills/cleanup/SKILL.md` states the JIRA-transition
carve-out to its "never modifies remote state" invariant.

**Not machine-verifiable** (bash cannot call MCP tools, same limitation the
original adapter's T9 named): the discovery prompts, the assignee set, and
the two transitions need one end-to-end manual run against a real JIRA
ticket — claim one and confirm assignee + status, merge its PR and confirm
`sdlc:cleanup` offers and executes the close — recorded in the tracking
ticket, matching the original adapter's T9 pattern.

## Decomposition

### T1: Extend bin/sdlc-backend.sh cache schema for assignee and workflow transitions
**Acceptance criteria:**
- [ ] `repos.json` schema gains optional `assignee_account_id` and `workflow.{start,done}` fields per repo entry
- [ ] `cmd_set` (or a new subcommand, e.g. `set-workflow` / `set-assignee`) can write these fields into an existing binding without clobbering `backend`/`project`/`cloud_id`/`site`/`source`
- [ ] `resolve` output includes whatever of these fields are cached (or omits them cleanly when absent)
- [ ] Absent fields read as "not yet discovered", not as an error
- [ ] `tests/test-sdlc-backend.sh` covers the round trip and the absent-field case
**Scope:** `bin/sdlc-backend.sh`, `tests/test-sdlc-backend.sh`
**Depends on:** none
**Out of scope:** any MCP interaction; any skill/reference-file edits

### T2: Extend the bind and adapter reference files with the three new slots and the lazy-discovery procedure
**Acceptance criteria:**
- [ ] `references/backend-bind.md` documents probing `get_current_user`, `get_transitions`, `transition_issue`, including the `lookupJiraAccountId` fallback for `get_current_user`
- [ ] `references/backend-jira.md`'s `claim` operation is rewritten per "Operation changes" above: label add (unchanged) plus assignee-set and start-transition, each independently fail-soft
- [ ] The lazy-discovery procedure (probe live options on the actual ticket, ask once, cache the name, re-check on every later call) is written once and referenced by both `claim` and the close-on-merge step, not duplicated
- [ ] Failure modes table gains every row from this design's "Failure modes" section
**Scope:** `references/backend-bind.md`, `references/backend-jira.md`
**Depends on:** T1
**Out of scope:** `skills/cleanup/SKILL.md` (T3); `mark_in_review` (explicitly out of scope for this whole design)

### T3: Add the close-on-merge step to sdlc:cleanup
**Acceptance criteria:**
- [ ] `skills/cleanup/SKILL.md`'s merged-PR detection (step 2) additionally resolves a JIRA ticket ref from any `sdlc/<JIRA-key>-<slug>` branch it classifies PR-merged
- [ ] For such a branch, the step 4 confirmation gate offers "close JIRA `<ref>`" as its own line item, never bundled into a blanket branch-deletion confirmation
- [ ] The skill's "never modifies remote state" invariant is amended with an explicit, narrow carve-out for this confirmed transition
- [ ] `workflow.done` discovery (if uncached) runs against the specific merged ticket, per T2's shared procedure
- [ ] `tests/validate-skills.sh` asserts the carve-out language is present
**Scope:** `skills/cleanup/SKILL.md`, `tests/validate-skills.sh`
**Depends on:** T2
**Out of scope:** any change to worktree/branch deletion logic itself

### T4: Update docs and version
**Acceptance criteria:**
- [ ] README's "Ticket backends" section mentions assignee-setting and the two configured transitions
- [ ] `.claude-plugin/plugin.json` version bump
- [ ] Full test suite passes
**Scope:** `README.md`, `.claude-plugin/plugin.json`
**Depends on:** T3
**Out of scope:** skill logic changes

### T5: End-to-end verification against the live owner-service JIRA project
**Acceptance criteria:**
- [ ] `sdlc:implement` on a real `DB-*` ticket sets assignee and transitions status on claim, discovery prompt appears and the answer is cached
- [ ] After merging that ticket's PR, `sdlc:cleanup` offers and (on confirmation) executes the close transition
- [ ] Results recorded in the tracking ticket; any defect found becomes a new task
**Scope:** manual run; no code changes expected. Label `ops`, exempt from the review flow, per `sdlc:next`'s ops handling.
**Depends on:** T4
**Out of scope:** automated MCP testing, which bash cannot do
