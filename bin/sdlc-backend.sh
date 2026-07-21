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
