# `bin/sdlc-backend.sh` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the deterministic shell utility that answers "which ticket backend does this repo use?" — repo identity, the binding cache, JIRA-key sniffing, and the JIRA-MCP-configured check — with a unit test per acceptance criterion.

**Architecture:** One executable bash script (`bin/sdlc-backend.sh`) with a subcommand dispatcher, plus one test script. All JSON in and out goes through `jq` (already a hard README requirement). The cache is a single global file whose location is `${SDLC_HOME:-$HOME/.claude/sdlc}/repos.json`, so tests point `SDLC_HOME` at a temp dir and never touch the developer's real cache. Every write is temp-file + `mv`.

**Tech Stack:** Bash (`set -u` only, matching every other script in this repo), `jq`, `git`, GNU `grep`/`sed`/`awk`. No test framework — the script prints `passed=N failed=M` and exits non-zero on failure, like every other `tests/test-*.sh`.

## Global Constraints

- **This is issue #2 / spec §T1.** Scope is exactly `bin/sdlc-backend.sh` and `tests/test-sdlc-backend.sh`. Out of scope: "any MCP interaction; any skill edits". Do not touch `skills/`, `README.md`, `.claude-plugin/plugin.json`, or `hooks/hooks.json`.
- **House style:** `#!/usr/bin/env bash`; `set -u` only — *never* `set -euo pipefail` (no script in this repo uses it); mode `100755`; `printf '%s' "$var" | jq -r '...'` for JSON parsing; `jq -cn`/`jq -c` for JSON emission.
- **Deliberate divergence from `hooks/`:** hooks fail *open* with silent `exit 0`. This is a CLI whose exit codes are its interface — it must fail *loudly* on stderr. `exit 3` outside a git repo is a spec requirement, not a fail-open case.
- **The `resolve` JSON keys are a cross-task contract** consumed later by T3–T7 (five skills). They are frozen as exactly: `repo`, `action`, `backend`, `project`, `cloud_id`, `site`, `toolmap`.
- **The `action` vocabulary is frozen** as exactly: `use-github`, `use-jira`, `bind-needed`. (verbatim from spec "Backend resolution" table)
- **Cache schema is co-owned with T2's bind procedure.** Top-level keys: `version` (always `1`), `jira_toolmap`, `repos`. Per-repo keys: `backend`, `project`, `cloud_id`, `site`, `bound_at`, `source`. (verbatim from the spec's JSON block)
- **The no-JIRA-MCP path must write nothing.** "it costs one bash call — no probe, no prompt, no file read, and **no cache write**, so installing a JIRA MCP later still produces the bind prompt." (verbatim from spec)
- **Denylist, verbatim from spec:** `UTF`, `ISO`, `RFC`, `CVE`, `SHA`, `MD`, `AES`, `RSA`, `TLS`, `SSL`, `HTTP`, `UTC`, `GMT`, `X86`, `ARM`, `PEP`, `IPV`.
- **Sniff pattern, verbatim from spec:** `[A-Z][A-Z0-9]{1,9}-[0-9]+` over the last **500** commit subjects and bodies plus local and remote branch names. Candidates below **3** hits are not proposed.

## File Structure

| File | Responsibility |
|---|---|
| `bin/sdlc-backend.sh` (create, 100755) | Everything. Subcommand dispatch + repo key + cache + MCP detection + sniff. Single file because every piece shares the cache path and repo key helpers, and the whole thing is ~200 lines — splitting it would mean sourcing a lib, which no script in this repo does. |
| `tests/test-sdlc-backend.sh` (create, 100755) | One test file, sections mirroring the 9 acceptance criteria. Picked up automatically by README's `tests/test-*.sh` glob — no registration needed. |

Tasks 1–4 each append their own section to the *same* test file. That is intentional: the repo has one test file per subject, not per function.

---

### Task 1: Repo identity — normalization, worktree collapse, fallback key

**Files:**
- Create: `bin/sdlc-backend.sh`
- Create: `tests/test-sdlc-backend.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `repo_key()` → prints the normalized key on stdout, returns 3 when not in a git repo. `normalize_remote <url>` → prints `host/owner/name`. Tasks 2–4 all call `repo_key`.

**Covers acceptance criteria:** "All four remote URL forms normalize to one `host/owner/name` key"; "A worktree resolves to the same key as its main repo; a no-origin repo gets a stable `git-common-dir` fallback key"; the `exits 3 outside a git repo` half of criterion 1.

- [ ] **Step 1: Write the failing test**

Create `tests/test-sdlc-backend.sh`:

```bash
#!/usr/bin/env bash
# bin/sdlc-backend.sh — repo identity, binding cache, MCP gating, key sniffing.
# SDLC_HOME and HOME are both redirected into $tmp so the suite can never
# read or write the developer's real cache or MCP config.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
SUT="$here/../bin/sdlc-backend.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SDLC_HOME="$tmp/sdlc"
export HOME="$tmp"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { # want got desc
  [ "$1" = "$2" ] && ok "$3" || bad "$3 (want '$1' got '$2')"
}

mkrepo() { # dir [origin-url] -> initialized repo with one commit
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  [ $# -ge 2 ] && git -C "$d" remote add origin "$2"
  return 0
}

# --- repo key: four remote URL forms collapse to one key ----------------
i=0
for url in "git@github.com:a/b.git" \
           "https://github.com/a/b" \
           "https://github.com/a/b/" \
           "ssh://git@github.com/a/b.git"; do
  i=$((i+1)); r="$tmp/form$i"; mkrepo "$r" "$url"
  got=$(cd "$r" && "$SUT" resolve | jq -r '.repo')
  eq "github.com/a/b" "$got" "remote form $i normalizes ($url)"
done

# --- repo key: worktree collapses to its main repo ----------------------
wtmain="$tmp/wtmain"; mkrepo "$wtmain" "git@github.com:a/b.git"
git -C "$wtmain" worktree add -q "$tmp/wtlinked" -b feat >/dev/null 2>&1
mainkey=$(cd "$wtmain" && "$SUT" resolve | jq -r '.repo')
wtkey=$(cd "$tmp/wtlinked" && "$SUT" resolve | jq -r '.repo')
eq "$mainkey" "$wtkey" "worktree resolves to same key as main repo"

# --- repo key: no-origin fallback is stable and worktree-collapsing -----
noremote="$tmp/noremote"; mkrepo "$noremote"
k1=$(cd "$noremote" && "$SUT" resolve | jq -r '.repo')
k2=$(cd "$noremote" && "$SUT" resolve | jq -r '.repo')
eq "$k1" "$k2" "no-origin fallback key is stable across calls"
case "$k1" in path:/*) ok "no-origin key uses path: prefix" ;;
             *) bad "no-origin key not a path: key (got '$k1')" ;; esac
git -C "$noremote" worktree add -q "$tmp/nowt" -b feat >/dev/null 2>&1
k3=$(cd "$tmp/nowt" && "$SUT" resolve | jq -r '.repo')
eq "$k1" "$k3" "no-origin worktree collapses to main repo key"

# --- outside a git repo -> exit 3 ---------------------------------------
outside="$tmp/notarepo"; mkdir -p "$outside"
(cd "$outside" && "$SUT" resolve >/dev/null 2>&1); rc=$?
eq "3" "$rc" "resolve exits 3 outside a git repo"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

Then `chmod +x tests/test-sdlc-backend.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-sdlc-backend.sh`
Expected: FAIL — every case fails because `bin/sdlc-backend.sh` does not exist yet (`jq -r '.repo'` gets empty input). Final line shows `failed=` a non-zero count.

- [ ] **Step 3: Write minimal implementation**

Create `bin/sdlc-backend.sh`:

```bash
#!/usr/bin/env bash
# Deterministic backend resolution for the sdlc pipeline: repo identity,
# the per-repo binding cache, the git-history scan for JIRA keys, and the
# check for whether a JIRA MCP is configured at all. No MCP interaction
# happens here — the model does that, gated on this script's `action`.
#
# Unlike hooks/*.sh (which fail open with a silent exit 0), this is a CLI:
# exit codes are its interface. 3 = not a git repo, 2 = usage error.
set -u

CACHE_DIR="${SDLC_HOME:-$HOME/.claude/sdlc}"
CACHE="$CACHE_DIR/repos.json"

die() { printf 'sdlc-backend: %s\n' "$1" >&2; exit "${2:-1}"; }

normalize_remote() { # <url> -> host/owner/name
  local u="$1" host rest
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  # scp-style (git@host:owner/name) has no scheme; turn its colon into a
  # slash so both shapes can share one parser below.
  if ! printf '%s' "$u" | grep -qE '^[a-zA-Z][a-zA-Z0-9+.-]*://'; then
    u="${u/:/\/}"
  fi
  u="${u#*://}"
  host="${u%%/*}"; rest="${u#*/}"
  host="${host#*@}"          # drop userinfo, never touching the path
  u="$host/$rest"
  u="${u%.git}"
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  printf '%s\n' "$u"
}

repo_key() { # -> normalized key on stdout; return 3 outside a git repo
  git rev-parse --git-dir >/dev/null 2>&1 || return 3
  local url common parent
  url=$(git remote get-url origin 2>/dev/null)
  if [ -n "$url" ]; then
    normalize_remote "$url"
  else
    # --git-common-dir points a linked worktree at its MAIN repo's .git,
    # so every worktree of a remote-less repo shares one key.
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    parent=$(cd "$common/.." 2>/dev/null && pwd -P) || return 3
    printf 'path:%s\n' "$parent"
  fi
}

cmd_resolve() {
  local key; key=$(repo_key) || exit 3
  jq -cn --arg k "$key" '{repo:$k}'
}

case "${1:-}" in
  resolve) shift; cmd_resolve "$@" ;;
  "") die "usage: sdlc-backend.sh <resolve|sniff|set|unset|set-toolmap|get-toolmap>" 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
```

Then `chmod +x bin/sdlc-backend.sh`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-sdlc-backend.sh`
Expected: PASS — `passed=9 failed=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/sdlc-backend.sh tests/test-sdlc-backend.sh
git commit -m "feat(backend): repo key normalization with worktree collapse

Four remote URL forms collapse to one host/owner/name key; a remote-less
repo falls back to a git-common-dir path key, which resolves a linked
worktree to its main repository. Exit 3 outside a git repo."
```

---

### Task 2: The binding cache — set/unset/toolmap round trips, atomic writes

**Files:**
- Modify: `bin/sdlc-backend.sh` (add cache helpers + four subcommands; extend the dispatcher `case`)
- Modify: `tests/test-sdlc-backend.sh` (append a cache section before the final two lines)

**Interfaces:**
- Consumes: `repo_key()` from Task 1.
- Produces: `cache_read()` → prints the cache JSON, or `{"version":1,"repos":{}}` when absent/malformed. `cache_write()` → reads JSON on stdin, replaces the cache atomically. Subcommands `set`, `unset`, `set-toolmap`, `get-toolmap`. Task 3's `cmd_resolve` reads through `cache_read`.

**Covers acceptance criteria:** "`set`/`unset`/`set-toolmap`/`get-toolmap` round-trip through `${SDLC_HOME:-$HOME/.claude/sdlc}/repos.json` with atomic temp-file writes"; "Absent or malformed `repos.json` is treated as empty rather than fatal".

- [ ] **Step 1: Write the failing test**

Insert this section into `tests/test-sdlc-backend.sh` immediately BEFORE the final `echo "passed=..."` line:

```bash
# --- cache: set -> resolve round trip -----------------------------------
cr="$tmp/cacherepo"; mkrepo "$cr" "git@github.com:a/cache.git"
(cd "$cr" && "$SUT" set --backend jira --project PROJ \
   --cloud-id CID --site https://acme.atlassian.net --source git-sniff-confirmed)
out=$(cd "$cr" && "$SUT" resolve)
eq "jira"  "$(printf '%s' "$out" | jq -r '.backend')"  "set --backend jira round-trips"
eq "PROJ"  "$(printf '%s' "$out" | jq -r '.project')"  "set --project round-trips"
eq "CID"   "$(printf '%s' "$out" | jq -r '.cloud_id')" "set --cloud-id round-trips"
eq "https://acme.atlassian.net" "$(printf '%s' "$out" | jq -r '.site')" \
   "set --site round-trips"

# the cache carries the co-owned schema T2's bind procedure reads back
eq "1" "$(jq -r '.version' "$SDLC_HOME/repos.json")" "cache records version 1"
eq "git-sniff-confirmed" \
   "$(jq -r '.repos["github.com/a/cache"].source' "$SDLC_HOME/repos.json")" \
   "cache records bind source"

# --- cache: unbound repo reports backend null ---------------------------
ub="$tmp/unbound"; mkrepo "$ub" "git@github.com:a/unbound.git"
eq "null" "$(cd "$ub" && "$SUT" resolve | jq -r '.backend')" \
   "unbound repo reports backend null"

# --- cache: unset clears the binding ------------------------------------
(cd "$cr" && "$SUT" unset)
eq "null" "$(cd "$cr" && "$SUT" resolve | jq -r '.backend')" "unset clears binding"

# --- cache: toolmap round trip (global, not per-repo) -------------------
printf '%s' '{"server":"atlassian","ops":{"create_issue":"mcp__atlassian__createJiraIssue"}}' \
  | (cd "$cr" && "$SUT" set-toolmap)
eq "mcp__atlassian__createJiraIssue" \
   "$(cd "$cr" && "$SUT" get-toolmap | jq -r '.ops.create_issue')" \
   "toolmap round-trips"
eq "atlassian" "$(cd "$ub" && "$SUT" get-toolmap | jq -r '.server')" \
   "toolmap is global across repos"

# --- cache: atomic writes leave no temp droppings -----------------------
eq "0" "$(find "$SDLC_HOME" -name '.repos.json.*' | wc -l)" \
   "no temp files left behind after writes"

# --- cache: malformed repos.json is treated as empty, not fatal ---------
printf 'not json at all{{{' > "$SDLC_HOME/repos.json"
out=$(cd "$ub" && "$SUT" resolve 2>/dev/null); rc=$?
eq "0"    "$rc" "malformed cache is not fatal"
eq "null" "$(printf '%s' "$out" | jq -r '.backend')" "malformed cache reads as empty"
(cd "$cr" && "$SUT" set --backend github) 2>/dev/null
eq "github" "$(cd "$cr" && "$SUT" resolve | jq -r '.backend')" \
   "a write over a malformed cache repairs it"

# --- cache: absent repos.json is treated as empty, not fatal ------------
rm -rf "$SDLC_HOME"
out=$(cd "$ub" && "$SUT" resolve 2>/dev/null); rc=$?
eq "0"    "$rc" "absent cache is not fatal"
eq "null" "$(printf '%s' "$out" | jq -r '.backend')" "absent cache reads as empty"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-sdlc-backend.sh`
Expected: FAIL — `sdlc-backend: unknown command: set` on stderr, and the `.backend`/`.project` lookups return empty because `cmd_resolve` still emits only `{"repo":...}`.

- [ ] **Step 3: Write minimal implementation**

Add these helpers to `bin/sdlc-backend.sh` after `repo_key()`:

```bash
cache_read() { # -> cache JSON; absent or malformed reads as empty
  if [ -f "$CACHE" ] && jq -e . "$CACHE" >/dev/null 2>&1; then
    cat "$CACHE"
  else
    printf '{"version":1,"repos":{}}\n'
  fi
}

cache_write() { # stdin: JSON -> atomically replace the cache
  local tmpf
  mkdir -p "$CACHE_DIR" || die "cannot create $CACHE_DIR"
  tmpf=$(mktemp "$CACHE_DIR/.repos.json.XXXXXX") || die "cannot create temp file"
  if cat > "$tmpf" && jq -e . "$tmpf" >/dev/null 2>&1; then
    mv -f "$tmpf" "$CACHE"
  else
    rm -f "$tmpf"; die "refusing to write malformed cache"
  fi
}

cmd_set() {
  local backend="" project="" cloud_id="" site="" source="user-selected"
  while [ $# -gt 0 ]; do
    case "$1" in
      --backend)  backend="${2:-}";  shift 2 ;;
      --project)  project="${2:-}";  shift 2 ;;
      --cloud-id) cloud_id="${2:-}"; shift 2 ;;
      --site)     site="${2:-}";     shift 2 ;;
      --source)   source="${2:-}";   shift 2 ;;
      *) die "set: unknown flag: $1" 2 ;;
    esac
  done
  case "$backend" in
    github|jira) ;;
    *) die "set: --backend must be github or jira" 2 ;;
  esac
  local key; key=$(repo_key) || exit 3
  cache_read | jq \
    --arg k "$key" --arg b "$backend" --arg p "$project" --arg c "$cloud_id" \
    --arg s "$site" --arg src "$source" --arg d "$(date +%F)" \
    '.version = 1
     | .repos = (.repos // {})
     | .repos[$k] = ({backend: $b, bound_at: $d, source: $src}
         + (if $p == "" then {} else {project:  $p} end)
         + (if $c == "" then {} else {cloud_id: $c} end)
         + (if $s == "" then {} else {site:     $s} end))' \
    | cache_write
}

cmd_unset() {
  local key; key=$(repo_key) || exit 3
  cache_read | jq --arg k "$key" '.version = 1 | .repos = ((.repos // {}) | del(.[$k]))' \
    | cache_write
}

cmd_set_toolmap() { # stdin: the tool map object
  local tm; tm=$(cat)
  printf '%s' "$tm" | jq -e . >/dev/null 2>&1 || die "set-toolmap: stdin is not valid JSON" 2
  cache_read | jq --argjson tm "$tm" '.version = 1 | .jira_toolmap = $tm' | cache_write
}

cmd_get_toolmap() { cache_read | jq -c '.jira_toolmap // {}'; }
```

Extend the dispatcher `case` to:

```bash
case "${1:-}" in
  resolve)      shift; cmd_resolve "$@" ;;
  set)          shift; cmd_set "$@" ;;
  unset)        shift; cmd_unset "$@" ;;
  set-toolmap)  shift; cmd_set_toolmap "$@" ;;
  get-toolmap)  shift; cmd_get_toolmap "$@" ;;
  "") die "usage: sdlc-backend.sh <resolve|sniff|set|unset|set-toolmap|get-toolmap>" 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
```

And widen `cmd_resolve` so the cache fields it just learned to store come back out:

```bash
cmd_resolve() {
  local key; key=$(repo_key) || exit 3
  cache_read | jq -c --arg k "$key" \
    '{repo:     $k,
      backend:  (.repos[$k].backend  // null),
      project:  (.repos[$k].project  // null),
      cloud_id: (.repos[$k].cloud_id // null),
      site:     (.repos[$k].site     // null),
      toolmap:  (.jira_toolmap       // null)}'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-sdlc-backend.sh`
Expected: PASS — `passed=24 failed=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/sdlc-backend.sh tests/test-sdlc-backend.sh
git commit -m "feat(backend): binding cache with atomic writes

set/unset/set-toolmap/get-toolmap round-trip through
\${SDLC_HOME:-\$HOME/.claude/sdlc}/repos.json. Writes go temp-file + mv so a
killed session cannot truncate the cache; absent or malformed JSON reads as
empty rather than failing."
```

---

### Task 3: `action` gating — JIRA MCP detection and the three-way branch

**Files:**
- Modify: `bin/sdlc-backend.sh` (add `jira_mcp_configured()`; add `action` to `cmd_resolve`)
- Modify: `tests/test-sdlc-backend.sh` (append a gating section before the final two lines)

**Interfaces:**
- Consumes: `repo_key()` (Task 1), `cache_read()` (Task 2).
- Produces: the final `resolve` contract — `{repo, action, backend, project, cloud_id, site, toolmap}` where `action` ∈ `use-github` | `use-jira` | `bind-needed`. This is what T3–T7 branch on.

**Covers acceptance criteria:** "`resolve` prints JSON with repo key, `action`, backend, project, cloud id, site, and tool map"; "`action` is `use-github` when no `jira`/`atlassian` MCP server is configured … and that path writes nothing to the cache"; "`action` is `bind-needed` when such a server is configured and the repo is unbound, and `use-jira` when the repo is bound to JIRA".

- [ ] **Step 1: Write the failing test**

Insert this section into `tests/test-sdlc-backend.sh` immediately BEFORE the final `echo "passed=..."` line:

```bash
# --- action gating ------------------------------------------------------
# HOME is $tmp, so $HOME/.claude.json is this suite's fixture.
gate="$tmp/gate"; mkrepo "$gate" "git@github.com:a/gate.git"
rm -rf "$SDLC_HOME" "$HOME/.claude.json"

# (a) no JIRA-looking MCP anywhere -> use-github, and NOTHING is written
out=$(cd "$gate" && "$SUT" resolve)
eq "use-github" "$(printf '%s' "$out" | jq -r '.action')" \
   "no MCP configured -> use-github"
eq "false" "$([ -e "$SDLC_HOME/repos.json" ] && echo true || echo false)" \
   "use-github path writes nothing to the cache"

# the full resolve contract T3-T7 depend on
for k in repo action backend project cloud_id site toolmap; do
  [ "$(printf '%s' "$out" | jq "has(\"$k\")")" = "true" ] \
    && ok "resolve emits key '$k'" || bad "resolve missing key '$k'"
done

# (b) an unrelated MCP server does not trip the heuristic
printf '%s' '{"mcpServers":{"postgres":{"command":"x"}}}' > "$HOME/.claude.json"
eq "use-github" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "unrelated MCP server -> still use-github"

# (c) a JIRA-looking server in ~/.claude.json + unbound repo -> bind-needed
printf '%s' '{"mcpServers":{"Atlassian":{"command":"x"}}}' > "$HOME/.claude.json"
eq "bind-needed" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "atlassian server (case-insensitive) + unbound -> bind-needed"
eq "false" "$([ -e "$SDLC_HOME/repos.json" ] && echo true || echo false)" \
   "bind-needed path also writes nothing"

# (d) detection also reads ~/.claude.json's per-project mcpServers
printf '%s' '{"projects":{"/somewhere":{"mcpServers":{"jira-cloud":{"command":"x"}}}}}' \
  > "$HOME/.claude.json"
eq "bind-needed" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "per-project mcpServers entry is detected"

# (e) detection also reads a project-local .mcp.json at the repo root
printf '%s' '{"mcpServers":{"postgres":{"command":"x"}}}' > "$HOME/.claude.json"
printf '%s' '{"mcpServers":{"my-jira":{"command":"x"}}}' > "$gate/.mcp.json"
eq "bind-needed" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "project .mcp.json is detected"
# ...and from a subdirectory of the repo, not just its root
mkdir -p "$gate/sub"
eq "bind-needed" "$(cd "$gate/sub" && "$SUT" resolve | jq -r '.action')" \
   "project .mcp.json is found from a subdirectory"
rm -f "$gate/.mcp.json"

# (f) bound repo wins over config in both directions
printf '%s' '{"mcpServers":{"atlassian":{"command":"x"}}}' > "$HOME/.claude.json"
(cd "$gate" && "$SUT" set --backend jira --project PROJ)
eq "use-jira" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "bound to jira -> use-jira"
(cd "$gate" && "$SUT" set --backend github)
eq "use-github" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "explicitly bound to github -> use-github despite MCP present"
rm -f "$HOME/.claude.json"
eq "use-jira" "$(cd "$cr" && "$SUT" set --backend jira >/dev/null 2>&1; \
                 cd "$cr" && "$SUT" resolve | jq -r '.action')" \
   "bound to jira -> use-jira even with no MCP configured"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-sdlc-backend.sh`
Expected: FAIL — every `.action` lookup returns `null` (the key does not exist yet), and `resolve emits key 'action'` fails.

- [ ] **Step 3: Write minimal implementation**

Add to `bin/sdlc-backend.sh` after `cache_read`/`cache_write`:

```bash
jira_mcp_configured() { # 0 if any configured MCP server name looks like JIRA
  local names="" root
  if [ -f "$HOME/.claude.json" ]; then
    names="$names
$(jq -r '[(.mcpServers // {} | keys[]),
          (.projects  // {} | to_entries[] | .value.mcpServers // {} | keys[])]
         | .[]' "$HOME/.claude.json" 2>/dev/null)"
  fi
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$root" ] && [ -f "$root/.mcp.json" ]; then
    names="$names
$(jq -r '.mcpServers // {} | keys[]' "$root/.mcp.json" 2>/dev/null)"
  fi
  printf '%s' "$names" | grep -qiE 'jira|atlassian'
}
```

Replace `cmd_resolve` with the final version:

```bash
cmd_resolve() {
  local key backend action
  key=$(repo_key) || exit 3
  backend=$(cache_read | jq -r --arg k "$key" '.repos[$k].backend // ""')
  # A recorded binding always wins; the MCP sniff only decides what to do
  # about a repo nobody has bound yet. No branch here writes to the cache.
  case "$backend" in
    jira)   action="use-jira" ;;
    github) action="use-github" ;;
    *)      if jira_mcp_configured; then action="bind-needed"
            else action="use-github"; fi ;;
  esac
  cache_read | jq -c --arg k "$key" --arg a "$action" \
    '{repo:     $k,
      action:   $a,
      backend:  (.repos[$k].backend  // null),
      project:  (.repos[$k].project  // null),
      cloud_id: (.repos[$k].cloud_id // null),
      site:     (.repos[$k].site     // null),
      toolmap:  (.jira_toolmap       // null)}'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-sdlc-backend.sh`
Expected: PASS — `passed=41 failed=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/sdlc-backend.sh tests/test-sdlc-backend.sh
git commit -m "feat(backend): action gating on configured JIRA MCP servers

resolve now emits the full contract the pipeline skills branch on. A repo
with no jira/atlassian-looking MCP server gets use-github without a single
cache write, so installing a JIRA MCP later still produces the bind prompt."
```

---

### Task 4: `sniff` — ranked JIRA-key candidates from git history

**Files:**
- Modify: `bin/sdlc-backend.sh` (add `cmd_sniff`; add `sniff` to the dispatcher)
- Modify: `tests/test-sdlc-backend.sh` (append a sniff section before the final two lines)

**Interfaces:**
- Consumes: `repo_key()` (Task 1) purely as the git-repo guard.
- Produces: `sniff` → zero or more lines of `KEY COUNT`, highest count first. T2's bind procedure reads this to populate its prompt.

**Covers acceptance criteria:** "`sniff` ranks JIRA keys by frequency over 500 commits and branch names, applies the denylist, and suppresses candidates under 3 hits".

- [ ] **Step 1: Write the failing test**

Insert this section into `tests/test-sdlc-backend.sh` immediately BEFORE the final `echo "passed=..."` line:

```bash
# --- sniff --------------------------------------------------------------
sn="$tmp/sniff"; mkrepo "$sn" "git@github.com:a/sniff.git"
c() { git -C "$sn" commit -q --allow-empty -m "$1"; }
c "PROJ-1 first";  c "PROJ-2 second"; c "PROJ-3 third"; c "PROJ-4 fourth"
c "MINOR-1 a";     c "MINOR-2 b";     c "MINOR-3 c"
c "RARE-1 only once"; c "RARE-2 twice"          # 2 hits: under the floor
c "fix UTF-8 handling and CVE-2024-1234 and RFC-3339"
c "another UTF-8 fix";  c "more UTF-8 and CVE-2024-9999 and RFC-2119"
c "yet more UTF-8, CVE-2024-1111, RFC-1234"
sniff_out=$(cd "$sn" && "$SUT" sniff)

eq "PROJ" "$(printf '%s\n' "$sniff_out" | awk 'NR==1{print $1}')" \
   "sniff ranks the most frequent key first"
eq "4"    "$(printf '%s\n' "$sniff_out" | awk 'NR==1{print $2}')" \
   "sniff reports the hit count"
eq "MINOR" "$(printf '%s\n' "$sniff_out" | awk 'NR==2{print $1}')" \
   "sniff ranks the second key second"
printf '%s\n' "$sniff_out" | grep -q '^RARE ' \
  && bad "sniff proposed a candidate under the 3-hit floor" \
  || ok "sniff suppresses candidates under 3 hits"
for d in UTF CVE RFC; do
  printf '%s\n' "$sniff_out" | grep -q "^$d " \
    && bad "sniff proposed denylisted key $d" \
    || ok "sniff rejects denylisted $d"
done

# branch names count toward the ranking, not just commit subjects
git -C "$sn" branch "BRANCHY-1" >/dev/null 2>&1
git -C "$sn" branch "BRANCHY-2" >/dev/null 2>&1
git -C "$sn" branch "BRANCHY-3" >/dev/null 2>&1
(cd "$sn" && "$SUT" sniff) | grep -q '^BRANCHY 3$' \
  && ok "sniff counts branch names" || bad "sniff ignored branch names"

# a key mentioned only in a commit BODY still counts
git -C "$sn" commit -q --allow-empty -m "subject" -m "BODYKEY-1 BODYKEY-2 BODYKEY-3"
(cd "$sn" && "$SUT" sniff) | grep -q '^BODYKEY 3$' \
  && ok "sniff reads commit bodies" || bad "sniff ignored commit bodies"

# a repo with no keys at all sniffs clean and does not error
clean="$tmp/cleanrepo"; mkrepo "$clean" "git@github.com:a/clean.git"
sn_clean=$(cd "$clean" && "$SUT" sniff); rc=$?
eq "0"  "$rc" "sniff exits 0 on a repo with no candidates"
eq ""   "$sn_clean" "sniff prints nothing when there are no candidates"

# sniff respects the git-repo guard
(cd "$outside" && "$SUT" sniff >/dev/null 2>&1); rc=$?
eq "3" "$rc" "sniff exits 3 outside a git repo"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-sdlc-backend.sh`
Expected: FAIL — `sdlc-backend: unknown command: sniff` on stderr; `sniff_out` is empty so the ranking assertions fail.

- [ ] **Step 3: Write minimal implementation**

Add to `bin/sdlc-backend.sh`:

```bash
# Keys that look like JIRA projects but never are. Without this, UTF-8,
# CVE-2024-1234 and RFC-3339 all read as project keys.
SNIFF_DENYLIST='UTF|ISO|RFC|CVE|SHA|MD|AES|RSA|TLS|SSL|HTTP|UTC|GMT|X86|ARM|PEP|IPV'

cmd_sniff() {
  git rev-parse --git-dir >/dev/null 2>&1 || exit 3
  { git log -n 500 --format='%s%n%b' 2>/dev/null
    git branch -a --format='%(refname:short)' 2>/dev/null
  } | grep -oE '\b[A-Z][A-Z0-9]{1,9}-[0-9]+\b' \
    | sed 's/-[0-9]*$//' \
    | grep -vxE "$SNIFF_DENYLIST" \
    | sort | uniq -c | sort -rn \
    | awk '$1 >= 3 { print $2, $1 }'
}
```

Add `sniff)  shift; cmd_sniff "$@" ;;` to the dispatcher `case`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-sdlc-backend.sh`
Expected: PASS — `passed=54 failed=0`, exit 0.

- [ ] **Step 5: Run the whole suite and commit**

Run: `for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done`
Expected: no output (every suite exits 0).

```bash
git add bin/sdlc-backend.sh tests/test-sdlc-backend.sh
git commit -m "feat(backend): sniff ranked JIRA key candidates from history

Scans 500 commit subjects and bodies plus local and remote branch names for
[A-Z][A-Z0-9]{1,9}-[0-9]+, ranks by frequency, drops a denylist of
lookalikes (UTF-8, CVE-2024-1234, RFC-3339) and anything under 3 hits."
```

---

## Self-Review

**1. Spec coverage** — all nine acceptance criteria map to a task:

| Acceptance criterion | Task |
|---|---|
| `resolve` prints JSON with all 7 fields; exit 3 outside a git repo | 3 (fields) + 1 (exit 3) |
| `use-github` when no JIRA MCP configured, no cache write | 3 |
| `bind-needed` when configured + unbound; `use-jira` when bound | 3 |
| Four remote URL forms → one key | 1 |
| Worktree → main repo key; no-origin fallback | 1 |
| `sniff` ranking, denylist, 3-hit floor | 4 |
| `set`/`unset`/`set-toolmap`/`get-toolmap` round trip, atomic writes | 2 |
| Absent or malformed `repos.json` → empty, not fatal | 2 |
| `tests/test-sdlc-backend.sh` covers every criterion and passes | 1–4 |

**2. Placeholder scan** — no unfinished-work markers, no vague "add error handling", no "similar to Task N" back-references; every code step carries complete runnable code.

**3. Type consistency** — `repo_key`, `normalize_remote`, `cache_read`, `cache_write`, `jira_mcp_configured`, `cmd_resolve`, `cmd_set`, `cmd_unset`, `cmd_set_toolmap`, `cmd_get_toolmap`, `cmd_sniff` are spelled identically at every definition and call site. `cmd_resolve` is written three times (Tasks 1, 2, 3), each a stated full replacement rather than a diff, so a worker reading only one task still gets a coherent function. The `resolve` key set and `action` vocabulary match the Global Constraints and the spec table exactly.

**Deliberate deviations from the spec, both narrowing:**
- `cache_write` validates its stdin is JSON before `mv`. The spec only requires atomicity; refusing to install a malformed cache is strictly safer and is what makes "a write over a malformed cache repairs it" testable.
- `cmd_set` accepts an undocumented `--source` flag. The spec's cache schema has a `source` field with two values (`git-sniff-confirmed`, `user-selected`) and no other way to set it; T2's bind procedure needs to write it.
