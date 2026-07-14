#!/usr/bin/env bash
# Context-budget tripwire (sdlc spec P3: deterministic, not model discipline).
#   context-tripwire.sh baseline — SessionStart: record the main transcript
#                                  path; clear fired-threshold markers
#   context-tripwire.sh check    — PostToolUse (all tools): estimate live
#                                  context as transcript-bytes/4; nudge a
#                                  handoff once at SOFT and once at HARD.
# The byte heuristic overestimates after compaction, which fails safe
# (early handoff, never a blown budget).
set -u
mode="${1:-check}"
input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
dir="$HOME/.claude/cache/context-tripwire"
soft=120000
hard=150000

mkdir -p "$dir" 2>/dev/null || exit 0

if [ "$mode" = "baseline" ]; then
  find "$dir" -type f -mtime +7 -delete 2>/dev/null
  printf '%s' "$tp" > "$dir/$sid.transcript"
  rm -f "$dir/$sid.soft" "$dir/$sid.hard"
  exit 0
fi

# check mode. Subagent tool calls report a sidechain transcript — that is
# the subagent's context, not this session's; never measure it. If no
# baseline exists (plugin installed mid-session), check anyway: a false
# nudge is cheaper than a silent tripwire.
main_tp=$(cat "$dir/$sid.transcript" 2>/dev/null || true)
if [ -n "$main_tp" ] && [ -n "$tp" ] && [ "$tp" != "$main_tp" ]; then
  exit 0
fi
[ -f "$tp" ] || exit 0
bytes=$(wc -c < "$tp" 2>/dev/null) || exit 0
tokens=$((bytes / 4))

fire() {
  jq -cn --arg m "$1" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
}

if [ "$tokens" -ge "$hard" ] && [ ! -f "$dir/$sid.hard" ]; then
  : > "$dir/$sid.hard"
  fire "Context tripwire HARD: estimated context ~${tokens} tokens, at or \
over the 150k budget. Invoke the sdlc:handoff skill NOW: commit WIP, write \
the handoff file, then end the turn — or pass --continue to dispatch a \
fresh-context subagent and act as supervisor only. Start no new work in \
this session."
elif [ "$tokens" -ge "$soft" ] && [ ! -f "$dir/$sid.soft" ]; then
  : > "$dir/$sid.soft"
  fire "Context tripwire SOFT: estimated context ~${tokens} tokens (120k of \
the 150k budget). Finish the current atomic step, then invoke the \
sdlc:handoff skill. Until then, delegate any remaining exploration, test \
runs, or verification to subagents — their transcripts do not enter this \
context (delegate breadth, keep judgment)."
fi
exit 0
