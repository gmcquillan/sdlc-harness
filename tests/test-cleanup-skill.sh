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

if [ ! -f "$f" ]; then echo "FAIL: cleanup SKILL.md missing"; exit 1; fi

# 1. The merged-PR signal is queried (AC: squash-merged branch is deletable).
grep -qF 'gh pr list --state merged' "$f" \
  && ok "queries merged PRs" \
  || bad "no 'gh pr list --state merged' query"

# 2. The report cites PR number and merge SHA (AC: report states *why*).
grep -qF 'squash-merged as' "$f" \
  && ok "reason string cites the squash commit" \
  || bad "no 'squash-merged as' evidence string"

# 3. The stale parenthetical is gone (AC: correct the stale claim).
grep -qF 'usually squash-merged, so the remote branch' "$f" \
  && bad "stale parenthetical still present" \
  || ok "stale 'remote branch is deleted' claim removed"

# 4. The red flags name the squash trap (AC: red flag section).
awk '/^## Red flags$/{n=1} n' "$f" | grep -qF 'not an ancestor' \
  && ok "red flag names the squash-merge trap" \
  || bad "no red flag about 'not an ancestor' meaning unmerged"

# 5. The invariant is mutation-scoped, permitting the read-only query.
grep -qF 'never MUTATES' "$f" \
  && ok "invariant narrowed to mutations" \
  || bad "invariant not restated in terms of mutation"

# 6. Degraded mode is defined for when gh is unavailable.
grep -qF 'DEGRADED' "$f" \
  && ok "degraded fallback defined" \
  || bad "no DEGRADED fallback when gh is unavailable"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
