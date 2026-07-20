#!/usr/bin/env bash
# Handoff auto-pickup. SessionStart (startup|clear): if the project root
# holds .handoff-*.md files from a previous session, tell the fresh session
# to invoke sdlc:resume — the human's only manual step is launching claude.
set -u
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
# Enumerate every worktree (main tree first) and scan each root, so the
# handoff is found no matter where it was written or where claude launched.
roots=$(git worktree list --porcelain 2>/dev/null \
          | awk '/^worktree /{print $2}')
[ -n "$roots" ] || roots=$(git rev-parse --show-toplevel 2>/dev/null) || roots="$cwd"
files=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  f=$(find "$r" -maxdepth 1 -name '.handoff-*.md' 2>/dev/null)
  [ -n "$f" ] && files="$files$f"$'\n'
done <<EOF
$roots
EOF
files=$(printf '%s' "$files" | grep -v '^$' | sort -u)
[ -n "$files" ] || exit 0
n=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
echo "SDLC handoff pickup: $n handoff file(s) from a previous session:"
printf '%s\n' "$files"
echo "Invoke the sdlc:resume skill to continue that work. It verifies the \
recorded state against git (trust git over prose) and archives the file."
exit 0
