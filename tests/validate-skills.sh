#!/usr/bin/env bash
# Validates every skills/*/SKILL.md: frontmatter fence present, name: matches
# its directory, description: non-empty and begins "Use when".
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
pass=0; fail=0
ok()   { echo "ok: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

expected="interview ticket next implement review handoff resume cleanup"
for name in $expected; do
  f="$root/skills/$name/SKILL.md"
  if [ ! -f "$f" ]; then bad "$name: SKILL.md missing"; continue; fi
  head -1 "$f" | grep -qx -- '---' || { bad "$name: no frontmatter fence"; continue; }
  fm=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$f")
  printf '%s\n' "$fm" | grep -qx "name: $name" \
    || { bad "$name: frontmatter name != directory"; continue; }
  desc=$(printf '%s\n' "$fm" | sed -n 's/^description: //p')
  case "$desc" in
    "Use when"*) ok "$name" ;;
    "") bad "$name: empty description" ;;
    *) bad "$name: description must begin 'Use when'" ;;
  esac
done

# --- step 0 resolves the ticket backend (spec T3, T8) -------------------
# The GitHub path must cost exactly one bash call, so each ticket-touching
# skill resolves the backend in step 0 and branches on the action. Look
# only inside the step-0 block: a mention elsewhere in the file does not
# satisfy this.
pipeline="ticket next implement review"
for name in $pipeline; do
  f="$root/skills/$name/SKILL.md"
  if [ ! -f "$f" ]; then bad "$name: SKILL.md missing (step 0)"; continue; fi
  step0=$(awk '/^0\. /{n=1} /^1\. /{n=0} n' "$f")
  if [ -z "$step0" ]; then
    bad "$name: no step 0 block"
  elif printf '%s\n' "$step0" | grep -q 'sdlc-backend\.sh resolve'; then
    ok "$name: step 0 resolves the backend"
  else
    bad "$name: step 0 does not run sdlc-backend.sh resolve"
  fi
done
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
