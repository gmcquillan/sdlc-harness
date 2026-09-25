#!/usr/bin/env bash
# bin/sdlc-epicstate.sh — durable state-file arithmetic for sdlc:epic's
# stacked-PR autopilot loop. Exit codes are the whole interface; see the
# script's header comment for the contract.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
SUT="$here/../bin/sdlc-epicstate.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# sdlc-epicstate.sh locates the state file via `git worktree list`, so
# it needs to run inside a real (if empty) git repo, not a bare scratch dir.
repo="$tmp/repo"
mkdir -p "$repo"
( cd "$repo" && git init -q )

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { # want got desc
  [ "$1" = "$2" ] && ok "$3" || bad "$3 (want '$1' got '$2')"
}

run() { # <args...> -> sets OUT, RC (always inside the fixture repo)
  OUT=$(cd "$repo" && "$SUT" "$@" 2>/dev/null); RC=$?
}

field() { # <name> -> the value of "<name>=..." from the last run's $OUT
  printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n1
}

# --- init ---------------------------------------------------------------
run init 100
eq "0" "$RC" "fresh init exits 0"
[ -f "$repo/.sdlc-epic-100.md" ] && ok "init creates the state file" \
  || bad "init creates the state file"

run init 100
eq "2" "$RC" "duplicate init exits 2"

run init 200 --cap 5
eq "0" "$RC" "init with a custom --cap exits 0"
run status 200
eq "5" "$(field cap)" "custom --cap is recorded"

run init 300 --cap banana
eq "2" "$RC" "non-numeric --cap exits 2"

run init 'foo/bar'
eq "2" "$RC" "an epic ref containing a slash is rejected"

# --- record: happy path ---------------------------------------------------
run record 999 t1 sdlc/999-t1 1 3
eq "2" "$RC" "record on an unknown epic exits 2"

run record 100 t1 sdlc/100-t1 10 abc
eq "2" "$RC" "record with a non-numeric hops argument exits 2"

run record 100 t1 sdlc/100-t1 10 3
eq "0" "$RC" "first record exits 0"
eq "Hops: 3 of 30" "$OUT" "first record sums from 0"

run record 100 t2 sdlc/100-t2 11 4
eq "0" "$RC" "second record exits 0"
eq "Hops: 7 of 30" "$OUT" "second record accumulates"
run status 100
eq "2" "$(printf '%s\n' "$OUT" | grep -c '^stack=')" \
  "second record appends a second stack line"

# --- record: hop cap ------------------------------------------------------
run record 200 t1 sdlc/200-t1 20 3
eq "0" "$RC" "record under a small custom cap exits 0"
run record 200 t2 sdlc/200-t2 21 4
eq "1" "$RC" "record over a small custom cap exits 1"
eq "" "$OUT" "record over the cap prints nothing"
run status 200
eq "7" "$(field hops)" "hop count is still persisted after the cap trips"
eq "stopped:hop-cap" "$(field status)" "status becomes stopped:hop-cap"

# --- record: cap of 0 boundary ---------------------------------------------
run init 400 --cap 0
run record 400 t1 sdlc/400-t1 40 1
eq "1" "$RC" "any hops against a cap of 0 trips immediately"
run status 400
eq "stopped:hop-cap" "$(field status)" "cap-0 epic is stopped:hop-cap"

# --- set-status ------------------------------------------------------------
run set-status 100 stopped:blocked "waiting on #55"
eq "0" "$RC" "set-status with a valid token exits 0"
run status 100
eq "stopped:blocked" "$(field status)" "set-status updates status"
eq "waiting on #55" "$(field stopped_detail)" "set-status records the detail"

run set-status 100 running
eq "2" "$RC" "set-status rejects 'running' (owned only by record/init)"

run set-status 100 bogus-status
eq "2" "$RC" "set-status with an unrecognized token exits 2"

# --- unknown epic: status/record/set-status all exit 2 ---------------------
run status 999
eq "2" "$RC" "status on an unknown epic exits 2"
run set-status 999 done
eq "2" "$RC" "set-status on an unknown epic exits 2"

# --- leading '#' sanitizes to the same file as the bare ref -----------------
run init '#123'
eq "0" "$RC" "init with a leading # exits 0"
run record 123 t1 sdlc/123-t1 1 2
eq "0" "$RC" "record with the bare ref hits the file '#123' created"
[ -f "$repo/.sdlc-epic-123.md" ] && ok "leading # and bare ref share one file" \
  || bad "leading # and bare ref share one file"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
