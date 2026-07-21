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

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
