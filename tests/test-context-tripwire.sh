#!/usr/bin/env bash
# Thresholds, debounce, baseline-reset, and sidechain-skip for the
# context tripwire. Overrides HOME so the cache dir is sandboxed.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../hooks/context-tripwire.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
pass=0; fail=0
contains() { # desc needle haystack
  if printf '%s' "$3" | grep -q "$2"; then echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (got: ${3:-<empty>})"; fail=$((fail+1)); fi
}
empty() { # desc haystack
  if [ -z "$2" ]; then echo "ok: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (expected empty, got: $2)"; fail=$((fail+1)); fi
}
hook() { # mode sid transcript_path
  printf '{"session_id":"%s","transcript_path":"%s"}' "$2" "$3" \
    | bash "$script" "$1"
}

tp="$tmp/main.jsonl"
hook baseline s1 "$tp" >/dev/null

head -c 400000 /dev/zero > "$tp"                       # ≈100k tokens
empty "below soft: silent"            "$(hook check s1 "$tp")"

head -c 500000 /dev/zero > "$tp"                       # ≈125k tokens
contains "soft fires at 125k" SOFT    "$(hook check s1 "$tp")"
empty    "soft debounced"             "$(hook check s1 "$tp")"

head -c 620000 /dev/zero > "$tp"                       # ≈155k tokens
contains "hard fires at 155k" HARD    "$(hook check s1 "$tp")"
empty    "hard debounced"             "$(hook check s1 "$tp")"

hook baseline s1 "$tp" >/dev/null                      # new session baseline
contains "baseline re-arms (hard refires)" HARD "$(hook check s1 "$tp")"

side="$tmp/sidechain.jsonl"; head -c 900000 /dev/zero > "$side"
hook baseline s2 "$tp" >/dev/null
empty "sidechain transcript ignored"  "$(hook check s2 "$side")"

out=$(hook check s3 "$side")                           # no baseline recorded
contains "no-baseline still checks" HARD "$out"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
