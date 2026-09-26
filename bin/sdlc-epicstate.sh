#!/usr/bin/env bash
# Deterministic state-file arithmetic for sdlc:epic's stacked-PR
# autopilot loop: the skill branches on this script's exit codes and
# stdout, it never computes cap/hop arithmetic or state-file layout
# itself. Same exit-code-is-the-interface contract as sdlc-hopcount.sh.
#
#   init <epic-ref> [--cap N]   create the state file (default cap 30)
#   record <epic-ref> <ticket-ref> <branch> <pr#> <hops>
#                               append a completed ticket, advance the
#                               tip, sum hops against the cap
#   set-status <epic-ref> <status> [detail]
#                               closed vocabulary: done |
#                               stopped:review-tier-b-c | stopped:blocked
#   status <epic-ref>          print the current state, parseable
#
# Exit codes: 3 = not inside a git worktree. 2 = usage error / unknown
# epic (record/set-status/status) / duplicate init / non-numeric --cap
# or hops / invalid epic ref / invalid set-status token. 1 = record
# pushed the running hop total over the cap (state is still persisted).
# 0 = success.
#
# Deliberately unlocked, unlike sdlc-backend.sh's cache: this assumes one
# sdlc:epic run at a time per epic ref, not sdlc-backend.sh's routinely-
# concurrent-across-worktrees usage. A second concurrent writer against
# the same epic ref can lose an update (read-modify-write race). Add
# locking here only if that assumption stops holding.
set -u

DEFAULT_CAP=30

die() { printf 'sdlc-epicstate: %s\n' "$1" >&2; exit "${2:-1}"; }

main_root() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}'
}

sanitize_ref() { # <ref> -> ref with a leading '#' stripped, or fail (2)
  local r="${1#\#}"
  case "$r" in
    ''|*/*) return 1 ;;
  esac
  printf '%s\n' "$r"
}

state_file() { # <epic-ref> -> absolute path (may not exist yet)
  local root ref
  root=$(main_root)
  [ -n "$root" ] || die "not inside a git worktree" 3
  ref=$(sanitize_ref "$1") || die "epic ref must not be empty or contain '/': $1" 2
  printf '%s/.sdlc-epic-%s.md\n' "$root" "$ref"
}

# --- field readers: degrade safely on malformed/missing data, mirroring
# sdlc-hopcount.sh's "missing Hop: line degrades to 0" rule -------------
read_field() { # <file> <heading> -> the single value line under it, or ""
  awk -v h="$2" '
    $0 == "## " h { want=1; next }
    want && /^## / { exit }
    want && NF { print; exit }
  ' "$1"
}

read_stack() { # <file> -> the Stack section's lines, one per line, or nothing
  awk '
    $0 == "## Stack" { want=1; next }
    want && /^## / { exit }
    want && NF { print }
  ' "$1"
}

write_state() { # <file> <epic> <status> <cap> <hops> <tip> <detail-or-""> ; stack lines on stdin
  local f="$1" epic="$2" status="$3" cap="$4" hops="$5" tip="$6" detail="$7"
  local tmpf; tmpf=$(mktemp "$(dirname "$f")/.sdlc-epic-XXXXXX.md") || die "cannot create temp file"
  {
    printf '# SDLC Epic State\n\n'
    printf '## Epic\n%s\n\n' "$epic"
    printf '## Status\n%s\n\n' "$status"
    printf '## Cap\n%s\n\n' "$cap"
    printf '## Hops\n%s\n\n' "$hops"
    printf '## Tip\n%s\n\n' "$tip"
    printf '## Stack\n'
    cat
    if [ -n "$detail" ]; then
      printf '\n## Stopped\n%s\n' "$detail"
    fi
  } > "$tmpf"
  mv -f "$tmpf" "$f"
}

cmd_init() {
  local ref="${1:-}" cap="$DEFAULT_CAP"
  [ -n "$ref" ] || die "init requires an epic ref" 2
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --cap)
        [ $# -ge 2 ] || die "init: --cap requires a value" 2
        case "$2" in ''|*[!0-9]*) die "init: --cap must be numeric" 2 ;; esac
        cap=$((10#$2)); shift 2 ;;
      *) die "init: unknown flag: $1" 2 ;;
    esac
  done
  local f; f=$(state_file "$ref") || exit $?
  [ -f "$f" ] && die "init: state file already exists for '$ref'" 2
  printf '' | write_state "$f" "$ref" running "$cap" 0 main ""
}

cmd_status() {
  local ref="${1:-}"; [ -n "$ref" ] || die "status requires an epic ref" 2
  local f; f=$(state_file "$ref") || exit $?
  [ -f "$f" ] || die "status: no state file for '$ref'" 2
  local epic status cap hops tip detail
  epic=$(read_field "$f" Epic); epic="${epic:-$ref}"
  status=$(read_field "$f" Status); status="${status:-running}"
  cap=$(read_field "$f" Cap); case "$cap" in ''|*[!0-9]*) cap="$DEFAULT_CAP" ;; *) cap=$((10#$cap)) ;; esac
  hops=$(read_field "$f" Hops); case "$hops" in ''|*[!0-9]*) hops=0 ;; *) hops=$((10#$hops)) ;; esac
  tip=$(read_field "$f" Tip); tip="${tip:-main}"
  detail=$(read_field "$f" Stopped)
  printf 'epic=%s\n' "$epic"
  printf 'status=%s\n' "$status"
  printf 'cap=%s\n' "$cap"
  printf 'hops=%s\n' "$hops"
  printf 'tip=%s\n' "$tip"
  [ -n "$detail" ] && printf 'stopped_detail=%s\n' "$detail"
  read_stack "$f" | while IFS= read -r line; do printf 'stack=%s\n' "$line"; done
}

cmd_record() {
  [ $# -eq 5 ] || die "record requires: <epic-ref> <ticket-ref> <branch> <pr#> <hops>" 2
  local ref="$1" ticket="$2" branch="$3" pr="$4" hops_add="$5"
  case "$hops_add" in ''|*[!0-9]*) die "record: hops must be numeric" 2 ;; esac
  hops_add=$((10#$hops_add))
  local f; f=$(state_file "$ref") || exit $?
  [ -f "$f" ] || die "record: no state file for '$ref'" 2
  local epic cap hops_cur stack_lines total status detail
  epic=$(read_field "$f" Epic); epic="${epic:-$ref}"
  cap=$(read_field "$f" Cap); case "$cap" in ''|*[!0-9]*) cap="$DEFAULT_CAP" ;; *) cap=$((10#$cap)) ;; esac
  hops_cur=$(read_field "$f" Hops); case "$hops_cur" in ''|*[!0-9]*) hops_cur=0 ;; *) hops_cur=$((10#$hops_cur)) ;; esac
  stack_lines=$(read_stack "$f")
  total=$((hops_cur + hops_add))
  if [ "$total" -gt "$cap" ]; then
    status="stopped:hop-cap"; detail="$ticket $pr hop cap ($cap) reached"
  else
    status="running"; detail=""
  fi
  { [ -n "$stack_lines" ] && printf '%s\n' "$stack_lines"
    printf '%s %s %s %s\n' "$ticket" "$branch" "$pr" "$hops_add"
  } | write_state "$f" "$epic" "$status" "$cap" "$total" "$branch" "$detail"
  [ "$status" = "stopped:hop-cap" ] && exit 1
  printf 'Hops: %s of %s\n' "$total" "$cap"
}

cmd_set_status() {
  local ref="${1:-}" status="${2:-}" detail="${3:-}"
  [ -n "$ref" ] && [ -n "$status" ] || die "set-status requires: <epic-ref> <status> [detail]" 2
  case "$status" in
    done|stopped:review-tier-b-c|stopped:blocked) ;;
    *) die "set-status: status must be done, stopped:review-tier-b-c, or stopped:blocked" 2 ;;
  esac
  local f; f=$(state_file "$ref") || exit $?
  [ -f "$f" ] || die "set-status: no state file for '$ref'" 2
  local epic cap hops tip stack_lines
  epic=$(read_field "$f" Epic); epic="${epic:-$ref}"
  cap=$(read_field "$f" Cap); case "$cap" in ''|*[!0-9]*) cap="$DEFAULT_CAP" ;; *) cap=$((10#$cap)) ;; esac
  hops=$(read_field "$f" Hops); case "$hops" in ''|*[!0-9]*) hops=0 ;; *) hops=$((10#$hops)) ;; esac
  tip=$(read_field "$f" Tip); tip="${tip:-main}"
  stack_lines=$(read_stack "$f")
  { [ -n "$stack_lines" ] && printf '%s\n' "$stack_lines"; } | write_state "$f" "$epic" "$status" "$cap" "$hops" "$tip" "$detail"
}

case "${1:-}" in
  init)        shift; cmd_init "$@" ;;
  record)      shift; cmd_record "$@" ;;
  set-status)  shift; cmd_set_status "$@" ;;
  status)      shift; cmd_status "$@" ;;
  "") die "usage: sdlc-epicstate.sh <init|record|set-status|status> ..." 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
