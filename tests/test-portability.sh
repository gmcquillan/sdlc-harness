#!/usr/bin/env bash
# Shipped scripts AND the test suite must run on stock macOS (BSD userland) as
# well as GNU. Two classes of construct diverge *silently* between the two --
# they do not error on the wrong platform, they just stop matching or corrupt
# quietly -- so a Linux dev box cannot catch them behaviourally. This scan is
# the only thing standing between that class of bug and a release.
#
# Class 1 -- regex: `\b` is a GNU extension; `[[:<:]]`/`[[:>:]]` is the BSD-only
# counterpart. Neither is portable; both are banned -- see cmd_sniff in
# bin/sdlc-backend.sh for the construct to use instead.
#
# Class 2 -- utility flags (#19): `sed -i` needs a mandatory suffix arg on BSD
# and none on GNU; `readlink -f` is absent on stock macOS; `base64 -w` is
# GNU-only; `date -d` is GNU where BSD spells it -v / -j -f; `stat -c` is GNU
# where BSD is -f; and `timeout` does not exist on stock macOS at all (it is
# gtimeout, brew-only) -- use the tmo() shim in tests/test-sdlc-backend.sh.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Whole-line comments are stripped before scanning, and deliberately so: a fix
# is REQUIRED to explain in a comment why `\b` and `[[:<:]]` were both rejected,
# and scanning prose would make that explanation illegal. `sed` blanks the line
# rather than deleting it, so `grep -n` still reports true line numbers.
# Trailing comments after code are NOT stripped -- keep prose about these
# constructs on its own line. \\ matches one literal backslash.
strip() { sed 's/^[[:space:]]*#.*//' "$1" 2>/dev/null; }

# Simple checks: one BRE, any match is a violation. Emitted as "$desc|$pattern".
# (The grep -[a-zA-Z]*P style, and its known limit -- flags split across
# separate args like `sed -n -i` are not caught -- are inherited from #16
# deliberately; the realistic bad form is the simple/combined one.)
checks() {
  cat <<'EOF'
GNU-only regex escape (\b \B \w \W \s \S)|\\[bBwWsS]
GNU-only word-boundary escape (\< \>)|\\[<>]
BSD-only word boundary ([[:<:]] [[:>:]])|\[\[:[<>]:\]\]
grep --perl-regexp (GNU-only)|grep .*--perl-regexp
grep -P (GNU-only)|grep -[a-zA-Z]*P
sed -i, BSD needs a mandatory suffix arg|sed -[a-zA-Z]*i
readlink -f, absent on stock macOS|readlink -[a-zA-Z]*f
base64 -w, GNU-only wrap flag|base64 -[a-zA-Z]*w
date -d, GNU (BSD is -v / -j -f)|date -[a-zA-Z]*d
stat -c, GNU (BSD is -f)|stat -[a-zA-Z]*c
EOF
}

# Return the comment-stripped hits for a simple check (empty = clean).
simple_hits() { strip "$1" | grep -n -- "$2"; }

# `timeout` needs a two-step check: flag it invoked as a command, but exempt the
# tmo() shim, which guards every call with a same-line `command -v`. A non-word
# char (or start of line) must precede `timeout` so `gtimeout` is not a match,
# and whitespace must follow so the word `timeout` in trailing prose is not one.
# `command -v` on the same line means capability detection -- not a bare call;
# a multi-line guard is not recognised, so new tests should route through tmo().
# grep -E for the alternation/bracket class; still no GNU-only construct.
timeout_hits() {
  strip "$1" | grep -nE '(^|[^[:alnum:]_])timeout[[:space:]]' | grep -v 'command -v'
}

# Run every check against one file, emitting OK|/BAD| lines (tallied by caller).
sweep() { # file label
  local desc pat hits
  checks | while IFS='|' read -r desc pat; do
    hits=$(simple_hits "$1" "$pat")
    if [ -n "$hits" ]; then
      echo "BAD|$2: $desc"; printf '%s\n' "$hits" | sed 's/^/      /'
    else
      echo "OK|$2: no $desc"
    fi
  done
  hits=$(timeout_hits "$1")
  if [ -n "$hits" ]; then
    echo "BAD|$2: bare timeout (use the tmo() shim)"; printf '%s\n' "$hits" | sed 's/^/      /'
  else
    echo "OK|$2: no bare timeout"
  fi
}

# A `while read` in a pipe runs in a subshell, so pass/fail counters set inside
# it would be lost. sweep() emits OK|/BAD| lines; tally them in this shell via a
# here-doc so ok()/bad() run in the parent and the counters persist.
tally() { # reads OK|/BAD| lines on stdin
  local verdict rest
  while IFS='|' read -r verdict rest; do
    case "$verdict" in
      OK)  ok "$rest" ;;
      BAD) bad "$rest" ;;
      *)   [ -n "$verdict$rest" ] && printf '%s%s\n' "$verdict" "$rest" ;;
    esac
  done
}

# --- Self-test: the guard must catch what it exists to catch, and only that. --
# A green scan proves nothing unless it goes red on the constructs it bans and
# stays green on their portable look-alikes. Fixtures live in a temp dir so
# their banned literals are never part of the real sweep. (This file is excluded
# from the sweep for the same reason -- see the loop below.)
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT

# offenders: one line per banned construct. Every check must fire here.
cat > "$fx/offenders.sh" <<'EOF'
grep -o '\bword\b' f
grep '\<word\>' f
grep '[[:<:]]word[[:>:]]' f
grep --perl-regexp 're' f
grep -oP 're' f
sed -i 's/a/b/' f
readlink -f "$x"
base64 -w0 <in >out
date -d @1700000000
stat -c %s f
timeout 5 slow-cmd
EOF

# portable: legit look-alikes. No check may fire here. Covers the AC-5 traps --
# `date +%s` vs `date -d`, and the tmo() same-line guard / `gtimeout` vs bare
# `timeout` -- plus a plain form for each other construct.
cat > "$fx/portable.sh" <<'EOF'
grep -oE '^[A-Z]+' f
tr -cs 'A-Za-z0-9_-' '\n' <f
sed 's/a/b/' f
readlink "$x"
base64 <in >out
date +%s; date +%F
stat "$x"
command -v timeout >/dev/null 2>&1 && timeout 5 slow-cmd
gtimeout 5 slow-cmd
EOF

# Assert each check fires on offenders and is silent on portable.
selftest() {
  local desc pat
  checks | while IFS='|' read -r desc pat; do
    [ -n "$(simple_hits "$fx/offenders.sh" "$pat")" ] \
      && echo "OK|self-test: guard catches $desc" \
      || echo "BAD|self-test: guard MISSED $desc in the offenders fixture"
    [ -z "$(simple_hits "$fx/portable.sh" "$pat")" ] \
      && echo "OK|self-test: no false positive for $desc" \
      || echo "BAD|self-test: false positive for $desc on portable code"
  done
  [ -n "$(timeout_hits "$fx/offenders.sh")" ] \
    && echo "OK|self-test: guard catches bare timeout" \
    || echo "BAD|self-test: guard MISSED bare timeout in the offenders fixture"
  [ -z "$(timeout_hits "$fx/portable.sh")" ] \
    && echo "OK|self-test: no false positive for bare timeout (tmo/gtimeout)" \
    || echo "BAD|self-test: false positive for bare timeout on guarded/gtimeout code"
}
tally <<EOF
$(selftest)
EOF

# --- Real sweep over the shipped scripts and the test suite. ------------------
# tests/ is included (#19): a non-portable construct in a *test* would otherwise
# only surface on a Mac -- tests/test-sdlc-backend.sh ships a tmo() shim exactly
# because stock macOS has no `timeout`, but nothing scanned for a bare one.
# test-portability.sh is skipped: its pattern table and offenders fixture embed
# these constructs as literals, so it necessarily matches itself. Excluding it
# (issue #19, option 1) is the cheapest of the three options -- the scanner is
# the one file whose reviewers are already thinking about portability.
found=0
for f in "$root"/bin/*.sh "$root"/hooks/*.sh "$root"/tests/*.sh; do
  [ -f "$f" ] || continue
  case "$f" in */test-portability.sh) continue ;; esac
  found=$((found+1))
  tally <<EOF
$(sweep "$f" "${f#$root/}")
EOF
done

# A glob that matched nothing would report a clean sweep of zero files.
if [ "$found" -ge 4 ]; then
  ok "scanned $found scripts under bin/, hooks/, tests/"
else
  bad "expected at least 4 scripts under bin/, hooks/, tests/, found $found"
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
