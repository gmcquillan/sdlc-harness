#!/usr/bin/env bash
# Deterministic hop-count/cap check for phase-aware auto-continue (sdlc
# spec P3: deterministic, not model discipline). sdlc:handoff calls this
# before deciding whether to take the --continue path automatically when
# a context tripwire fires; the model branches on the exit code below, it
# never computes the cap arithmetic itself.
#
# Unlike hooks/*.sh (which fail open with a silent exit 0), this is a CLI:
# exit codes are its interface.
#   2 = phase is not auto-continue-eligible (interview|ticket, or unknown)
#       — no stdout; ALSO used (with a stderr message) for a genuine usage
#       error, since a usage error must fall back to the same default
#       end-turn path a caller takes for any non-eligible phase
#   1 = eligible phase, but the hop cap is reached — no stdout
#   0 = eligible phase, cap not reached — stdout is exactly one line:
#       "Hop: <next> of <cap>"
set -u

CAP=10

die() { printf 'sdlc-hopcount: %s\n' "$1" >&2; exit "${2:-1}"; }

cmd_check() {
  local phase="${1:-}" prior="${2:-}"
  [ -n "$phase" ] || die "check requires a phase" 2
  case "$phase" in
    implement|review) : ;;
    # A recognized-but-ineligible phase (interview|ticket) or any unknown
    # string is a routine, expected outcome for this check, not a bug —
    # exit silently, no stderr noise for something the caller triggers on
    # every interview/ticket tripwire.
    *) exit 2 ;;
  esac

  # Malformed, absent, or missing-file Hop input all degrade to n=0 (the
  # first hop of a chain) rather than erroring: a prior handoff predating
  # this feature has no Hop line at all, and that must not be treated any
  # differently from a fresh implement/review run with no prior handoff.
  local n=0 line
  if [ -n "$prior" ] && [ -f "$prior" ]; then
    line=$(grep -m1 -E '^Hop: [0-9]+ of [0-9]+$' "$prior" 2>/dev/null || true)
    if [ -n "$line" ]; then
      n=$(printf '%s' "$line" | sed -E 's/^Hop: ([0-9]+) of [0-9]+$/\1/')
    fi
  fi

  local next=$((n + 1))
  [ "$next" -le "$CAP" ] || exit 1
  printf 'Hop: %d of %d\n' "$next" "$CAP"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  "") die "usage: sdlc-hopcount.sh check <phase> [prior-handoff-file]" 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
