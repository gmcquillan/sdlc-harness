#!/usr/bin/env bash
# Lint gate before every `git push` (sdlc: enforcement is a hook, not
# model discipline — same pattern as context-tripwire). PreToolUse(Bash):
# when the command is a `git push`, auto-detect the project linter, run
# it, and DENY the push on failure. Not a push, not a git repo, no linter
# detected, or SDLC_SKIP_LINT set -> allow silently. Fail-open: any
# unexpected condition allows rather than wedging the workflow.
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Gate only `git push`. Tolerate flags/remotes between the words; stop at
# a shell separator so `git commit && push` does not match. `tr` breaks the
# command at those separators so both words must land in one segment, and
# the bracket classes stand in for `\b` -- a GNU-only extension whose BSD
# counterpart `[[:<:]]` GNU grep rejects. Same reasoning as cmd_sniff in
# bin/sdlc-backend.sh; here the match is boolean, so `grep -q` may consume
# the boundary characters freely.
printf '%s' "$cmd" | tr ';&|' '\n\n\n' \
  | grep -Eq '(^|[^[:alnum:]_])git([^[:alnum:]_].*)?[^[:alnum:]_]push([^[:alnum:]_]|$)' \
  || exit 0

# Intentional bypass (doc-only push, temporarily broken linter, etc.).
[ -n "${SDLC_SKIP_LINT:-}" ] && exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" 2>/dev/null || exit 0

# Detect the linter; first match wins. No match -> allow.
lint_cmd=""
mf=""
[ -f Makefile ] && mf=Makefile
[ -f makefile ] && mf=makefile
if [ -n "$mf" ] && grep -Eq '^lint:' "$mf"; then
  lint_cmd="make lint"
elif [ -f package.json ] && jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
  if   [ -f pnpm-lock.yaml ]; then lint_cmd="pnpm run lint"
  elif [ -f yarn.lock ];      then lint_cmd="yarn lint"
  else                             lint_cmd="npm run lint"; fi
elif [ -f .pre-commit-config.yaml ]; then
  lint_cmd="pre-commit run --all-files"
fi
[ -n "$lint_cmd" ] || exit 0

out=$(eval "$lint_cmd" 2>&1); rc=$?
[ "$rc" -eq 0 ] && exit 0   # lint passed -> allow the push

# Lint failed -> deny, feeding the tail of the output back to Claude.
tail=$(printf '%s' "$out" | tail -c 2000)
reason=$(printf 'Lint failed before push (`%s`). Fix the errors and retry, or set SDLC_SKIP_LINT=1 to bypass intentionally.\n\n%s' "$lint_cmd" "$tail")
jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
