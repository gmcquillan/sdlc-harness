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

# Simple checks: one ERE, any match is a violation. Emitted as "$desc|$pattern".
# (The -[a-zA-Z]*P style is inherited from #16 deliberately; the realistic bad
# form is the simple/combined one.) Each utility pattern is bounded on the left
# by (^|[^[:alnum:]_-]) -- the same lead-in idiom as timeout_hits() below and as
# tests/validate-skills.sh -- so it matches the utility as a word rather than
# any string that merely ends in its name. That deliberately exempts the
# brew-coreutils `g*` binaries (`gsed -i`, `gdate -d`, ...): those are the
# portable *remedy* on a Mac, not the defect, and flagging them would punish
# the fix. `-` is inside the excluded class, so a long option ending in the
# utility name (`apt update -does`) is likewise not a match. Two coverage
# boundaries remain and are accepted, not oversights:
#   - split flags -- `sed -n -i`, `date -u -d` -- are not caught, only the
#     combined `sed -ni` / `date -ud`;
#   - long-form GNU spellings -- `sed --in-place`, `date --date`, `base64
#     --wrap`, `stat --format`, `readlink --canonicalize` -- are not caught.
# Both are follow-up territory (#19 scoped to the "at minimum" short forms).
# Whitespace between utility and flag is NOT a gap: [[:space:]][[:space:]]*
# covers a tab or any run of spaces, and the oddws fixture below asserts it.
checks() {
  cat <<'EOF'
GNU-only regex escape (\b \B \w \W \s \S)|\\[bBwWsS]
GNU-only word-boundary escape (\< \>)|\\[<>]
BSD-only word boundary ([[:<:]] [[:>:]])|\[\[:[<>]:\]\]
grep --perl-regexp (GNU-only)|grep .*--perl-regexp
grep -P (GNU-only)|(^|[^[:alnum:]_-])grep[[:space:]][[:space:]]*-[a-zA-Z]*P
sed -i, BSD needs a mandatory suffix arg|(^|[^[:alnum:]_-])sed[[:space:]][[:space:]]*-[a-zA-Z]*i
readlink -f, absent on stock macOS|(^|[^[:alnum:]_-])readlink[[:space:]][[:space:]]*-[a-zA-Z]*f
base64 -w, GNU-only wrap flag|(^|[^[:alnum:]_-])base64[[:space:]][[:space:]]*-[a-zA-Z]*w
date -d, GNU (BSD is -v / -j -f)|(^|[^[:alnum:]_-])date[[:space:]][[:space:]]*-[a-zA-Z]*d
stat -c, GNU (BSD is -f)|(^|[^[:alnum:]_-])stat[[:space:]][[:space:]]*-[a-zA-Z]*c
EOF
}

# Return the comment-stripped hits for a simple check (empty = clean).
# -E, not the default BRE: the lead-in anchor above is an alternation, and BRE
# spells that `\|`, which is a GNU extension -- one of the very things this file
# bans. -E is POSIX. The three regex-escape patterns are unaffected by the
# switch (`\\`, `\[`, `\]` and bracket expressions mean the same in both).
# `--` still guards a pattern that starts with `-`.
simple_hits() { strip "$1" | grep -nE -- "$2"; }

# `timeout` needs a two-step check: flag it invoked as a command, but exempt the
# tmo() shim, which guards every call with a same-line `command -v`. The lead-in
# char must be neither a word char nor `$` nor `-`, so `gtimeout`, a `$timeout`
# variable reference and a long option that merely ends in the word (curl's
# `--connect-timeout`) are all excluded; whitespace must follow so the word
# `timeout` in trailing prose (or a `timeout=5` assignment) is not a match.
# The `-` must stay last inside the bracket expression or it reads as a range.
# `command -v` anywhere on the line means capability detection -- not a bare
# call; that exemption is line-global (a stray `command -v` for an unrelated
# reason would also exempt) and a multi-line guard is not recognised, so new
# tests should route through the tmo() shim rather than call timeout directly.
# grep -E for the alternation/bracket class; still no GNU-only construct.
timeout_hits() {
  strip "$1" | grep -nE '(^|[^[:alnum:]_$-])timeout[[:space:]]' | grep -v 'command -v'
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

# oddws: the same offenders, but with the flag separated by a tab or by two
# spaces instead of one. Every check must fire here too. This is a separate
# fixture on purpose: if these lines lived in offenders.sh the single-space
# copies would keep each check green, and a pattern that hard-codes one literal
# space would pass the self-test while silently missing the real thing.
cat > "$fx/oddws.sh" <<'EOF'
grep -o '\bword\b' f
grep '\<word\>' f
grep '[[:<:]]word[[:>:]]' f
grep  --perl-regexp 're' f
grep	-oP 're' f
sed  -i 's/a/b/' f
readlink	-f "$x"
base64  -w0 <in >out
date	-d @1700000000
stat  -c %s f
EOF

# portable: legit look-alikes. No check may fire here. Covers the AC-5 traps --
# `date +%s` vs `date -d`, and the tmo() same-line guard / `gtimeout` vs bare
# `timeout` -- plus a plain form for each other construct.
#
# Two families of near-miss earn their place here:
#   - the brew-coreutils `g*` binaries (gsed, gdate, gstat, greadlink,
#     gbase64). These are the portable *fix* -- the whole point of installing
#     them is to get GNU flag semantics on a Mac -- so a pattern that matches
#     any string merely ending in the utility name would red-flag the remedy.
#   - genuinely portable flagged forms (`date -u`, `readlink -n`, `base64 -d`,
#     `stat -L`), so a pattern that lost its flag letter and banned the
#     utility's whole flag space could not slip through. `stat -f` and
#     `date -r <epoch>` are NOT in here and must not be added: BSD `stat -f`
#     takes a format string where GNU `-f` reports the filesystem, and BSD
#     `date -r` accepts an epoch where GNU `-r` takes a file. Same letter,
#     different meaning -- exactly what this guard exists to catch.
cat > "$fx/portable.sh" <<'EOF'
grep -oE '^[A-Z]+' f
tr -cs 'A-Za-z0-9_-' '\n' <f
sed 's/a/b/' f
readlink "$x"
base64 <in >out
date +%s; date +%F
stat "$x"
date -u
readlink -n "$x"
base64 -d <in >out
stat -L "$x"
gsed -i 's/a/b/' f
greadlink -f "$x"
gbase64 -w0 <in >out
gdate -d @1700000000
gstat -c %s f
command -v timeout >/dev/null 2>&1 && timeout 5 slow-cmd
gtimeout 5 slow-cmd
curl --connect-timeout 5 https://x
timeout=5
echo "waited $timeout seconds"
EOF

# Assert each check fires on offenders and is silent on portable.
selftest() {
  local desc pat
  checks | while IFS='|' read -r desc pat; do
    [ -n "$(simple_hits "$fx/offenders.sh" "$pat")" ] \
      && echo "OK|self-test: guard catches $desc" \
      || echo "BAD|self-test: guard MISSED $desc in the offenders fixture"
    [ -n "$(simple_hits "$fx/oddws.sh" "$pat")" ] \
      && echo "OK|self-test: guard catches $desc across tab/double-space" \
      || echo "BAD|self-test: guard MISSED $desc when the flag is tab/double-space separated"
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
