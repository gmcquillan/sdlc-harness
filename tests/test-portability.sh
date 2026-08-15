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
# the fix. `-` is inside the excluded class too, so a long option ending in the
# utility name (`apt update -does`) is not a match -- and neither is a
# hyphenated wrapper (`my-sed -i`, `update-date -d`). That is judged negligible
# in practice and it buys a genuine false-positive fix: `pgrep -P 1` is
# portable and no longer trips the `grep -P` row. Two coverage boundaries
# remain and are accepted, not oversights:
#   - split flags -- `sed -n -i`, `date -u -d` -- are not caught, only the
#     combined `sed -ni` / `date -ud`;
#   - long-form GNU spellings -- `sed --in-place`, `date --date`, `base64
#     --wrap`, `stat --format`, `readlink --canonicalize` -- are not caught;
#   - ANY wrapper whose name merely ENDS IN a guarded utility name is now
#     exempt, not just the `g*` remedy binaries. For `grep -P` that means every
#     compression wrapper and the common `egrep` spelling -- `egrep -P`,
#     `zgrep -P`, `bzgrep -P`, `lzgrep -P`, `xzgrep -P` (verified: none match)
#     -- and the same holds for the other rows. They were caught before the
#     lead-in and are not any more. This is inherent, not an oversight: one
#     character class cannot both exempt `ggrep` (the portable remedy) and
#     catch `egrep`/`zgrep` (real defects), because the two are
#     indistinguishable one character to the left. The trade is judged worth
#     it: `grep -P` on a plain file is the realistic bad form, and it is still
#     caught.
# All three are follow-up territory (#19 scoped to the "at minimum" short
# forms); the wrapper case needs an explicit utility list, not a wider class.
# Whitespace between utility and flag is NOT a gap: [[:space:]][[:space:]]*
# covers a tab or any run of spaces, and the oddws fixture below asserts it.
checks() {
  cat <<'EOF'
GNU-only regex escape (\b \B \w \W \s \S)|\\[bBwWsS]
GNU-only word-boundary escape (\< \>)|\\[<>]
BSD-only word boundary ([[:<:]] [[:>:]])|\[\[:[<>]:\]\]
grep --perl-regexp (GNU-only)|(^|[^[:alnum:]_-])grep[[:space:]].*--perl-regexp
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
#
# The six utility rows carry the COMBINED flag form (`sed -ni`, `stat -Lc`),
# because that is the half of the pattern nothing else exercises. Each utility
# pattern is `-[a-zA-Z]*<letter>`, and the `[a-zA-Z]*` exists solely to reach a
# flag letter that is clustered behind other letters. A fixture that only ever
# spelled the SIMPLE form (`sed -i`) left that portion dead: the whole
# `[a-zA-Z]*` could be deleted from five of the six rows and the self-test
# stayed green while `sed -ni`, `readlink -nf`, `base64 -iw0`, `date -ud` and
# `stat -Lc` -- all genuinely broken on BSD -- shipped unguarded. The SIMPLE
# form is not lost: oddws.sh below spells every one of these the short way, so
# the two fixtures cover the two shapes between them without either file
# gaining a second line for the same check (the line-bound assertions require
# exactly one line per check per fixture).
#
# Every combined cluster here is a form that really appears and really breaks:
# BSD `sed -i` eats the next arg as a suffix; macOS has no `readlink -f`; macOS
# `base64 -i` takes an input FILE, so `-iw0` reads a file named `w0`; BSD
# `date -d` is the daylight-savings flag, not --date; BSD `stat` has no -c.
cat > "$fx/offenders.sh" <<'EOF'
grep -o '\bword\b' f
grep '\<word\>' f
grep '[[:<:]]word[[:>:]]' f
grep --perl-regexp 're' f
grep -oP 're' f
sed -ni 's/x/y/p' f
readlink -nf "$x"
base64 -iw0 <in >out
date -ud @1700000000
stat -Lc %s f
timeout 5 slow-cmd
EOF

# oddws: the same offenders, but with the flag separated by a tab or by two
# spaces instead of one. Every check must fire here too. This is a separate
# fixture on purpose: if these lines lived in offenders.sh the single-space
# copies would keep each check green, and a pattern that hard-codes one literal
# space would pass the self-test while silently missing the real thing.
#
# This fixture also carries the SIMPLE flag form for every utility row -- the
# counterpart to the combined forms in offenders.sh above. Splitting the two
# shapes across the two fixtures is what keeps both live without breaking the
# one-line-per-check mapping; see the offenders comment for why the combined
# half was previously untested.
cat > "$fx/oddws.sh" <<'EOF'
grep -o '\bword\b' f
grep '\<word\>' f
grep '[[:<:]]word[[:>:]]' f
grep  --perl-regexp 're' f
grep	-P 're' f
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
#     gbase64, ggrep). These are the portable *fix* -- the whole point of
#     installing them is to get GNU flag semantics on a Mac -- so a pattern
#     that matches any string merely ending in the utility name would
#     red-flag the remedy. `ggrep --perl-regexp` covers the long-form row,
#     which kept a bare `grep .*` lead-in after the rest were anchored.
#   - genuinely portable flagged forms (`sed -n`, `date -u`, `readlink -n`,
#     `base64 -d`, `stat -L`), so a pattern that lost its flag letter and
#     banned the utility's whole flag space could not slip through. `sed -n`
#     earns its place late: without it, broadening the sed row to
#     `sed[[:space:]][[:space:]]*-` was caught only by one incidental
#     `sed -n` on a real scanned file (tests/validate-skills.sh) -- rewrite
#     that one line to awk and the mutation went fully green. `stat -f` and
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
sed -n '1p' f
date -u
readlink -n "$x"
base64 -d <in >out
stat -L "$x"
gsed -i 's/a/b/' f
ggrep --perl-regexp 're' f
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

# Both offender fixtures are laid out one line per check, in checks() order:
# fixture line N is the construct for check N (offenders.sh carries one extra
# trailing line, nchecks+1, for the bare-timeout check, asserted separately
# below -- that assertion derives its line number rather than spelling it out).
# Assertions are bound to that line number, not merely to "matched somewhere":
# an unbound assertion passes when a pattern cross-matches a *sibling's*
# fixture line, which is exactly what an ordinary copy-paste row misalignment
# produces. The three regex-escape checks are the live risk -- they carry no
# command-name prefix, so nothing else anchors them to their own construct,
# and a row that silently inherits its neighbour's pattern would still print
# "guard catches ..." while the class it names went completely unguarded.
# Comparing the whole matched-line list (not just its first entry) also fails
# a pattern that hits its own line *and* a sibling's.
hit_lines() { # file pattern -> space-free list of matching line numbers
  simple_hits "$1" "$2" | cut -d: -f1 | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# The eleven "no false positive for ..." rows in selftest() are NEGATIVE
# assertions: each passes when its pattern matches nothing in portable.sh. A
# fixture that was never written -- a mangled here-doc terminator, a typo'd
# redirect target, a bad rebase that dropped the block -- therefore satisfies
# every one of them, and the suite prints its healthy `passed=` while those
# eleven rows prove precisely nothing. That is not hypothetical: with
# portable.sh absent, four of the utility patterns could be broadened to their
# bare `date -` / `readlink -` / `base64 -` / `stat -` form and the self-test
# still reported every assertion green. The offender fixtures are
# self-protecting -- they drive POSITIVE assertions, which go MISSED -- but
# only against total loss; a truncated one silently drops the checks whose
# lines went with it.
#
# So each fixture gets a positive control before anything reads it: it must
# exist and be non-empty, it must have exactly the expected number of lines,
# and a probe must match one specific line near the end of it. A missing,
# empty, truncated or half-written fixture now fails that control loudly
# instead of passing quietly. The probe deliberately goes through simple_hits()
# -- the same strip-then-grep path the real assertions use -- so a break in
# that path fails the control too, and it is deliberately unlike any checks()
# row so that it stays a test of the FIXTURE rather than a duplicate of the
# assertions it protects.
#
# The two offender fixtures derive their expected length from nchecks: that is
# the 1:1 fixture-line-to-check mapping every line-bound assertion depends on,
# asserted outright instead of assumed. portable.sh carries no such mapping, so
# its length is a literal -- bump it (and the probe's line, if the probe moves)
# when a portable look-alike is added. `grep -c ''` counts lines rather than
# `wc -l`, which pads its output with leading blanks on BSD.
fixture_control() { # file label expected_lines probe expected_probe_line
  local file=$1 label=$2 want_lines=$3 probe=$4 want_line=$5 got
  if [ ! -s "$file" ]; then
    bad "fixture control: $label is missing or empty -- every assertion that reads it would pass vacuously"
    return
  fi
  got=$(grep -c '' "$file")
  if [ "$got" != "$want_lines" ]; then
    bad "fixture control: $label has $got lines, expected $want_lines -- it is truncated or has gained a line, so the line-bound assertions are reading the wrong rows"
    return
  fi
  got=$(hit_lines "$file" "$probe")
  if [ "$got" != "$want_line" ]; then
    bad "fixture control: $label probe matched line(s) [$got], expected only line $want_line -- the fixture was not written as intended"
    return
  fi
  ok "fixture control: $label present, $want_lines lines, probe matches line $want_line"
}

# Assert each check fires on its own offender line and is silent on portable.
selftest() {
  local desc pat n got tline
  n=0
  checks | while IFS='|' read -r desc pat; do
    n=$((n+1))
    got=$(hit_lines "$fx/offenders.sh" "$pat")
    if [ "$got" = "$n" ]; then
      echo "OK|self-test: guard catches $desc on offenders line $n"
    elif [ -z "$got" ]; then
      echo "BAD|self-test: guard MISSED $desc in the offenders fixture"
    else
      echo "BAD|self-test: $desc matched offenders line(s) [$got], expected only line $n -- the pattern is cross-matching another check's construct"
    fi
    got=$(hit_lines "$fx/oddws.sh" "$pat")
    if [ "$got" = "$n" ]; then
      echo "OK|self-test: guard catches $desc across tab/double-space on oddws line $n"
    elif [ -z "$got" ]; then
      echo "BAD|self-test: guard MISSED $desc when the flag is tab/double-space separated"
    else
      echo "BAD|self-test: $desc matched oddws line(s) [$got], expected only line $n -- the pattern is cross-matching another check's construct"
    fi
    [ -z "$(simple_hits "$fx/portable.sh" "$pat")" ] \
      && echo "OK|self-test: no false positive for $desc" \
      || echo "BAD|self-test: false positive for $desc on portable code"
  done
  # Same line-binding for the bare-timeout check: its construct is the line
  # straight after the per-check rows, so derive it from the table size instead
  # of hard-coding it. A literal here is a fifth thing to update in lockstep
  # when a check is added -- checks(), both fixtures, the table floor, and this
  # -- and the one that gets forgotten reports a *timeout* misalignment, which
  # points at the wrong row entirely.
  tline=$((nchecks + 1))
  got=$(timeout_hits "$fx/offenders.sh" | cut -d: -f1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  if [ "$got" = "$tline" ]; then
    echo "OK|self-test: guard catches bare timeout on offenders line $tline"
  elif [ -z "$got" ]; then
    echo "BAD|self-test: guard MISSED bare timeout in the offenders fixture"
  else
    echo "BAD|self-test: bare timeout matched offenders line(s) [$got], expected only line $tline"
  fi
  [ -z "$(timeout_hits "$fx/portable.sh")" ] \
    && echo "OK|self-test: no false positive for bare timeout (tmo/gtimeout)" \
    || echo "BAD|self-test: false positive for bare timeout on guarded/gtimeout code"
}

# The check table is a here-doc, and the shell does not validate here-doc
# contents: a botched merge-conflict resolution or rebase can delete rows from
# checks() without producing a syntax error or any other symptom. selftest()
# iterates that same table, so its assertions disappear along with the rows --
# the one mechanism that should catch the loss is coupled to the thing that
# breaks, and the suite exits 0 with a smaller `passed=` while the whole class
# these checks exist to catch goes unguarded. There is no CI here, so nobody is
# diffing that number. Assert the floor explicitly instead. Bump the 10 when a
# check is added; a deliberate removal has to edit this line, which is the
# point. `grep -c '|'` counts only well-formed "desc|pattern" rows.
nchecks=$(checks | grep -c '|')
if [ "$nchecks" -ge 10 ]; then
  ok "check table has $nchecks checks"
else
  bad "check table shrank: expected at least 10 checks, found $nchecks"
fi

# Fixture controls run BEFORE selftest() so a broken fixture is reported as the
# cause rather than as a wall of downstream misalignments. Both offender
# fixtures put their probe on their own last line, so length and probe line are
# the same number for them; portable.sh's probe is `gtimeout`, one of the
# brew-coreutils remedy binaries the negative assertions exist to protect.
fixture_control "$fx/offenders.sh" offenders.sh "$((nchecks + 1))" 'slow-cmd' "$((nchecks + 1))"
fixture_control "$fx/oddws.sh"     oddws.sh     "$nchecks"         '%s'       "$nchecks"
fixture_control "$fx/portable.sh"  portable.sh  23                 'gtimeout' 20

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
found=0; found_bin=0; found_hooks=0; found_tests=0
for f in "$root"/bin/*.sh "$root"/hooks/*.sh "$root"/tests/*.sh; do
  [ -f "$f" ] || continue
  case "$f" in */test-portability.sh) continue ;; esac
  found=$((found+1))
  # "$root" MUST stay quoted inside the expansion: unquoted, the prefix is read
  # as a glob pattern, so any bracket metacharacter in the checkout path defeats
  # the strip (shellcheck SC2295). The bracketed-path assertion below guards it.
  rel="${f#"$root"/}"
  case "$rel" in
    bin/*)   found_bin=$((found_bin+1)) ;;
    hooks/*) found_hooks=$((found_hooks+1)) ;;
    tests/*) found_tests=$((found_tests+1)) ;;
  esac
  tally <<EOF
$(sweep "$f" "$rel")
EOF
done

# A glob that matched nothing would report a clean sweep of zero files. The
# floor is PER DIRECTORY, not a total: bin/ (1 file) and hooks/ (3) already met
# a flat `found >= 4` on their own, so the tests/ widening that #19 exists to
# deliver had no floor protection at all -- move the real tests into a
# tests/unit/ subdirectory and the run still printed a clean green sweep having
# scanned no test file. A raised flat floor would not fix that: it needs
# bumping on every file added or removed, and one directory can still go to
# zero while another covers for it. A per-directory floor has neither problem.
#
# Be clear about the size of what this buys, though. The floor is `>= 1`, so it
# catches only the TOTAL loss of a directory. PARTIAL loss stays invisible:
# rename one script to .bash, or relocate one helper into tests/fixtures/, and
# the remaining files keep the count above zero -- the run prints
# "scanned 6 script(s) under tests/", exits 0, and the construct in the file
# that dropped out is never scanned. Catching that needs a per-file inventory
# (or a count assertion that has to be bumped on every add), which is out of
# scope here; the floor is a tripwire on a directory disappearing, not a
# guarantee that every script in it was seen.
dir_floor() { # dir count
  if [ "$2" -ge 1 ]; then
    ok "scanned $2 script(s) under $1/"
  else
    bad "scanned no scripts under $1/ -- that glob matched nothing, so the directory went unscanned"
  fi
}
dir_floor bin "$found_bin"
dir_floor hooks "$found_hooks"
dir_floor tests "$found_tests"
echo "scanned $found scripts under bin/, hooks/, tests/"

# --- Regression: the sweep must survive glob metacharacters in the repo path. --
# `rel` is produced by stripping "$root/" off the front of "$f". If the prefix is
# left unquoted inside the expansion (`${f#$root/}`) the shell reads it as a GLOB
# PATTERN, not as literal text -- so a checkout whose path contains bracket
# metacharacters (a git worktree named `w[1]`, say) fails to strip, `rel` stays
# absolute, none of the bin/*|hooks/*|tests/* arms above match, and all three
# per-directory floors report "scanned no scripts" on a tree that in fact scanned
# every file. Quoting inside the expansion is the fix (shellcheck SC2295); this
# assertion is what keeps it quoted. It re-runs this very script from a copy
# rooted at a bracketed directory and checks the floors still pass.
# SDLC_PORTABILITY_NESTED is what stops that inner run from recursing here for
# ever; it is set only by this block and means nothing outside it.
if [ -z "${SDLC_PORTABILITY_NESTED:-}" ]; then
  meta="$fx/w[1]"
  mkdir -p "$meta/bin" "$meta/hooks" "$meta/tests"
  for d in bin hooks tests; do
    printf '%s\n' '#!/bin/sh' 'echo probe' > "$meta/$d/probe.sh"
  done
  cp "$here/${0##*/}" "$meta/tests/test-portability.sh"
  nested=$(SDLC_PORTABILITY_NESTED=1 bash "$meta/tests/test-portability.sh" 2>&1)
  missing=""
  for d in bin hooks tests; do
    case "$nested" in
      *"ok: scanned 1 script(s) under $d/"*) ;;
      *) missing="$missing $d" ;;
    esac
  done
  if [ -z "$missing" ]; then
    ok "per-directory floors survive glob metacharacters in the repo path"
  else
    bad "per-directory floors broke under a repo path containing glob metacharacters (nothing counted for:$missing) -- the \$root prefix strip is being read as a pattern instead of literal text"
  fi
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
