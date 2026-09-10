#!/usr/bin/env bash
# Thresholds, debounce, baseline-reset, and sidechain-skip for the
# context tripwire. Overrides HOME so the cache dir is sandboxed.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../hooks/context-tripwire.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
pass=0; fail=0
OUT=""; RC=0
hook() { # mode sid transcript_path -> sets OUT, RC
  OUT=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$2" "$3" \
    | bash "$script" "$1" 2>/dev/null)
  RC=$?
}
contains() { # desc needle
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "$2"; then
    echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}
empty() { # desc
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}

tp="$tmp/main.jsonl"
hook baseline s1 "$tp"

head -c 700000 /dev/zero > "$tp"                       # ≈175k tokens
hook check s1 "$tp"
empty "below soft: silent"

head -c 840000 /dev/zero > "$tp"                       # ≈210k tokens
hook check s1 "$tp"
contains "soft fires at 210k" SOFT
hook check s1 "$tp"
empty    "soft debounced"

head -c 1040000 /dev/zero > "$tp"                      # ≈260k tokens
hook check s1 "$tp"
contains "hard fires at 260k" HARD
hook check s1 "$tp"
empty    "hard debounced"

hook baseline s1 "$tp"                                 # new session baseline
hook check s1 "$tp"
contains "baseline re-arms (hard refires)" HARD

side="$tmp/sidechain.jsonl"; head -c 1100000 /dev/zero > "$side"  # ≈275k tokens
hook baseline s2 "$tp"
hook check s2 "$side"
empty "sidechain transcript ignored"

hook check s3 "$side"                                  # no baseline recorded
contains "no-baseline still checks" HARD

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
