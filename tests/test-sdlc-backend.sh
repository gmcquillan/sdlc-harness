#!/usr/bin/env bash
# bin/sdlc-backend.sh — repo identity, binding cache, MCP gating, key sniffing.
# SDLC_HOME and HOME are both redirected into $tmp so the suite can never
# read or write the developer's real cache or MCP config.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
SUT="$here/../bin/sdlc-backend.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SDLC_HOME="$tmp/sdlc"
export HOME="$tmp"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { # want got desc
  [ "$1" = "$2" ] && ok "$3" || bad "$3 (want '$1' got '$2')"
}

mkrepo() { # dir [origin-url] -> initialized repo with one commit
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  [ $# -ge 2 ] && git -C "$d" remote add origin "$2"
  return 0
}

# --- repo key: four remote URL forms collapse to one key ----------------
i=0
for url in "git@github.com:a/b.git" \
           "https://github.com/a/b" \
           "https://github.com/a/b/" \
           "ssh://git@github.com/a/b.git"; do
  i=$((i+1)); r="$tmp/form$i"; mkrepo "$r" "$url"
  got=$(cd "$r" && "$SUT" resolve | jq -r '.repo')
  eq "github.com/a/b" "$got" "remote form $i normalizes ($url)"
done

# --- repo key: worktree collapses to its main repo ----------------------
wtmain="$tmp/wtmain"; mkrepo "$wtmain" "git@github.com:a/b.git"
git -C "$wtmain" worktree add -q "$tmp/wtlinked" -b feat >/dev/null 2>&1
mainkey=$(cd "$wtmain" && "$SUT" resolve | jq -r '.repo')
wtkey=$(cd "$tmp/wtlinked" && "$SUT" resolve | jq -r '.repo')
eq "$mainkey" "$wtkey" "worktree resolves to same key as main repo"

# --- repo key: no-origin fallback is stable and worktree-collapsing -----
noremote="$tmp/noremote"; mkrepo "$noremote"
k1=$(cd "$noremote" && "$SUT" resolve | jq -r '.repo')
k2=$(cd "$noremote" && "$SUT" resolve | jq -r '.repo')
eq "$k1" "$k2" "no-origin fallback key is stable across calls"
case "$k1" in path:/*) ok "no-origin key uses path: prefix" ;;
             *) bad "no-origin key not a path: key (got '$k1')" ;; esac
git -C "$noremote" worktree add -q "$tmp/nowt" -b feat >/dev/null 2>&1
k3=$(cd "$tmp/nowt" && "$SUT" resolve | jq -r '.repo')
eq "$k1" "$k3" "no-origin worktree collapses to main repo key"

# --- outside a git repo -> exit 3 ---------------------------------------
outside="$tmp/notarepo"; mkdir -p "$outside"
(cd "$outside" && "$SUT" resolve >/dev/null 2>&1); rc=$?
eq "3" "$rc" "resolve exits 3 outside a git repo"

# --- cache: set -> resolve round trip -----------------------------------
cr="$tmp/cacherepo"; mkrepo "$cr" "git@github.com:a/cache.git"
(cd "$cr" && "$SUT" set --backend jira --project PROJ \
   --cloud-id CID --site https://acme.atlassian.net --source git-sniff-confirmed)
out=$(cd "$cr" && "$SUT" resolve)
eq "jira"  "$(printf '%s' "$out" | jq -r '.backend')"  "set --backend jira round-trips"
eq "PROJ"  "$(printf '%s' "$out" | jq -r '.project')"  "set --project round-trips"
eq "CID"   "$(printf '%s' "$out" | jq -r '.cloud_id')" "set --cloud-id round-trips"
eq "https://acme.atlassian.net" "$(printf '%s' "$out" | jq -r '.site')" \
   "set --site round-trips"

# the cache carries the co-owned schema T2's bind procedure reads back
eq "1" "$(jq -r '.version' "$SDLC_HOME/repos.json")" "cache records version 1"
eq "git-sniff-confirmed" \
   "$(jq -r '.repos["github.com/a/cache"].source' "$SDLC_HOME/repos.json")" \
   "cache records bind source"

# --- cache: unbound repo reports backend null ---------------------------
ub="$tmp/unbound"; mkrepo "$ub" "git@github.com:a/unbound.git"
eq "null" "$(cd "$ub" && "$SUT" resolve | jq -r '.backend')" \
   "unbound repo reports backend null"

# --- cache: unset clears the binding ------------------------------------
(cd "$cr" && "$SUT" unset)
eq "null" "$(cd "$cr" && "$SUT" resolve | jq -r '.backend')" "unset clears binding"

# --- cache: toolmap round trip (global, not per-repo) -------------------
printf '%s' '{"server":"atlassian","ops":{"create_issue":"mcp__atlassian__createJiraIssue"}}' \
  | (cd "$cr" && "$SUT" set-toolmap)
eq "mcp__atlassian__createJiraIssue" \
   "$(cd "$cr" && "$SUT" get-toolmap | jq -r '.ops.create_issue')" \
   "toolmap round-trips"
eq "atlassian" "$(cd "$ub" && "$SUT" get-toolmap | jq -r '.server')" \
   "toolmap is global across repos"

# --- cache: atomic writes leave no temp droppings -----------------------
# repos.json must be the ONLY file in the cache dir after several writes;
# matching a temp-name pattern instead would pass vacuously if the naming
# scheme ever changed.
eq "1" "$(find "$SDLC_HOME" -maxdepth 1 -type f | wc -l)" \
   "no temp files left behind after writes"

# --- cache: malformed repos.json is treated as empty, not fatal ---------
printf 'not json at all{{{' > "$SDLC_HOME/repos.json"
out=$(cd "$ub" && "$SUT" resolve 2>/dev/null); rc=$?
eq "0"    "$rc" "malformed cache is not fatal"
eq "null" "$(printf '%s' "$out" | jq -r '.backend')" "malformed cache reads as empty"
(cd "$cr" && "$SUT" set --backend github) 2>/dev/null
eq "github" "$(cd "$cr" && "$SUT" resolve | jq -r '.backend')" \
   "a write over a malformed cache repairs it"

# --- cache: absent repos.json is treated as empty, not fatal ------------
rm -rf "$SDLC_HOME"
out=$(cd "$ub" && "$SUT" resolve 2>/dev/null); rc=$?
eq "0"    "$rc" "absent cache is not fatal"
eq "null" "$(printf '%s' "$out" | jq -r '.backend')" "absent cache reads as empty"

# --- cache: set with a dangling flag exits 2, not an infinite loop -------
# shift 2 is a no-op (not an error) when only one positional argument is
# left, so a trailing flag with no value must be caught explicitly or the
# parser spins at 100% CPU forever. timeout turns a regression into a
# FAIL (exit 124) instead of hanging this whole suite.
mv="$tmp/missingval"; mkrepo "$mv" "git@github.com:a/missingval.git"
(cd "$mv" && timeout 5 "$SUT" set --backend) >/dev/null 2>&1
eq "2" "$?" "set --backend with no value exits 2, does not hang"

(cd "$mv" && timeout 5 "$SUT" set --backend jira --project) >/dev/null 2>&1
eq "2" "$?" "set --project with no value exits 2, does not hang"

(cd "$mv" && timeout 5 "$SUT" set --backend jira --project PROJ) >/dev/null 2>&1
eq "0" "$?" "well-formed set still succeeds"
eq "jira" "$(cd "$mv" && "$SUT" resolve | jq -r '.backend')" \
   "well-formed set still binds the backend"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
