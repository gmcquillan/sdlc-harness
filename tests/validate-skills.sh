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

# --- the JIRA adapter references exist, and no GitHub twin --------------
for r in backend-jira backend-bind; do
  if [ -f "$root/references/$r.md" ]; then ok "references/$r.md exists"
  else bad "references/$r.md missing"; fi
done
# Spec T2: the GitHub path stays inline in the skills. A backend-github.md
# would mean the common path had started paying the adapter's cost.
if [ -e "$root/references/backend-github.md" ]; then
  bad "references/backend-github.md exists — the GitHub path must stay inline"
else
  ok "no references/backend-github.md"
fi

# --- inline gh commands survive (spec T3) -------------------------------
# Floors, not exact counts: adding gh calls is fine; losing them means the
# GitHub path grew a wrapper or an indirection. If a removal is deliberate,
# lower the floor in the same commit and say why in the message.
# The bracket class stands in for \b, which is not portable to BSD grep.
gh_floors="ticket:7 next:4 implement:7 review:8 resume:1"
for entry in $gh_floors; do
  name=${entry%%:*}; want=${entry##*:}
  f="$root/skills/$name/SKILL.md"
  if [ ! -f "$f" ]; then bad "$name: SKILL.md missing (gh floor)"; continue; fi
  got=$(grep -oE '(^|[^[:alnum:]_-])gh [a-z]' "$f" | wc -l | tr -d ' ')
  if [ "$got" -ge "$want" ]; then
    ok "$name: $got inline gh commands (floor $want)"
  else
    bad "$name: $got inline gh commands, floor is $want"
  fi
done
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
