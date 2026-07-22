#!/usr/bin/env bash
# Guards the squash-merge fixes in skills/cleanup/SKILL.md (issue #14).
# A squash-merged branch is not an ancestor of base and — when the repo keeps
# head branches — has no [gone] upstream, so neither local signal fires.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
f="$here/../skills/cleanup/SKILL.md"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# want <description> <fixed-string>  — assert the string IS present.
want() {
  if grep -qF "$2" "$f"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
# reject <description> <fixed-string> — assert the string is NOT present.
reject() {
  if grep -qF "$2" "$f"; then bad "$1 (still present: $2)"; else ok "$1"; fi
}
# in_section <heading> <description> <fixed-string> — assert the string
# appears at or after <heading>. Scoping beats whole-file matching: it
# pins each claim to the section that has to carry it, and survives
# rewording elsewhere in the file.
in_section() {
  if awk -v h="$1" '$0==h{n=1} n' "$f" | grep -qF "$3"; then
    ok "$2"
  else
    bad "$2 (missing under $1: $3)"
  fi
}

if [ ! -f "$f" ]; then echo "FAIL: cleanup SKILL.md missing"; exit 1; fi

# The merged-PR signal is queried — without it a squash-merged branch is
# invisible to cleanup in a repo that keeps head branches.
want "queries merged PRs" 'gh pr list --state merged'

# The report cites the PR and the squash commit, so the human gate can judge.
want "reason string cites the squash commit" 'squash-merged as'

# The stale claim that squash-merging deletes the remote branch is gone.
reject "stale 'remote branch is deleted' claim removed" \
  'usually squash-merged, so the remote branch'

# The invariant is mutation-scoped, which is what permits the read-only query.
want "invariant narrowed to mutations" 'never MUTATES'

# Cleanup still works, degraded, when gh is unavailable.
want "degraded fallback defined" 'DEGRADED'

# Unpushed commits on a PR-merged branch are never discarded. Matching on
# 'ahead' (not '[ahead N]') because the skill must itself warn that git
# also writes '[ahead 1, behind 2]'.
want "ahead-of-upstream guard present" 'ahead'

# A merged PR is matched by tracked upstream, never by bare branch name:
# a never-pushed branch or a fork PR can collide by coincidence, and the
# confirmation gate would be shown real PR evidence for unrelated work.
want "matches on tracked upstream" '%(upstream)'
want "fork PRs excluded" 'isCrossRepository'

# The execute step must actually use -D for the PR-merged class; that is
# the half of the change that does the deleting.
in_section '5. **Execute** only what was confirmed:' \
  "execute step deletes PR-merged with -D" 'PR-merged'

# The red flags name the squash-merge trap specifically.
in_section '## Red flags' \
  "red flag names the squash-merge trap" 'not an ancestor'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
