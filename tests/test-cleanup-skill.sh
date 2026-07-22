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

# All three helpers pass '--' before the pattern: assertions legitimately
# start with '-' (the '-D <branch>' pairing below), and grep would
# otherwise read the pattern as a flag.
#
# want <description> <fixed-string>  — assert the string IS present.
want() {
  if grep -qF -- "$2" "$f"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
# reject <description> <fixed-string> — assert the string is NOT present.
reject() {
  if grep -qF -- "$2" "$f"; then bad "$1 (still present: $2)"; else ok "$1"; fi
}
# in_section <heading> <description> <fixed-string> — assert the string
# appears INSIDE <heading>'s section. The section runs from the heading to
# the next '## ' heading or the next top-level numbered step, whichever
# comes first; matching to end-of-file instead would let a later section
# satisfy an assertion about this one (the red flags mention "PR-merged",
# which would vacuously satisfy the step 5 assertion below).
in_section() {
  if awk -v h="$1" '
        $0 == h { n = 1; next }
        n && (/^## / || /^[0-9]+\. /) { exit }
        n
      ' "$f" | grep -qF -- "$3"; then
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

# Unpushed commits on a PR-merged branch are never discarded. Anchored on
# the two-part form rather than a bare 'ahead': the guard is only correct
# if the skill tests for the substring, and git writes '[ahead 1, behind 2]'
# as well as '[ahead 1]'. A bare 'ahead' would match ordinary prose.
want "ahead-of-upstream guard present" '[ahead 1, behind 2]'

# A merged PR is matched by tracked upstream, never by bare branch name:
# a never-pushed branch or a fork PR can collide by coincidence, and the
# confirmation gate would be shown real PR evidence for unrelated work.
want "matches on tracked upstream" '%(upstream)'
want "fork PRs excluded" 'isCrossRepository'

# A [gone] upstream whose branch still holds commits absent from base is
# the ordinary shape of the default merge-and-delete flow: the squash
# wrote a new commit, then the head branch was deleted. Demoting it to
# "review manually" reclaims nothing in exactly the repos issue #14 is
# about, and in every DEGRADED scan. It stays deletable, flagged.
in_section '2. **Scan (all read-only — nothing is deleted in this step).**' \
  "gone-with-commits stays deletable, flagged unverified" \
  'deletable, merge unverified'
in_section '3. **Report** the findings grouped as: Uncommitted (per tree),' \
  "report carries the unverified group" 'Deletable-but-unverified'
in_section '4. **Confirmation gate (the human gate).** Present the deletable' \
  "unverified branches are confirmed per item" 'ONE AT A TIME'

# The execute step must actually pair -D with the PR-merged class; that is
# the half of the change that does the deleting. Assert the pairing, not
# the bare words — the red flags mention 'PR-merged' too.
in_section '5. **Execute** only what was confirmed:' \
  "execute step deletes PR-merged with -D" '-D <branch>` for PR-merged'

# The red flags name the squash-merge trap specifically.
in_section '## Red flags' \
  "red flag names the squash-merge trap" 'not an ancestor'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
