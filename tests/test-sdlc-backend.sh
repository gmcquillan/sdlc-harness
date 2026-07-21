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

# --- action gating ------------------------------------------------------
# HOME is $tmp, so $HOME/.claude.json is this suite's fixture.
gate="$tmp/gate"; mkrepo "$gate" "git@github.com:a/gate.git"
rm -rf "$SDLC_HOME" "$HOME/.claude.json"

# (a) no JIRA-looking MCP anywhere -> use-github, and NOTHING is written
out=$(cd "$gate" && "$SUT" resolve)
eq "use-github" "$(printf '%s' "$out" | jq -r '.action')" \
   "no MCP configured -> use-github"
eq "false" "$([ -e "$SDLC_HOME/repos.json" ] && echo true || echo false)" \
   "use-github path writes nothing to the cache"

# the full resolve contract T3-T7 depend on
for k in repo action backend project cloud_id site toolmap; do
  [ "$(printf '%s' "$out" | jq "has(\"$k\")")" = "true" ] \
    && ok "resolve emits key '$k'" || bad "resolve missing key '$k'"
done

# (b) an unrelated MCP server does not trip the heuristic
printf '%s' '{"mcpServers":{"postgres":{"command":"x"}}}' > "$HOME/.claude.json"
eq "use-github" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "unrelated MCP server -> still use-github"

# (c) a JIRA-looking server in ~/.claude.json + unbound repo -> bind-needed
printf '%s' '{"mcpServers":{"Atlassian":{"command":"x"}}}' > "$HOME/.claude.json"
eq "bind-needed" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "atlassian server (case-insensitive) + unbound -> bind-needed"
eq "false" "$([ -e "$SDLC_HOME/repos.json" ] && echo true || echo false)" \
   "bind-needed path also writes nothing"

# (d) detection also reads ~/.claude.json's per-project mcpServers
printf '%s' '{"projects":{"/somewhere":{"mcpServers":{"jira-cloud":{"command":"x"}}}}}' \
  > "$HOME/.claude.json"
eq "bind-needed" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "per-project mcpServers entry is detected"

# (e) detection also reads a project-local .mcp.json at the repo root
printf '%s' '{"mcpServers":{"postgres":{"command":"x"}}}' > "$HOME/.claude.json"
printf '%s' '{"mcpServers":{"my-jira":{"command":"x"}}}' > "$gate/.mcp.json"
eq "bind-needed" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "project .mcp.json is detected"
# ...and from a subdirectory of the repo, not just its root
mkdir -p "$gate/sub"
eq "bind-needed" "$(cd "$gate/sub" && "$SUT" resolve | jq -r '.action')" \
   "project .mcp.json is found from a subdirectory"
rm -f "$gate/.mcp.json"

# (f) bound repo wins over config in both directions
printf '%s' '{"mcpServers":{"atlassian":{"command":"x"}}}' > "$HOME/.claude.json"
(cd "$gate" && "$SUT" set --backend jira --project PROJ)
eq "use-jira" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "bound to jira -> use-jira"
(cd "$gate" && "$SUT" set --backend github)
eq "use-github" "$(cd "$gate" && "$SUT" resolve | jq -r '.action')" \
   "explicitly bound to github -> use-github despite MCP present"
rm -f "$HOME/.claude.json"
eq "use-jira" "$(cd "$cr" && "$SUT" set --backend jira >/dev/null 2>&1; \
                 cd "$cr" && "$SUT" resolve | jq -r '.action')" \
   "bound to jira -> use-jira even with no MCP configured"

# --- sniff --------------------------------------------------------------
sn="$tmp/sniff"; mkrepo "$sn" "git@github.com:a/sniff.git"
c() { git -C "$sn" commit -q --allow-empty -m "$1"; }
c "PROJ-1 first";  c "PROJ-2 second"; c "PROJ-3 third"; c "PROJ-4 fourth"
c "MINOR-1 a";     c "MINOR-2 b";     c "MINOR-3 c"
c "RARE-1 only once"; c "RARE-2 twice"          # 2 hits: under the floor
c "fix UTF-8 handling and CVE-2024-1234 and RFC-3339"
c "another UTF-8 fix";  c "more UTF-8 and CVE-2024-9999 and RFC-2119"
c "yet more UTF-8, CVE-2024-1111, RFC-1234"
sniff_out=$(cd "$sn" && "$SUT" sniff)

eq "PROJ" "$(printf '%s\n' "$sniff_out" | awk 'NR==1{print $1}')" \
   "sniff ranks the most frequent key first"
eq "4"    "$(printf '%s\n' "$sniff_out" | awk 'NR==1{print $2}')" \
   "sniff reports the hit count"
eq "MINOR" "$(printf '%s\n' "$sniff_out" | awk 'NR==2{print $1}')" \
   "sniff ranks the second key second"
printf '%s\n' "$sniff_out" | grep -q '^RARE ' \
  && bad "sniff proposed a candidate under the 3-hit floor" \
  || ok "sniff suppresses candidates under 3 hits"
for d in UTF CVE RFC; do
  printf '%s\n' "$sniff_out" | grep -q "^$d " \
    && bad "sniff proposed denylisted key $d" \
    || ok "sniff rejects denylisted $d"
done

# branch names count toward the ranking, not just commit subjects
git -C "$sn" branch "BRANCHY-1" >/dev/null 2>&1
git -C "$sn" branch "BRANCHY-2" >/dev/null 2>&1
git -C "$sn" branch "BRANCHY-3" >/dev/null 2>&1
(cd "$sn" && "$SUT" sniff) | grep -q '^BRANCHY 3$' \
  && ok "sniff counts branch names" || bad "sniff ignored branch names"

# a key mentioned only in a commit BODY still counts
git -C "$sn" commit -q --allow-empty -m "subject" -m "BODYKEY-1 BODYKEY-2 BODYKEY-3"
(cd "$sn" && "$SUT" sniff) | grep -q '^BODYKEY 3$' \
  && ok "sniff reads commit bodies" || bad "sniff ignored commit bodies"

# a repo with no keys at all sniffs clean and does not error
clean="$tmp/cleanrepo"; mkrepo "$clean" "git@github.com:a/clean.git"
sn_clean=$(cd "$clean" && "$SUT" sniff); rc=$?
eq "0"  "$rc" "sniff exits 0 on a repo with no candidates"
eq ""   "$sn_clean" "sniff prints nothing when there are no candidates"

# sniff respects the git-repo guard
(cd "$outside" && "$SUT" sniff >/dev/null 2>&1); rc=$?
eq "3" "$rc" "sniff exits 3 outside a git repo"

# --- MCP config visible only from the main worktree still gates worktrees -
# Fix 2: jira_mcp_configured must not vary by which worktree you resolve
# from -- repo_key() collapses every worktree to the main repo, so
# .mcp.json visibility must too. Left untracked in the main repo so the
# worktree's own checkout genuinely lacks it.
mcpmain="$tmp/mcpmain"; mkrepo "$mcpmain" "git@github.com:a/mcpmain.git"
printf '%s' '{"mcpServers":{"jira-server":{"command":"x"}}}' > "$mcpmain/.mcp.json"
git -C "$mcpmain" worktree add -q "$tmp/mcpwt" -b feat2 >/dev/null 2>&1
rm -f "$HOME/.claude.json"
eq "false" "$([ -f "$tmp/mcpwt/.mcp.json" ] && echo true || echo false)" \
   ".mcp.json is genuinely absent from the worktree's own checkout"
eq "bind-needed" "$(cd "$tmp/mcpwt" && "$SUT" resolve | jq -r '.action')" \
   "worktree resolve sees main repo's untracked .mcp.json -> bind-needed"

# --- get-toolmap and resolve agree on the "no toolmap" shape ------------
rm -rf "$SDLC_HOME"
eq "null" "$(cd "$ub" && "$SUT" get-toolmap)" \
   "get-toolmap on an empty cache prints null"

# --- action gating: malformed / unreadable ~/.claude.json is not fatal --
printf 'not json at all{{{' > "$HOME/.claude.json"
out=$(cd "$ub" && "$SUT" resolve 2>/dev/null); rc=$?
eq "0"          "$rc" "malformed ~/.claude.json exits 0"
eq "use-github" "$(printf '%s' "$out" | jq -r '.action')" \
   "malformed ~/.claude.json -> use-github"

chmod 000 "$HOME/.claude.json"
out=$(cd "$ub" && "$SUT" resolve 2>/dev/null); rc=$?
eq "0"          "$rc" "unreadable ~/.claude.json exits 0"
eq "use-github" "$(printf '%s' "$out" | jq -r '.action')" \
   "unreadable ~/.claude.json -> use-github"
chmod 644 "$HOME/.claude.json"
rm -f "$HOME/.claude.json"

# --- sniff: denylist rejects only exact whole-line matches --------------
# MDX, ARMOR, and HTTP2 all CONTAIN a denylisted string (MD, ARM, HTTP)
# but are not EQUAL to it; grep -vxE's -x (whole-line) flag is what lets
# them survive. ARM itself is denylisted and must still be rejected in
# the same run, proving discrimination rather than a disabled filter.
dl="$tmp/denylist"; mkrepo "$dl" "git@github.com:a/denylist.git"
d() { git -C "$dl" commit -q --allow-empty -m "$1"; }
d "MDX-1 a";   d "MDX-2 b";   d "MDX-3 c"
d "ARMOR-1 a"; d "ARMOR-2 b"; d "ARMOR-3 c"
d "HTTP2-1 a"; d "HTTP2-2 b"; d "HTTP2-3 c"
d "ARM-1 a";   d "ARM-2 b";   d "ARM-3 c"
dl_out=$(cd "$dl" && "$SUT" sniff)
for k in MDX ARMOR HTTP2; do
  printf '%s\n' "$dl_out" | grep -q "^$k " \
    && ok "sniff proposes lookalike $k (contains a denylisted string)" \
    || bad "sniff dropped lookalike $k -- is -x missing?"
done
printf '%s\n' "$dl_out" | grep -q '^ARM ' \
  && bad "sniff proposed denylisted key ARM" \
  || ok "sniff still rejects genuinely denylisted ARM"

# --- documented error exit codes -----------------------------------------
errrepo="$tmp/errrepo"; mkrepo "$errrepo" "git@github.com:a/errrepo.git"
(cd "$errrepo" && "$SUT" >/dev/null 2>&1)
eq "2" "$?" "no arguments at all exits 2"
(cd "$errrepo" && "$SUT" bogus >/dev/null 2>&1)
eq "2" "$?" "unknown command exits 2"
(cd "$errrepo" && "$SUT" set --backend bogus >/dev/null 2>&1)
eq "2" "$?" "set --backend bogus (invalid value) exits 2"
(cd "$errrepo" && "$SUT" set --nope x >/dev/null 2>&1)
eq "2" "$?" "set --nope (unknown flag) exits 2"
(cd "$errrepo" && printf 'not json' | "$SUT" set-toolmap >/dev/null 2>&1)
eq "2" "$?" "set-toolmap with invalid JSON on stdin exits 2"
(cd "$outside" && "$SUT" set --backend github >/dev/null 2>&1)
eq "3" "$?" "set outside a git repo exits 3"
(cd "$outside" && "$SUT" unset >/dev/null 2>&1)
eq "3" "$?" "unset outside a git repo exits 3"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
