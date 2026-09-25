#!/usr/bin/env bash
# bin/sdlc-hopcount.sh — phase eligibility gate and hop-count/cap
# arithmetic for auto-continue. Exit codes are the whole interface; see
# the script's header comment for the contract.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
SUT="$here/../bin/sdlc-hopcount.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { # want got desc
  [ "$1" = "$2" ] && ok "$3" || bad "$3 (want '$1' got '$2')"
}

run() { # phase [prior] -> sets OUT, RC
  OUT=$("$SUT" check "$@" 2>/dev/null); RC=$?
}

# --- non-eligible phases: exit 2, no stdout -----------------------------
for phase in interview ticket bogus; do
  run "$phase"
  eq "2" "$RC" "phase '$phase' exits 2"
  eq "" "$OUT" "phase '$phase' prints nothing"
done

# --- eligible phase, no prior file: first hop ---------------------------
run implement
eq "0" "$RC" "no prior file exits 0"
eq "Hop: 1 of 10" "$OUT" "no prior file starts at hop 1 of 10"

run review "$tmp/does-not-exist.md"
eq "0" "$RC" "nonexistent prior path exits 0"
eq "Hop: 1 of 10" "$OUT" "nonexistent prior path starts at hop 1 of 10"

# --- prior hop increments, one below the cap -----------------------------
p9="$tmp/prior9.md"
cat > "$p9" <<'EOF'
# SDLC Handoff

## Phase
implement — step 7

## State
- Last commit: abc123 wip
Hop: 9 of 10
EOF
run implement "$p9"
eq "0" "$RC" "hop 9 of 10 exits 0"
eq "Hop: 10 of 10" "$OUT" "hop 9 of 10 advances to 10 of 10"

# --- cap reached: exit 1, no stdout --------------------------------------
p10="$tmp/prior10.md"
cat > "$p10" <<'EOF'
## State
Hop: 10 of 10
EOF
run implement "$p10"
eq "1" "$RC" "hop 10 of 10 (cap) exits 1"
eq "" "$OUT" "hop 10 of 10 (cap) prints nothing"

# --- missing Hop line in an otherwise-valid prior file: treated as n=0 ---
pmiss="$tmp/nohop.md"
cat > "$pmiss" <<'EOF'
## State
- Last commit: abc123 wip
- Stash: none
EOF
run implement "$pmiss"
eq "0" "$RC" "missing Hop line exits 0"
eq "Hop: 1 of 10" "$OUT" "missing Hop line treated as n=0"

# --- malformed Hop line: treated as n=0 ----------------------------------
pbad="$tmp/badhop.md"
cat > "$pbad" <<'EOF'
Hop: banana of 10
EOF
run implement "$pbad"
eq "0" "$RC" "malformed Hop line exits 0"
eq "Hop: 1 of 10" "$OUT" "malformed Hop line treated as n=0"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
