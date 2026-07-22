#!/usr/bin/env bash
# Shipped scripts must run on stock macOS (BSD userland) as well as GNU.
# The regex constructs below are the ones that differ silently between the
# two: they do not error on the wrong platform, they just stop matching, so
# a Linux dev box cannot catch them by running the behavioural tests. This
# scan is the only thing standing between that class of bug and a release.
#
# `\b` is a GNU extension; `[[:<:]]`/`[[:>:]]` is the BSD-only counterpart.
# Neither is portable, so both are banned -- see cmd_sniff in
# bin/sdlc-backend.sh for the construct to use instead.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Whole-line comments are stripped before scanning, and deliberately so:
# the fix these scripts carry is REQUIRED to explain in a comment why `\b`
# and `[[:<:]]` were both rejected, and scanning prose would make that
# explanation illegal. `sed` blanks the line rather than deleting it, so
# `grep -n` still reports true line numbers. Trailing comments after code
# are NOT stripped -- keep prose about these constructs on its own line.
#
# Every construct is matched with a plain BRE so this scanner is itself
# portable. \\ matches one literal backslash.
scan() { # file label pattern description
  local hits
  hits=$(sed 's/^[[:space:]]*#.*//' "$1" 2>/dev/null | grep -n -- "$3")
  if [ -n "$hits" ]; then
    bad "$2: $4"
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    ok "$2: no $4"
  fi
}

found=0
for f in "$root"/bin/*.sh "$root"/hooks/*.sh; do
  [ -f "$f" ] || continue
  found=$((found+1))
  label="${f#$root/}"
  scan "$f" "$label" '\\[bBwWsS]'      'GNU-only regex escape (\b \B \w \W \s \S)'
  scan "$f" "$label" '\\[<>]'          'GNU-only word-boundary escape (\< \>)'
  scan "$f" "$label" '\[\[:[<>]:\]\]'  'BSD-only word boundary ([[:<:]] [[:>:]])'
  scan "$f" "$label" 'grep .*--perl-regexp' 'grep --perl-regexp (GNU-only)'
  scan "$f" "$label" 'grep -[a-zA-Z]*P' 'grep -P (GNU-only)'
done

# A glob that matched nothing would report a clean sweep of zero files.
if [ "$found" -ge 2 ]; then
  ok "scanned $found shipped scripts"
else
  bad "expected at least 2 shipped scripts under bin/ and hooks/, found $found"
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
