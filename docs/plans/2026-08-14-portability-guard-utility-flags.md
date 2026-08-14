# Portability Guard — Utility-Flag Class + `tests/` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `tests/test-portability.sh` (added in #16) so it also rejects the
silent-divergence **utility-flag** class (`sed -i`, `readlink -f`, `base64 -w`,
`date -d`, `stat -c`, bare `timeout`) and scans `tests/*.sh` in addition to
`bin/` and `hooks/`.

**Architecture:** Purely preventive — a scan of the tree today finds **zero**
instances of any of these constructs (verified, see Baseline). The deliverable
is the guard, not a set of fixes; a green sweep is the expected outcome. The
guard becomes **self-testing**: it builds an in-temp offenders fixture and
asserts every pattern fires, and a portable fixture and asserts none false-fire,
so its own correctness is covered on every run rather than spot-checked once.

**Tech Stack:** POSIX-ish bash, `sed`/`grep -n`/`grep -E`, `mktemp -d`. Runs
under the README loop (`README.md:158`, `for t in tests/test-*.sh tests/validate-skills.sh`).

## Global Constraints

- Target platform floor: **stock macOS** (BSD userland) as well as GNU/Linux.
- **Scope:** only `tests/test-portability.sh` changes. No shipped script under
  `bin/`/`hooks/` is expected to change (per #19 Scope).
- The scanner is itself portable: patterns are plain BRE (or ERE via `grep -E`
  for the two-step `timeout` check), no GNU-only construct, no `\b`.
- Whole-line-comment stripping (`sed 's/^[[:space:]]*#.*//'`) is preserved so a
  file may still explain a rejected construct in a comment (the AC-5 convention
  #16 established).
- New expected assertion counts are recorded in this plan and the PR, the way
  `docs/plans/2026-07-22-portable-word-boundaries.md` records them.

---

## Design decisions (record these in the code comments)

**Self-match wrinkle → Option 1 (exclude `test-portability.sh` from its own
sweep).** Scanning `tests/` makes the guard match itself: its pattern-table
literals (`'\\[bBwWsS]'` etc. — verified 3 self-hits today) and, after this
change, its offenders-fixture literals (`sed -i`, `timeout 5 …`) are ordinary
code, not comments. The issue offers three resolutions; Option 1 is the cheap
default and is now *doubly* necessary because the file embeds banned constructs
both as pattern literals and as fixture content. It leaves the scanner itself
unguarded — low risk, it is the one file whose reviewers are actively thinking
about portability. Recorded in a comment per the #16 convention.

**Red-proof mechanism → committed self-test (not one-time recorded evidence).**
- *Rejected — recorded evidence only (#16 style):* run once against a fixture,
  paste the output, commit only the green sweep. Matches precedent and is
  minimal, but a purely preventive guard with **zero** live instances is exactly
  the thing that can silently rot — a pattern edited to stop matching yields a
  false-green forever, and nothing notices. That reintroduces the ticket's own
  failure shape ("the coverage existed, the platform did not").
- *Chosen — self-test:* the test builds an offenders fixture (every banned
  construct) and asserts each check goes red, plus a portable fixture (legit
  look-alikes) and asserts each check stays green, then runs the real green
  sweep. Every pattern is proven both directions on every CI run; the guard's
  own correctness is covered. Steal from the rejected option: still record the
  first green-run counts in the PR.

**Bare-`timeout` recognition → same-line `command -v` guard.** The recognized
"guarded" form is a `command -v` on the *same line* as the `timeout`
invocation — exactly how `tests/test-sdlc-backend.sh`'s `tmo()` shim is written
(`command -v timeout … then timeout "$s"`). This is line-scoped, consistent with
the rest of the scanner, and its intent is simply: **new tests should route
through the `tmo()` shim rather than call `timeout` bare.** A multi-line
`command -v` guard is not recognized; the comment says so.

**Pattern style → combined-flag BRE, mirroring #16.** `sed -[a-zA-Z]*i`,
`readlink -[a-zA-Z]*f`, etc., matching the existing `grep -[a-zA-Z]*P` style.
Known, accepted limitation (shared with #16): flags split across separate args
(`sed -n -i`) are not caught; the realistic bad form is the simple/combined one.
Verified zero false positives against the current tree (see Baseline).

**Pattern scope → the six AC-required constructs only.** `sed -i`,
`readlink -f`, `base64 -w`, `date -d`, `stat -c`, bare `timeout`. The issue's
broader list (`sort -V`, `xargs -r`, `find -printf`, GNU BRE `\+ \? \|`,
`mapfile`/`declare -A`/`${x^^}`) is deferred: several carry real false-positive
risk (`\+`, `${x^^}`) and each needs its own justification; adding them now
widens the PR past the AC. Noted as a possible follow-up in the PR.

## Baseline

Recorded on this branch before any edit. Full suite green:

```
tests/test-cleanup-skill.sh: passed=13 failed=0
tests/test-context-tripwire.sh: passed=8 failed=0
tests/test-handoff-pickup.sh: passed=9 failed=0
tests/test-handoff-worktree.sh: passed=2 failed=0
tests/test-lint-before-push.sh: passed=24 failed=0
tests/test-portability.sh: passed=21 failed=0
tests/test-sdlc-backend.sh: passed=140 failed=0
tests/validate-skills.sh: passed=24 failed=0
```

Empirical false-positive checks already run against the comment-stripped tree
(these MUST stay clean; they are the AC-5 evidence):

- `sed -[a-zA-Z]*i`, `readlink -[a-zA-Z]*f`, `base64 -[a-zA-Z]*w`,
  `date -[a-zA-Z]*d`, `stat -[a-zA-Z]*c` → **zero hits** across `bin/`,
  `hooks/`, `tests/`.
- `date +%s` / `date +%F` → do **not** match `date -[a-zA-Z]*d`.
- Bare-`timeout` two-step (`grep -nE '(^|[^[:alnum:]_])timeout[[:space:]]' |
  grep -v 'command -v'`) → **zero** unguarded hits; `tmo()`'s guarded call and
  `gtimeout` are correctly exempt.
- The original 5 regex checks → **zero** false positives across `tests/*.sh`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `tests/test-portability.sh` | Static portability scan of shipped + test scripts, now self-testing | Modify: add utility-flag + bare-`timeout` checks, extend sweep to `tests/*.sh` with self-exclusion, add the offenders/portable self-test |

Scan surface after this change: `bin/*.sh` (1) + `hooks/*.sh` (3) +
`tests/*.sh` minus `test-portability.sh` (7) = **11 files**, **11 checks** each
(5 regex + 5 simple-utility + 1 `timeout`).

Expected assertion totals (record actuals from the run):
- Self-test: 11 offenders-red + 11 portable-green = **22**.
- Real sweep: 11 files × 11 checks + 1 file-count = **122**.
- **Total ≈ 144** (up from 21). Confirm exact numbers in Step 6.

---

### Task 1: Extend and self-test the portability guard

**Files:**
- Modify: `tests/test-portability.sh`

**Interfaces:**
- Consumes: nothing new at runtime — scans files.
- Produces: `passed=N failed=M` on stdout, non-zero exit on failure (unchanged
  contract; README runner relies on it).

- [ ] **Step 1: Write the RED-first demonstration (prove the new capability is absent)**

Before adding patterns, confirm the *current* guard is blind to the utility-flag
class — this is the "failing test." Create a throwaway offender and run the
current scanner logic against it:

```bash
fx=$(mktemp -d)
cat > "$fx/offender.sh" <<'EOF'
sed -i 's/a/b/' f
timeout 5 slow-cmd
EOF
# current guard's five patterns — none target sed -i or timeout:
for pat in '\\[bBwWsS]' '\\[<>]' '\[\[:[<>]:\]\]' 'grep .*--perl-regexp' 'grep -[a-zA-Z]*P'; do
  sed 's/^[[:space:]]*#.*//' "$fx/offender.sh" | grep -n -- "$pat"
done
echo "exit-with-old-patterns: the above found NOTHING -> the class is unguarded"
rm -rf "$fx"
```

Expected: no output from the loop — the old guard does not catch `sed -i` or a
bare `timeout`. That gap is what Task 1 closes.

- [ ] **Step 2: Rewrite `tests/test-portability.sh`**

Replace the whole file with the version below. Key additions over the #16
original: (a) a `timeout`-aware two-step check `scan_timeout`; (b) five
utility-flag patterns appended to the check table; (c) the sweep now includes
`tests/*.sh` and skips `test-portability.sh` itself; (d) a self-test that proves
every check red on an offenders fixture and green on a portable fixture.

```bash
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
# (grep -[a-zA-Z]*P style, and its known limit -- flags split across separate
# args like `sed -n -i` are not caught -- are inherited from #16 deliberately;
# the realistic bad form is the simple/combined one.)
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
# `command -v` on the same line means capability detection -- not a bare call.
# grep -E for the alternation/bracket class; still no GNU-only construct.
timeout_hits() {
  strip "$1" | grep -nE '(^|[^[:alnum:]_])timeout[[:space:]]' | grep -v 'command -v'
}

# Run every check against one file, reporting ok/bad per check.
sweep() { # file label
  local desc pat hits line
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
# it would be lost. sweep() emits OK|/BAD| lines; tally them here in this shell.
tally_sweep() { # file label
  local verdict rest
  while IFS='|' read -r verdict rest; do
    case "$verdict" in
      OK)  ok "$rest" ;;
      BAD) bad "$rest" ;;
      *)   [ -n "$verdict$rest" ] && printf '%s%s\n' "$verdict" "$rest" ;;
    esac
  done <<EOF
$(sweep "$1" "$2")
EOF
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
while IFS='|' read -r verdict rest; do
  case "$verdict" in OK) ok "$rest" ;; BAD) bad "$rest" ;; esac
done <<EOF
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
  tally_sweep "$f" "${f#$root/}"
done

# A glob that matched nothing would report a clean sweep of zero files.
if [ "$found" -ge 4 ]; then
  ok "scanned $found scripts under bin/, hooks/, tests/"
else
  bad "expected at least 4 scripts under bin/, hooks/, tests/, found $found"
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 3: Run the guard against the fixed tree**

Run: `bash tests/test-portability.sh; echo "exit=$?"`
Expected: all `ok:`, `exit=0`, `failed=0`. Record the exact `passed=` count
(≈144). No `FAIL:` lines.

- [ ] **Step 4: Prove the self-test is real (mutation check — evidence for AC-2)**

A self-test that always passes proves nothing. Confirm it goes red when a
pattern is broken, then restore:

```bash
cp tests/test-portability.sh /tmp/tp.bak
# break the sed -i pattern so it cannot match its offender:
sed 's|sed -\[a-zA-Z\]\*i|sed -ZZZZi|' tests/test-portability.sh > /tmp/tp.mut && cp /tmp/tp.mut tests/test-portability.sh
bash tests/test-portability.sh 2>&1 | grep -E 'MISSED|passed='
cp /tmp/tp.bak tests/test-portability.sh   # restore
bash tests/test-portability.sh >/dev/null && echo "restored-green"
```

Expected: the mutated run prints a `FAIL:` naming `guard MISSED sed -i …` and a
non-zero `failed=`; the restore run is green again (`restored-green`). Record
this output in the PR as the go-red evidence, mirroring #16's `passed=9 failed=2`.

- [ ] **Step 5: False-positive spot check against the real tree (evidence for AC-5)**

Run: `bash tests/test-portability.sh 2>&1 | grep -c '^FAIL:'`
Expected: `0`. The sweep covers `tests/test-sdlc-backend.sh` (the `tmo()` shim's
guarded `timeout` and `gtimeout`) and every `date +%s` in the tree, so a green
sweep is itself the proof that none of those legitimate forms trip a rule.

- [ ] **Step 6: Run the whole suite the way the README documents**

Run:
```bash
for t in tests/test-*.sh tests/validate-skills.sh; do
  printf '%s: ' "$t"; bash "$t" 2>&1 | tail -1
done
```
Expected: every line `passed=N failed=0`. Record the new `test-portability`
total and confirm all other totals are unchanged from Baseline.

- [ ] **Step 7: Commit**

```bash
git add tests/test-portability.sh
git commit -m "test(portability): guard the utility-flag class and tests/

Extend the #16 static guard to the second silent-divergence class -- sed -i,
readlink -f, base64 -w, date -d, stat -c, and bare timeout -- and scan tests/
in addition to bin/ and hooks/. No shipped script changes: the scan is green
today (zero instances), so introducing any of these later becomes a test
failure instead of a macOS-only field report.

The guard is now self-testing -- it asserts every pattern goes red on an
offenders fixture and green on a portable one -- so its own correctness is
covered rather than spot-checked once. test-portability.sh is excluded from
its own sweep (issue #19, option 1) because it embeds these constructs as
pattern and fixture literals."
```

---

## Acceptance criteria → evidence map

| Criterion (issue #19) | Step | Evidence |
|---|---|---|
| Guard rejects the utility-flag class (`sed -i`, `readlink -f`, `base64 -w`, `date -d`, `stat -c`, bare `timeout`) | 2 | Five patterns in `checks()` + `timeout_hits()`; self-test asserts each fires |
| Each added pattern proven **red** against a fixture | 2, 4 | `selftest()` offenders assertions (every run) + Step 4 mutation check recorded in PR |
| Scan covers `tests/*.sh`, self-match wrinkle resolved + explained | 2 | Sweep globs `tests/*.sh`; `test-portability.sh` self-excluded with a comment (option 1) |
| Full suite stays green; new counts recorded | 3, 6 | Suite run; `test-portability` new total recorded, others unchanged from Baseline |
| False-positive check (`date +%s` ≠ `date -d`; guarded `timeout`/`gtimeout` don't trip) | 2, 5 | `portable.sh` self-test assertions + green sweep over `test-sdlc-backend.sh` |

## Out of scope (per the issue)

Any behavioural change to `bin/`/`hooks/`. Broadening beyond the six required
constructs (`sort -V`, `xargs -r`, `find -printf`, GNU BRE `\+ \? \|`, bash-only
builtins) — possible follow-up, noted in the PR, not this ticket. Adopting a
real linter (shellcheck) instead of a grep table — its own ticket.
