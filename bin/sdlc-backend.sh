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
  tmpf=$(mktemp -p "$CACHE_DIR") || die "cannot create temp file"
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

case "${1:-}" in
  resolve)      shift; cmd_resolve "$@" ;;
  set)          shift; cmd_set "$@" ;;
  unset)        shift; cmd_unset "$@" ;;
  set-toolmap)  shift; cmd_set_toolmap "$@" ;;
  get-toolmap)  shift; cmd_get_toolmap "$@" ;;
  "") die "usage: sdlc-backend.sh <resolve|sniff|set|unset|set-toolmap|get-toolmap>" 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
