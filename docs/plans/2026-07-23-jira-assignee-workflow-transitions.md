# JIRA Assignee and Workflow Transitions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the JIRA adapter so `claim` sets an assignee and drives a human-confirmed "start" workflow transition, and so a merged ticket's status is closed via a human-confirmed "done" transition offered through `sdlc:cleanup`, both lazily discovered against a live ticket and cached per repo.
**Architecture:** `bin/sdlc-backend.sh` gains two new subcommands (`set-assignee`, `set-workflow`) that merge new fields into the existing per-repo cache entry without disturbing `backend`/`project`/`cloud_id`/`site`, and `resolve` echoes those fields back (`null` until discovered). `references/backend-jira.md` and `references/backend-bind.md` document three new toolmap slots and a single lazy-discovery procedure that both `claim` and `sdlc:cleanup`'s new close-on-merge step reference by name. `skills/cleanup/SKILL.md` gets one narrow, explicitly-gated exception to its "never mutates remote state" invariant.
**Tech Stack:** POSIX shell (`bin/sdlc-backend.sh`) + `jq`; Markdown reference/skill files that are prose specifications read by an agent, not executed code; POSIX shell regression tests (`tests/*.sh`).

## Global Constraints

- This plan covers T1–T4 of `docs/2026-07-23-jira-assignment-and-status-transitions-design.md`'s Decomposition only. T5 (a manual end-to-end run against a live JIRA project) is explicitly OUT OF SCOPE for this coding session — see the note at the end of this document.
- Strict dependency chain: T1 → T2 → T3 → T4. Do not start a task before its predecessor's tests pass.
- New CLI verbs are `set-assignee` (flag `--account-id`) and `set-workflow` (flags `--start`, `--done`, independently optional). These exact spellings are used everywhere across all four tasks — never `set_assignee`, `assign`, or `set_workflow`.
- Every new cache write to an existing repo entry MUST merge (`(.repos[$k] // {}) + {...}`), never replace (`cmd_set`'s existing full-replace behavior is untouched and must not be copied for the two new subcommands).
- `mark_in_review` stays label-only. Do not add a third transition anywhere in this plan.
- The GitHub path is untouched: no file under this plan changes `gh` command counts below their existing floors in `tests/validate-skills.sh`.
- Shell added to `bin/sdlc-backend.sh` and its tests must stay BSD/macOS-portable (no GNU-only flags, no `\b`), matching the file's existing style.
- `tests/test-handoff-worktree.sh` has one pre-existing, unrelated failure on `main` (a macOS `/private/var` vs `/var` path-symlink quirk). Do not attempt to fix it as part of this work; Task 4's final verification step names it explicitly so it isn't mistaken for a regression.

---

### Task 1: Extend `bin/sdlc-backend.sh`'s cache schema for assignee and workflow transitions

**Files:**
- Modify: `bin/sdlc-backend.sh:185-275` (insert two new `cmd_*` functions after `cmd_set` at line 185, before `cmd_unset` at line 187; modify `cmd_resolve` at lines 256-263; modify the dispatch `case` at lines 266-275)
- Test: `tests/test-sdlc-backend.sh` (insert new blocks; extend the existing `has()` loop at lines 265-268; extend the error-path block at lines 475-517)

**Interfaces:**
- Consumes: nothing from an earlier task (T1 has no dependency).
- Produces: CLI subcommands `set-assignee --account-id <id>` and `set-workflow [--start <name>] [--done <name>]`; cache fields `repos[<key>].assignee_account_id` (string) and `repos[<key>].workflow` (object with optional `start`/`done` string keys); `resolve` output keys `assignee_account_id` (string or `null`) and `workflow` (object or `null`). T2, T3 reference these subcommand names and output keys verbatim.

- [ ] **Step 1: Write the failing tests**

In `tests/test-sdlc-backend.sh`, insert the following block immediately after line 116 (after the existing line `eq "null" "$(cd "$ub" && "$SUT" resolve | jq -r '.backend')" "unbound repo reports backend null"` and before the `--- cache: unset clears the binding ---` comment at line 118). At this point in the file both `$cr` (bound to `backend jira, project PROJ, cloud_id CID, site https://acme.atlassian.net`) and `$ub` (unbound) already exist, and `$cr`'s binding is not mutated by anything later until the deliberate corruption test — so this is the right place to test merge-not-clobber before that corruption test reassigns `$cr` to `backend github`.

```bash
# --- cache: set-assignee / set-workflow merge into an existing binding --
# assignee round-trips without disturbing anything set --backend jira wrote
(cd "$cr" && "$SUT" set-assignee --account-id ACCT1)
out=$(cd "$cr" && "$SUT" resolve)
eq "ACCT1" "$(printf '%s' "$out" | jq -r '.assignee_account_id')" \
   "set-assignee --account-id round-trips"
eq "jira"  "$(printf '%s' "$out" | jq -r '.backend')"  \
   "set-assignee does not clobber backend"
eq "PROJ"  "$(printf '%s' "$out" | jq -r '.project')"  \
   "set-assignee does not clobber project"
eq "CID"   "$(printf '%s' "$out" | jq -r '.cloud_id')" \
   "set-assignee does not clobber cloud_id"
eq "https://acme.atlassian.net" "$(printf '%s' "$out" | jq -r '.site')" \
   "set-assignee does not clobber site"

# workflow round-trips, both fields set together
(cd "$cr" && "$SUT" set-workflow --start "In Progress" --done "Done")
out=$(cd "$cr" && "$SUT" resolve)
eq "In Progress" "$(printf '%s' "$out" | jq -r '.workflow.start')" \
   "set-workflow --start round-trips"
eq "Done" "$(printf '%s' "$out" | jq -r '.workflow.done')" \
   "set-workflow --done round-trips"
eq "jira"  "$(printf '%s' "$out" | jq -r '.backend')"  \
   "set-workflow does not clobber backend"
eq "PROJ"  "$(printf '%s' "$out" | jq -r '.project')"  \
   "set-workflow does not clobber project"
eq "ACCT1" "$(printf '%s' "$out" | jq -r '.assignee_account_id')" \
   "set-workflow does not clobber a previously-set assignee_account_id"

# setting --start alone later preserves the already-cached --done
(cd "$cr" && "$SUT" set-workflow --start "Building")
out=$(cd "$cr" && "$SUT" resolve)
eq "Building" "$(printf '%s' "$out" | jq -r '.workflow.start')" \
   "a later set-workflow --start alone updates only start"
eq "Done" "$(printf '%s' "$out" | jq -r '.workflow.done')" \
   "...and preserves the previously-cached done (merge, not clobber)"

# --- cache: assignee_account_id and workflow read as null when unset ----
out=$(cd "$ub" && "$SUT" resolve)
eq "null" "$(printf '%s' "$out" | jq -r '.assignee_account_id')" \
   "unset assignee_account_id reads null"
eq "null" "$(printf '%s' "$out" | jq -r '.workflow')" \
   "unset workflow reads null"

# --- set-assignee / set-workflow error paths -----------------------------
sw="$tmp/setworkflow"; mkrepo "$sw" "git@github.com:a/setworkflow.git"
(cd "$sw" && tmo 5 "$SUT" set-assignee --account-id) >/dev/null 2>&1
eq "2" "$?" "set-assignee --account-id with no value exits 2, does not hang"
(cd "$sw" && "$SUT" set-assignee >/dev/null 2>&1)
eq "2" "$?" "set-assignee with no --account-id at all exits 2"
(cd "$sw" && "$SUT" set-assignee --nope x >/dev/null 2>&1)
eq "2" "$?" "set-assignee with an unknown flag exits 2"
(cd "$sw" && "$SUT" set-workflow >/dev/null 2>&1)
eq "2" "$?" "set-workflow with neither --start nor --done exits 2"
(cd "$sw" && "$SUT" set-workflow --nope x >/dev/null 2>&1)
eq "2" "$?" "set-workflow with an unknown flag exits 2"
(cd "$sw" && tmo 5 "$SUT" set-workflow --start) >/dev/null 2>&1
eq "2" "$?" "set-workflow --start with no value exits 2, does not hang"
(cd "$sw" && "$SUT" set-workflow --start OK >/dev/null 2>&1)
eq "0" "$?" "set-workflow --start alone succeeds"
```

Also extend the existing `has()` loop at `tests/test-sdlc-backend.sh:265-268` from:

```bash
for k in repo action backend project cloud_id site toolmap; do
```

to:

```bash
for k in repo action backend project cloud_id site toolmap assignee_account_id workflow; do
```

Finally, add two exit-3 checks to the "documented error exit codes" block, immediately after the existing pair at lines 513-516 (`"set outside a git repo exits 3"` / `"unset outside a git repo exits 3"`):

```bash
(cd "$outside" && "$SUT" set-assignee --account-id X >/dev/null 2>&1)
eq "3" "$?" "set-assignee outside a git repo exits 3"
(cd "$outside" && "$SUT" set-workflow --start X >/dev/null 2>&1)
eq "3" "$?" "set-workflow outside a git repo exits 3"
```

- [ ] **Step 2: Run the test, verify it fails**

Run:

```bash
bash tests/test-sdlc-backend.sh
```

Expected: the suite errors out or reports failures for every new assertion, because `set-assignee` and `set-workflow` are not yet recognized subcommands (`sdlc-backend: unknown command: set-assignee`, exit 2 — which happens to make the two "exits 2" error-path assertions pass vacuously for the wrong reason, but every round-trip assertion and the two "exits 3" and "well-formed... succeeds" assertions fail). The final line reads `passed=<N> failed=<M>` with `M > 0` and the script's own exit status is non-zero (`[ "$fail" -eq 0 ]` at the last line).

- [ ] **Step 3: Write the minimal implementation**

In `bin/sdlc-backend.sh`, insert the following two functions immediately after `cmd_set`'s closing `}` at line 185 and before `cmd_unset` at line 187:

```bash
cmd_set_assignee() {
  local account_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --account-id)
        [ $# -ge 2 ] || die "set-assignee: $1 requires a value" 2 ;;
    esac
    case "$1" in
      --account-id) account_id="${2:-}"; shift 2 ;;
      *) die "set-assignee: unknown flag: $1" 2 ;;
    esac
  done
  [ -n "$account_id" ] || die "set-assignee: --account-id is required" 2
  local key; key=$(repo_key) || exit 3
  lock_acquire; cache_quarantine
  cache_read | jq \
    --arg k "$key" --arg a "$account_id" \
    '.version = 1
     | .repos = (.repos // {})
     | .repos[$k] = ((.repos[$k] // {}) + {assignee_account_id: $a})' \
    | cache_write
}

cmd_set_workflow() {
  local start="" done_val="" have_start=0 have_done=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --start|--done)
        [ $# -ge 2 ] || die "set-workflow: $1 requires a value" 2 ;;
    esac
    case "$1" in
      --start) start="${2:-}";    have_start=1; shift 2 ;;
      --done)  done_val="${2:-}"; have_done=1;  shift 2 ;;
      *) die "set-workflow: unknown flag: $1" 2 ;;
    esac
  done
  if [ "$have_start" -eq 0 ] && [ "$have_done" -eq 0 ]; then
    die "set-workflow: at least one of --start or --done is required" 2
  fi
  local key; key=$(repo_key) || exit 3
  lock_acquire; cache_quarantine
  cache_read | jq \
    --arg k "$key" --arg start "$start" --arg done_v "$done_val" \
    '.version = 1
     | .repos = (.repos // {})
     | .repos[$k] = ((.repos[$k] // {})
         + {workflow: ((.repos[$k].workflow // {})
             + (if $start  == "" then {} else {start: $start}  end)
             + (if $done_v == "" then {} else {done:  $done_v} end))})' \
    | cache_write
}
```

Modify `cmd_resolve`'s output `jq` at lines 256-263 from:

```bash
  printf '%s' "$cache" | jq -c --arg k "$key" --arg a "$action" \
    '{repo:     $k,
      action:   $a,
      backend:  (.repos[$k].backend  // null),
      project:  (.repos[$k].project  // null),
      cloud_id: (.repos[$k].cloud_id // null),
      site:     (.repos[$k].site     // null),
      toolmap:  (.jira_toolmap       // null)}'
```

to:

```bash
  printf '%s' "$cache" | jq -c --arg k "$key" --arg a "$action" \
    '{repo:     $k,
      action:   $a,
      backend:  (.repos[$k].backend             // null),
      project:  (.repos[$k].project             // null),
      cloud_id: (.repos[$k].cloud_id            // null),
      site:     (.repos[$k].site                // null),
      toolmap:  (.jira_toolmap                  // null),
      assignee_account_id: (.repos[$k].assignee_account_id // null),
      workflow: (.repos[$k].workflow            // null)}'
```

Modify the dispatch `case` at lines 266-275 from:

```bash
case "${1:-}" in
  resolve)      shift; cmd_resolve "$@" ;;
  sniff)        shift; cmd_sniff "$@" ;;
  set)          shift; cmd_set "$@" ;;
  unset)        shift; cmd_unset "$@" ;;
  set-toolmap)  shift; cmd_set_toolmap "$@" ;;
  get-toolmap)  shift; cmd_get_toolmap "$@" ;;
  "") die "usage: sdlc-backend.sh <resolve|sniff|set|unset|set-toolmap|get-toolmap>" 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
```

to:

```bash
case "${1:-}" in
  resolve)       shift; cmd_resolve "$@" ;;
  sniff)         shift; cmd_sniff "$@" ;;
  set)           shift; cmd_set "$@" ;;
  unset)         shift; cmd_unset "$@" ;;
  set-toolmap)   shift; cmd_set_toolmap "$@" ;;
  get-toolmap)   shift; cmd_get_toolmap "$@" ;;
  set-assignee)  shift; cmd_set_assignee "$@" ;;
  set-workflow)  shift; cmd_set_workflow "$@" ;;
  "") die "usage: sdlc-backend.sh <resolve|sniff|set|unset|set-toolmap|get-toolmap|set-assignee|set-workflow>" 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
```

- [ ] **Step 4: Run the test, verify it passes**

Run:

```bash
bash tests/test-sdlc-backend.sh
```

Expected: final line reads `passed=<N> failed=0` and the script exits 0. Every assertion added in Step 1 reports `ok:`, including the merge/no-clobber checks and both new "exits 3 outside a git repo" checks.

- [ ] **Step 5: Commit**

```bash
git add bin/sdlc-backend.sh tests/test-sdlc-backend.sh
git commit -m "feat: cache assignee_account_id and workflow transitions in sdlc-backend.sh"
```

---

### Task 2: Extend the bind and adapter reference files with the three new slots and the lazy-discovery procedure

**Files:**
- Modify: `references/backend-bind.md:53-77` (toolmap JSON example, adapter-slot count, omit-a-slot prose), `references/backend-bind.md:288-300` (Red flags)
- Modify: `references/backend-jira.md:71-74` (adapter slot count in "Resolving tools"), `references/backend-jira.md:350-355` (`list_open_tasks` normalization note), `references/backend-jira.md:372-375` (`get_state`), `references/backend-jira.md:382-419` (rewrite `claim`, and insert the new "Discovering a workflow transition" subsection immediately before it), `references/backend-jira.md:480-486` ("What the pipeline never does"), `references/backend-jira.md:492-505` (Failure modes table), `references/backend-jira.md:507-529` (Red flags)
- Test: none (Markdown reference files have no executable test; T1's cache round-trip and T3's `validate-skills.sh` grep are the machine-verifiable coverage this design names — see the design doc's own "Testing" section)

**Interfaces:**
- Consumes: `sdlc-backend.sh set-assignee --account-id <id>` and `sdlc-backend.sh set-workflow --start <name> --done <name>` from Task 1; `resolve`'s `assignee_account_id` and `workflow` output keys from Task 1.
- Produces: the toolmap slot names `get_current_user`, `get_transitions`, `transition_issue`; the named procedure "Discovering a workflow transition" in `references/backend-jira.md`, which Task 3's `skills/cleanup/SKILL.md` edit references by that exact heading name rather than repeating its steps.

This task edits prose specifications, not executable code, so there is no red/green test cycle. Each step below is a verification (grep-based, matching the repo's existing self-check style for reference-file edits) rather than a unit test — apply the edit, then run the verification, exactly as steps 2/4 do for the other tasks.

- [ ] **Step 1: Write the verification checks (run once now to confirm they fail, i.e. the old text is still there)**

```bash
grep -c 'get_current_user\|get_transitions\|transition_issue' references/backend-bind.md
grep -c 'get_current_user\|get_transitions\|transition_issue' references/backend-jira.md
grep -q 'Discovering a workflow transition' references/backend-jira.md && echo found || echo missing
grep -q 'never assigns an assignee\|The adapter never sets an\|assigned is always .false. on JIRA.: the claim is the' references/backend-jira.md && echo stale-still-present || echo stale-gone
```

- [ ] **Step 2: Run the checks, verify the pre-edit state**

Run the four commands above. Expected: the first two print `0` (the three new slot names do not appear anywhere yet), the third prints `missing`, and the fourth prints `stale-still-present` (the exact current text `**On JIRA the label alone is the claim. The adapter never sets an assignee.**` is still at `references/backend-jira.md:401-402`).

- [ ] **Step 3: Write the reference-file edits**

**3a. `references/backend-bind.md` — add the three slots to the JSON example.**

Replace the fenced JSON block at lines 53-64:

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

with:

```json
{"server": "atlassian",
 "probed_at": "YYYY-MM-DD",
 "ops": {"create_issue":     "mcp__atlassian__createJiraIssue",
         "search":           "mcp__atlassian__searchJiraIssuesUsingJql",
         "get_issue":        "mcp__atlassian__getJiraIssue",
         "edit_issue":       "mcp__atlassian__editJiraIssue",
         "comment":          "mcp__atlassian__addCommentToJiraIssue",
         "link_issues":      "mcp__atlassian__createJiraIssueLink",
         "get_current_user": "mcp__atlassian__atlassianUserInfo",
         "get_transitions":  "mcp__atlassian__getTransitionsForJiraIssue",
         "transition_issue": "mcp__atlassian__transitionJiraIssue",
         "list_projects":    "mcp__atlassian__getVisibleJiraProjects",
         "list_sites":       "mcp__atlassian__getAccessibleAtlassianResources"}}
```

Replace the paragraph at lines 66-70:

```markdown
Six of these — `create_issue`, `search`, `get_issue`, `edit_issue`,
`comment`, `link_issues` — are what the adapter runs on. `list_projects`
and `list_sites` are used only at bind time, by step 2 of this file, and
either may be missing on a server pinned to one fixed site. The names
above are one server's — they are illustrative, not a table to copy.
```

with:

```markdown
Nine of these — `create_issue`, `search`, `get_issue`, `edit_issue`,
`comment`, `link_issues`, `get_current_user`, `get_transitions`,
`transition_issue` — are what the adapter runs on. `list_projects` and
`list_sites` are used only at bind time, by step 2 of this file, and
either may be missing on a server pinned to one fixed site. The names
above are one server's — they are illustrative, not a table to copy.
```

Replace the omit-a-slot paragraph at lines 75-77:

```markdown
**Omit a slot with no matching tool; never guess a name.** A missing
`link_issues` has a defined fallback in `backend-jira.md`; an invented
tool name just fails later, further from its cause.
```

with:

```markdown
**Omit a slot with no matching tool; never guess a name.** A missing
`link_issues` has a defined fallback in `backend-jira.md`; an invented
tool name just fails later, further from its cause. A missing
`get_current_user` has a defined fallback too — `lookupJiraAccountId`
with a human-supplied search string, reachable through the same
`search`-style resolution — see `claim` in `backend-jira.md`. A missing
`get_transitions` or `transition_issue` has no fallback: `claim`'s
assignee step can still run, but its start-transition step cannot: that
is covered by `claim`'s own fail-soft rule (report, never block the
label), not by a substitute tool.
```

Add one bullet to the Red flags section at `references/backend-bind.md:288-300`, after the existing bullet ending "Creating a memory file on an install that has no memory directory.":

```markdown
- Failing the whole bind because `get_current_user`, `get_transitions`,
  or `transition_issue` has no matching tool — omit the slot; `claim`
  degrades those steps gracefully, per `backend-jira.md`.
```

**3b. `references/backend-jira.md` — update the adapter-slot count in "Resolving tools".**

Replace the sentence at lines 71-72:

```markdown
Resolve every operation below through
`toolmap.ops.<slot>`; the six adapter slots are `create_issue`, `search`,
`get_issue`, `edit_issue`, `comment`, and `link_issues`. (`list_projects`
```

with:

```markdown
Resolve every operation below through
`toolmap.ops.<slot>`; the nine adapter slots are `create_issue`, `search`,
`get_issue`, `edit_issue`, `comment`, `link_issues`, `get_current_user`,
`get_transitions`, and `transition_issue`. (`list_projects`
```

**3c. Reconcile the `list_open_tasks` normalization note at lines 350-355.**

Replace:

```markdown
The caller is always a subagent. **Normalize inside that subagent** to the
node shape the main loop expects — `{ref, title, dependsOn, inProgress,
inReview, assigned, ops, createdAt}` — where `dependsOn` is the list of
inbound "is blocked by" refs and `inProgress` / `inReview` / `ops` are
label tests. **`assigned` is always `false` on JIRA**: the claim is the
`sdlc:in-progress` label, not the assignee field — see `claim` below.
Raw JIRA issue-link JSON must never reach the main loop;
avoiding that is the entire reason the gather step is delegated.
```

with:

```markdown
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
```

**3d. Reconcile `get_state` at lines 372-375.**

Replace:

```markdown
The assignee field comes back too, and it is fine to show a human. It is
**not** part of the state this adapter acts on: `list_open_tasks`
normalizes `assigned` to `false` unconditionally, and readiness gates on
the `sdlc:in-progress` label — see `claim` below.
```

with:

```markdown
The assignee field comes back too — `claim` (below) may have set it —
and it is fine to show a human. It is **not** part of the state this
adapter acts on for readiness: `list_open_tasks` normalizes `assigned` to
`false` unconditionally, and readiness gates on the `sdlc:in-progress`
label — see `claim` below.
```

**3e. Insert the shared "Discovering a workflow transition" subsection immediately before `### `claim`` (currently line 382), and rewrite `claim` itself.**

Replace the whole span from line 382 (`### \`claim\``) through line 419 (the closing ` ``` ` of `claim`'s original code fence) with:

```markdown
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
```

**3f. Narrow "What the pipeline never does" at lines 480-486.**

Replace:

```markdown
**It never drives a JIRA workflow transition.** Status names and
transition graphs vary per project, transitions fail in ways that are
tedious to recover from, and a half-transitioned ticket is worse than an
untouched one. `sdlc:in-progress` and `sdlc:in-review` are labels for
exactly this reason.

A human moves and closes the ticket when they merge. Approval in
`sdlc:review` therefore ends: *"Ready for your merge decision — the
ticket stays open until you move it."*
```

with:

```markdown
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
```

**3g. Append every row from the design doc's Failure modes table to the existing table at lines 492-505.**

Insert these six rows immediately after the last existing row (`| \`cloud_id\` is null and the tool schema requires a cloud id | ... |`):

```markdown
| Cached `workflow.start`/`workflow.done` name absent from live transitions | Stop and report the expected name and the live options; do not guess a substitute. Offer to re-discover. |
| `get_current_user` slot unset and no fallback resolves an account | Skip assignee only; still apply the label; say so once per session, not once per ticket. |
| `transition_issue` call errors (permission, workflow condition unmet) | Stop and report; the label change (already applied, or applied alongside) stands regardless — labels are the pipeline's authoritative claim signal, not the Jira status. |
| Ticket already in a state the cached transition can't reach (e.g. reopened past "start") | Not a failure — skip the transition, say so, continue. |
| JIRA MCP erroring/unauthenticated | Stop and report, matching existing adapter policy — never fall back to GitHub. |
| `cleanup`'s merged-PR map has no JIRA-shaped branch (`sdlc/<ref>-`) | No close-on-merge line item is offered; existing branch-only behavior is unchanged. |
```

(The fifth row duplicates the table's existing first row in substance. It is appended verbatim anyway, per this plan's instruction to carry every row from the design doc's Failure modes section unmodified — a future edit could dedupe the two, but that is not this task's job.)

**3h. Update Red flags at lines 507-529.**

Replace the bullet at (currently) line 528:

```markdown
- Gating readiness on an empty assignee field — on JIRA the claim is the
  `sdlc:in-progress` label; the adapter never assigns anyone.
```

with:

```markdown
- Gating readiness on an empty assignee field — on JIRA the claim is the
  `sdlc:in-progress` label; an assignee, when `claim` sets one, is
  information for a human, not a gate.
```

Add two new bullets to the end of the Red flags section (after "Reading this file on the GitHub path at all."):

```markdown
- Substituting a guessed transition name when the cached one is not among
  `get_transitions`'s live options — stop and report instead, per
  "Discovering a workflow transition".
- Blocking the label add on an assignee-lookup or transition failure —
  both are fail-soft; the label is not.
```

- [ ] **Step 4: Run the checks, verify they pass**

```bash
grep -c 'get_current_user\|get_transitions\|transition_issue' references/backend-bind.md
grep -c 'get_current_user\|get_transitions\|transition_issue' references/backend-jira.md
grep -q 'Discovering a workflow transition' references/backend-jira.md && echo found || echo missing
grep -q 'The adapter never sets an assignee' references/backend-jira.md && echo stale-still-present || echo stale-gone
bash tests/validate-skills.sh
```

Expected: the first two print a number greater than `0`; the third prints `found`; the fourth prints `stale-gone`; and `tests/validate-skills.sh` still ends `passed=<N> failed=0` (this task does not touch any skill file, so its existing assertions are unaffected — this is a regression check, not new coverage for this task).

- [ ] **Step 5: Commit**

```bash
git add references/backend-bind.md references/backend-jira.md
git commit -m "docs: document assignee and workflow-transition ops in the JIRA adapter"
```

---

### Task 3: Add the close-on-merge step to `sdlc:cleanup`

**Files:**
- Modify: `skills/cleanup/SKILL.md:17-20` (intro invariant), `skills/cleanup/SKILL.md:30-125` (step 2 scan — new bullet), `skills/cleanup/SKILL.md:136-140` (step 4 confirmation gate), `skills/cleanup/SKILL.md:141-154` (step 5 execute), `skills/cleanup/SKILL.md:155-156` (step 6 report), `skills/cleanup/SKILL.md:158-166` (Safety invariants), `skills/cleanup/SKILL.md:168-195` (Red flags)
- Test: `tests/validate-skills.sh` (append one new assertion, in the file's existing `ok`/`bad`/`grep -q` style)

**Interfaces:**
- Consumes: `sdlc-backend.sh resolve`'s `action`/`workflow` output (Task 1); `references/backend-jira.md`'s `get_state` operation and "Discovering a workflow transition" procedure (Task 2), which this task references by name rather than repeating.
- Produces: the confirmable step-4 line item `"close JIRA <ref>"`; the exact substring `except a confirmed JIRA ticket transition, gated exactly like a branch deletion`, which Task 4's full-suite run and this task's own `validate-skills.sh` assertion both key on.

- [ ] **Step 1: Write the failing test**

Append the following block to `tests/validate-skills.sh`, immediately before its final `echo "passed=$pass failed=$fail"` line (currently line 89):

```bash
# --- cleanup's remote-mutation carve-out for a confirmed JIRA close -----
# spec T3: skills/cleanup/SKILL.md's "never modifies remote state"
# invariant needs an explicit, narrow carve-out for a confirmed JIRA
# transition, worded identically to the design doc so it is traceable.
carve_out="except a confirmed JIRA ticket transition, gated exactly like a branch deletion"
cf="$root/skills/cleanup/SKILL.md"
if grep -qF "$carve_out" "$cf"; then
  ok "cleanup: states the JIRA-transition carve-out to its remote-state invariant"
else
  bad "cleanup: missing the JIRA-transition carve-out to its remote-state invariant"
fi
```

- [ ] **Step 2: Run the test, verify it fails**

Run:

```bash
bash tests/validate-skills.sh
```

Expected: every existing assertion still reports `ok:`, and the new one reports `FAIL: cleanup: missing the JIRA-transition carve-out to its remote-state invariant`. The final line reads `passed=<N> failed=1` and the script exits non-zero.

- [ ] **Step 3: Write the minimal implementation**

**3a. Intro invariant, `skills/cleanup/SKILL.md:17-20`.**

Replace:

```markdown
It never MUTATES anything beyond the local workspace: it does not push,
does not delete remote branches, does not modify any remote state, and
never deletes uncommitted work. It DOES make one read-only remote query
(`gh pr list`, step 2) to learn which branches already have merged PRs.
Create a todo per checklist item.
```

with:

```markdown
It never MUTATES anything beyond the local workspace — except a
confirmed JIRA ticket transition, gated exactly like a branch deletion:
it does not push, does not delete remote branches, does not modify any
other remote state, and never deletes uncommitted work. It DOES make one
read-only remote query (`gh pr list`, step 2) to learn which branches
already have merged PRs. Create a todo per checklist item.
```

**3b. Step 2 scan — add the JIRA-status sub-step, `skills/cleanup/SKILL.md:30-125`.**

Insert a new top-level bullet into step 2's scan list, immediately after the existing `- **Local branches**, ...` bullet block ends (after the line "Always exclude: the current branch, the base branch, and any branch checked out in a worktree that is not itself being removed." — currently line 125) and before step 3 begins:

```markdown
   - **JIRA ticket status for branches classified PR merged.** Only when
     `bin/sdlc-backend.sh resolve` (run once for this whole step, not once
     per branch) reports `action: use-jira`; on any other action, skip this
     sub-step entirely — there is no JIRA ticket to resolve.

     For each branch classified **PR merged** above, parse `<ref>` from
     `sdlc/<ref>-<slug>`. If `<ref>` is not a bare integer (a JIRA key,
     e.g. `PROJ-123`), resolve the ticket with the adapter's `get_state`
     operation (`references/backend-jira.md`) to confirm it is not already
     Done (`statusCategory != Done`). Already Done means no close-on-merge
     item is needed for that branch.

     If it is not yet Done and `workflow.done` is uncached (from the same
     `resolve` output), run "Discovering a workflow transition"
     (`references/backend-jira.md`) against this specific ticket — it will
     be in whatever state PR-merged tickets sit in (e.g. "In Review"),
     which is a valid state to probe transitions from — and cache the name
     via `sdlc-backend.sh set-workflow --done <name>`.

     This scan step only discovers and resolves state; it transitions
     nothing. The transition itself happens in step 5, after the step 4
     confirmation.
```

**3c. Step 4 confirmation gate, `skills/cleanup/SKILL.md:136-140`.**

Replace:

```markdown
4. **Confirmation gate (the human gate).** Present the deletable
   worktrees, branches, and stray handoffs and ask the user to confirm — all, or a
   selected subset. Delete NOTHING before an explicit yes. Deletable-but-
   unverified branches are confirmed ONE AT A TIME, with their commits
   shown — a blanket "yes, all" never sweeps them up.
```

with:

```markdown
4. **Confirmation gate (the human gate).** Present the deletable
   worktrees, branches, and stray handoffs and ask the user to confirm — all, or a
   selected subset. Delete NOTHING before an explicit yes. Deletable-but-
   unverified branches are confirmed ONE AT A TIME, with their commits
   shown — a blanket "yes, all" never sweeps them up.

   For a branch with a pending close-on-merge item (from step 2's JIRA
   ticket status check), present **"close JIRA `<ref>`"** as its own
   confirmable line item, next to — never merged into — that branch's
   deletion confirmation. Confirmed ONE AT A TIME, the same way
   deletable-but-unverified branches already are: a blanket "yes, all"
   never sweeps up a ticket transition any more than it sweeps up an
   unverified branch deletion.
```

**3d. Step 5 execute, `skills/cleanup/SKILL.md:141-154`.**

Replace:

```markdown
5. **Execute** only what was confirmed:
   - Worktrees: `git worktree remove <path>` (add `--force` ONLY for a
     dirty worktree the user explicitly approved), then `git worktree
     prune`.
   - Branches: `git branch -d <branch>` for merged into base; `git branch
     -D <branch>` for PR-merged, for upstream-gone, and for deletable-but-
     unverified — none of those is guaranteed to be an ancestor of the
     local base. State the reason when you do ("PR #13 squash-merged as
     f3948f5").
   - **Stray handoffs:** delete confirmed `.handoff-*.md` files. When a
     worktree is removed, also delete any handoff that lived in it or that
     names its path in `## Refs`, so the pointer never outlives its target.
   - **Uncommitted files: reported only, never deleted** — leave them for
     the human.
```

with:

```markdown
5. **Execute** only what was confirmed:
   - Worktrees: `git worktree remove <path>` (add `--force` ONLY for a
     dirty worktree the user explicitly approved), then `git worktree
     prune`.
   - Branches: `git branch -d <branch>` for merged into base; `git branch
     -D <branch>` for PR-merged, for upstream-gone, and for deletable-but-
     unverified — none of those is guaranteed to be an ancestor of the
     local base. State the reason when you do ("PR #13 squash-merged as
     f3948f5").
   - **JIRA ticket close:** for each confirmed "close JIRA `<ref>`" item,
     call `toolmap.ops.transition_issue` with the id matching the cached
     `workflow.done` name among that ticket's live `get_transitions`
     options (per "Discovering a workflow transition",
     `references/backend-jira.md`). State the ticket ref and the
     transition name when you do it. This is the one remote-state
     mutation this skill ever performs, and it happens only here, after
     the step 4 gate — never during the read-only scan.
   - **Stray handoffs:** delete confirmed `.handoff-*.md` files. When a
     worktree is removed, also delete any handoff that lived in it or that
     names its path in `## Refs`, so the pointer never outlives its target.
   - **Uncommitted files: reported only, never deleted** — leave them for
     the human.
```

**3e. Step 6 report, `skills/cleanup/SKILL.md:155-156`.**

Replace:

```markdown
6. **Report** exactly what was removed, and restate any dirty trees or
   review-manually branches left for the user to handle.
```

with:

```markdown
6. **Report** exactly what was removed and which JIRA tickets were
   closed, and restate any dirty trees or review-manually branches left
   for the user to handle.
```

**3f. Safety invariants, `skills/cleanup/SKILL.md:158-166`, first bullet.**

Replace:

```markdown
- Remote state is never mutated. The single `gh pr list` call is
  read-only; nothing is pushed and no remote branch is deleted.
```

with:

```markdown
- Remote state is never mutated, except a confirmed JIRA ticket
  transition, gated exactly like a branch deletion. The single `gh pr
  list` call is read-only; nothing is pushed and no remote branch is
  deleted; the one JIRA transition confirmed at the step 4 gate is the
  sole exception.
```

**3g. Red flags, `skills/cleanup/SKILL.md:168-195`.**

Add a new bullet at the end of the Red flags section (after "Silently skipping the worktree you are standing in — say you cannot remove it and where to re-run from; do not pretend it is clean."):

```markdown
- Transitioning a JIRA ticket without the step 4 confirmation, or
  bundling it into a blanket branch-deletion "yes" — it gets its own
  confirmable line item, one at a time, same as an unverified branch.
```

- [ ] **Step 4: Run the test, verify it passes**

Run:

```bash
bash tests/validate-skills.sh
```

Expected: final line reads `passed=<N> failed=0`, script exits 0, and the new assertion reports `ok: cleanup: states the JIRA-transition carve-out to its remote-state invariant`.

- [ ] **Step 5: Commit**

```bash
git add skills/cleanup/SKILL.md tests/validate-skills.sh
git commit -m "feat: close-on-merge JIRA transition in sdlc:cleanup, gated like a branch deletion"
```

---

### Task 4: Update docs and version

**Files:**
- Modify: `README.md:97-122` ("Ticket backends" section)
- Modify: `.claude-plugin/plugin.json:4` (`version`)
- Modify: `.claude-plugin/marketplace.json:16` (`plugins[0].version`)
- Test: full suite (`tests/*.sh`) — no new test file; this task's own step 4 IS the verification

**Interfaces:**
- Consumes: Task 1's `set-assignee`/`set-workflow` subcommands and Task 2/3's adapter and cleanup behavior, described in prose only — no code interface is produced here.
- Produces: nothing later tasks depend on (T4 is the last task in this plan).

- [ ] **Step 1: Write the failing check**

```bash
grep -c 'assignee' README.md
jq -r '.version' .claude-plugin/plugin.json
jq -r '.plugins[0].version' .claude-plugin/marketplace.json
```

- [ ] **Step 2: Run the check, verify the pre-edit state**

Run the three commands above. Expected: `grep -c 'assignee' README.md` prints `0` (the word does not appear in the README yet), and both `jq` calls print `0.6.0`.

- [ ] **Step 3: Write the minimal implementation**

**3a. `README.md:97-122`.** Insert two sentences immediately after the existing sentence "...so the probe runs once, not once per skill." (the end of the second paragraph of "## Ticket backends") and before the paragraph beginning "`tests/validate-skills.sh` enforces the split:":

```markdown
On JIRA, `claim` now also sets the ticket's assignee and drives a
project-specific, human-confirmed "start" workflow transition, and a
merged ticket's status is closed via a similarly confirmed "done"
transition offered through `sdlc:cleanup` — both lazily discovered
against a live ticket rather than configured up front.
```

**3b. `.claude-plugin/plugin.json`.** Change line 4 from:

```json
  "version": "0.6.0",
```

to:

```json
  "version": "0.7.0",
```

**3c. `.claude-plugin/marketplace.json`.** Change line 16 from:

```json
      "version": "0.6.0",
```

to:

```json
      "version": "0.7.0",
```

Do not touch `metadata.version` (line 9, `"1.0.0"`) — that is the marketplace schema version, unrelated to this plugin's release version, and the `39d2dd6` release-commit precedent (`chore: release 0.6.0`) touched only `plugin.json`'s `version` and `marketplace.json`'s `plugins[0].version`, leaving `metadata.version` alone. No `CHANGELOG.md` exists in this repo; do not create one.

- [ ] **Step 4: Run the check, verify it passes, and run the full test suite**

```bash
grep -c 'assignee' README.md
jq -r '.version' .claude-plugin/plugin.json
jq -r '.plugins[0].version' .claude-plugin/marketplace.json
jq -r '.metadata.version' .claude-plugin/marketplace.json
for f in tests/*.sh; do echo "=== $f ==="; bash "$f"; done
```

Expected: `grep -c 'assignee' README.md` prints a number greater than `0`; both plugin-version `jq` calls print `0.7.0`; `metadata.version` still prints `1.0.0` (unchanged). In the full-suite run, every file under `tests/*.sh` ends with `passed=<N> failed=0` and exit 0, **except** `tests/test-handoff-worktree.sh`, which has one pre-existing, unrelated failure on `main` (a macOS `/private/var` vs `/var` path-symlink-normalization quirk in a test assertion). Confirm that failure's assertion text matches the known pre-existing one and that no *other* assertion in that file fails; do not attempt to fix it as part of this task.

- [ ] **Step 5: Commit**

```bash
git add README.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "docs: document assignee/workflow-transition behavior, release 0.7.0"
```

---

## Out of scope: T5 (manual verification)

T5 in the design doc's Decomposition — end-to-end verification against a live JIRA project (claim a real ticket and confirm assignee + status transition, merge its PR and confirm `sdlc:cleanup` offers and executes the close) — is **not** part of this plan. It is manual and not machine-verifiable: bash cannot call MCP tools, the same limitation the original JIRA adapter's T9 named. Once Tasks 1-4 above are merged, run T5 by hand against a real ticket, record the result in the tracking ticket, and file any defect found as a new task. Do not attempt to script or simulate it as part of this coding session.
