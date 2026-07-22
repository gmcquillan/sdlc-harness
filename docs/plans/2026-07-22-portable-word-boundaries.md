# Portable Word Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every GNU-only regex extension from the shipped scripts under
`bin/` and `hooks/`, preserving behaviour exactly, and add a static test so the
gap cannot reopen from a Linux dev box.

**Architecture:** There is no word-boundary operator both GNU and BSD `grep`
accept — `\b` is GNU-only, `[[:<:]]`/`[[:>:]]` is BSD-only. Rather than pick a
spelling, both call sites stop *needing* a boundary operator: a `tr` pass first
splits the stream on characters that cannot appear inside the token of
interest, which turns "is this on a word boundary?" into "is this the whole
token?" — expressible with plain POSIX `^`/`$` anchors. A third task adds a
grep-based portability guard over `bin/*.sh` and `hooks/*.sh`.

**Tech Stack:** POSIX shell, `tr`/`grep -E`/`sed`/`awk`, bash test scripts in
`tests/` run by the README's loop (`for t in tests/test-*.sh tests/validate-skills.sh`).

## Global Constraints

- Target platform floor: **stock macOS** (BSD userland) as well as GNU/Linux.
  `tests/test-sdlc-backend.sh` states the SUT is "deliberately BSD/macOS-portable".
- **No GNU-only regex extensions** in any shipped script under `bin/` or `hooks/`:
  `\b`, `\B`, `\<`, `\>`, `\w`, `\W`, `\s`, `\S`, `grep -P`/`--perl-regexp`.
  Also no BSD-only `[[:<:]]` / `[[:>:]]`.
- `sniff` must return **the same keys, ranks, and counts** it returns today.
  The existing assertions in `tests/test-sdlc-backend.sh` pass unchanged; no
  assertion may be weakened to accommodate a new pattern.
- The denylist (`grep -vxE "$SNIFF_DENYLIST"`) and the 3-hit floor
  (`awk '$1 >= 3'`) must still reject/suppress — no boundary character may leak
  into their input.
- The chosen construct is recorded in a comment beside the regex, naming why
  `\b` and `[[:<:]]` were both rejected.
- New test files must be named `tests/test-*.sh` so the documented runner
  (`README.md:138`) collects them automatically.

## Baseline

Recorded on this branch before any edit — 170 assertions, 0 failures:

```
tests/test-cleanup-skill.sh: 13 ok, 0 FAIL
tests/test-context-tripwire.sh: 8 ok, 0 FAIL
tests/test-handoff-pickup.sh: 9 ok, 0 FAIL
tests/test-handoff-worktree.sh: 2 ok, 0 FAIL
tests/test-lint-before-push.sh: 9 ok, 0 FAIL
tests/test-sdlc-backend.sh: 109 ok, 0 FAIL
tests/validate-skills.sh: 20 ok, 0 FAIL
```

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `bin/sdlc-backend.sh` | `cmd_sniff` key-extraction pipeline (line ~216) | Modify: replace `grep -oE '\b…\b'` with `tr` + anchored `grep -E` + `sed` |
| `hooks/lint-before-push.sh` | `git push` detection gate (line 14) | Modify: replace `grep -Eq '\bgit\b…\bpush\b'` with `tr` + bracket-class `grep -Eq` |
| `tests/test-sdlc-backend.sh` | 109 assertions over the backend script | Modify: add boundary-fidelity assertions to the sniff section |
| `tests/test-lint-before-push.sh` | 9 assertions over the hook | Modify: add word-boundary discrimination assertions |
| `tests/test-portability.sh` | **New.** Static scan of `bin/*.sh` + `hooks/*.sh` for non-portable regex constructs | Create |

### Why a new test file rather than folding into `validate-skills.sh`

The issue's Scope line offers `tests/test-sdlc-backend.sh` and/or
`tests/validate-skills.sh`. Neither fits: `validate-skills.sh` validates
`skills/*/SKILL.md` and knows nothing about `bin/` or `hooks/`, and
`test-sdlc-backend.sh` is scoped to one script while the constraint covers the
whole shipped surface. `tests/test-portability.sh` is collected by the same
documented runner glob, so this costs no wiring.

## Design decisions (record these in the code comments)

**Rejected — `\b`:** GNU extension. POSIX ERE leaves `\<ordinary-char>`
undefined; on BSD `grep` it most likely matches a literal `b`, so the pipeline
silently yields nothing and `sniff` looks like "this repo has no JIRA keys".

**Rejected — `[[:<:]]` / `[[:>:]]`:** the BSD spelling; not accepted by GNU
`grep`. Swapping one platform's breakage for the other's is not a fix.

**Rejected — bracket class `(^|[^[:alnum:]_])…([^[:alnum:]_]|$)` with `grep -o`**
(the issue's option 1, naive form). Measured against the GNU baseline:

```
input:  BODYKEY-1 BODYKEY-2 BODYKEY-3
        fix UTF-8 and CVE-2024-1234 and RFC-3339

GNU \b baseline        -> 3 BODYKEY, 1 CVE, 1 UTF, 1 RFC
bracket class + -o     -> 1 "BODYKEY-1 ", 1 " BODYKEY", 1 " CVE-2024", 1 " UTF-8 "
```

Two independent failures: `-o` **consumes** the trailing boundary character, so
that character is unavailable as the *leading* boundary of the next key and
adjacent keys under-count (3 → 2); and the consumed character rides through
`sed` into `grep -vxE "$SNIFF_DENYLIST"`, where `" CVE-2024"` no longer equals
`CVE` and the denylist stops rejecting it. Any fix must drop `-o`, not merely
re-spell the boundary.

**Chosen — pre-tokenise with `tr`, then anchor.** `tr -cs 'A-Za-z0-9_-' '\n'`
puts each candidate token on its own line, so the leading boundary is `^` and
`grep` needs no boundary operator at all. Verified byte-identical to the GNU
baseline across adjacency, multi-hyphen (`CVE-2024-1234`), leading letter
(`XPROJ-123`), leading underscore (`_PROJ-9`), leading digit (`9PROJ-8`),
trailing letters (`PROJ-123abc`), path separators (`feature/BRANCHY-1`), and
`ABC-123-456` / `AB-C-1` / `ABC-1DEF-2`.

The trailing `(-|$)` is the part that `\b` was buying: within a token the only
non-word character possible is `-`, so `(-|$)` rejects `PROJ-123abc` while still
accepting the `CVE-2024` prefix of `CVE-2024-1234` — exactly what GNU `\b` does.

---

### Task 1: Portable key extraction in `cmd_sniff`

**Files:**
- Modify: `bin/sdlc-backend.sh:211-221`
- Test: `tests/test-sdlc-backend.sh` (sniff section, after line 348)

**Interfaces:**
- Consumes: `SNIFF_DENYLIST` (`bin/sdlc-backend.sh:209`), unchanged.
- Produces: `cmd_sniff` stdout contract is unchanged — zero or more lines of
  `<KEY> <count>`, ranked by count descending, counts ≥ 3, exit 0 when empty.
  `references/backend-bind.md:280` depends on the empty case not being an error.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-sdlc-backend.sh` immediately after the "sniff reads
commit bodies" block (currently ending line 348), before the
`# a repo with no keys at all sniffs clean` block:

```bash
# --- sniff: word-boundary fidelity ---------------------------------------
# The boundary rules `\b` used to enforce, pinned as behaviour so the
# portable replacement cannot quietly widen or narrow them. ADJ-* proves
# adjacency survives: a fix that consumes the trailing boundary character
# (grep -o with a bracket class) counts 2 here, not 3.
bnd="$tmp/bounds"; mkrepo "$bnd" "git@github.com:a/bounds.git"
b() { git -C "$bnd" commit -q --allow-empty -m "$1"; }
b "ADJ-1 ADJ-2 ADJ-3"                        # 3 keys, single-space separated
b "XKEY-1 and _NOPE-1 and 9NOPE-1"
b "XKEY-2 and _NOPE-2 and 9NOPE-2"
b "XKEY-3 and _NOPE-3 and 9NOPE-3"
b "TAIL-1abc TAIL-2abc TAIL-3abc"            # digits then letters: not a key
b "PRE-1-9 x"; b "PRE-2-9 x"; b "PRE-3-9 x"  # multi-hyphen: prefix counts
b "feature/SLASH-1"; b "feature/SLASH-2"; b "feature/SLASH-3"
bnd_out=$(cd "$bnd" && "$SUT" sniff)

eq "ADJ 3" "$(printf '%s\n' "$bnd_out" | grep '^ADJ ')" \
   "sniff counts space-adjacent keys on one line"
eq "XKEY 3" "$(printf '%s\n' "$bnd_out" | grep '^XKEY ')" \
   "sniff counts a key preceded by a non-word character"
eq "PRE 3" "$(printf '%s\n' "$bnd_out" | grep '^PRE ')" \
   "sniff takes the leading key of a multi-hyphen token (CVE-2024-1234 form)"
eq "SLASH 3" "$(printf '%s\n' "$bnd_out" | grep '^SLASH ')" \
   "sniff counts a key after a path separator"
printf '%s\n' "$bnd_out" | grep -q '^NOPE ' \
  && bad "sniff proposed NOPE (key glued to a leading word character)" \
  || ok "sniff rejects a key glued to a leading word character"
printf '%s\n' "$bnd_out" | grep -q '^TAIL ' \
  && bad "sniff proposed TAIL (digits followed by letters is not a key)" \
  || ok "sniff rejects digits followed by letters"
```

- [ ] **Step 2: Run the tests to verify they pass against the current GNU form**

These assertions pin *existing* behaviour, so on this Linux box they pass
before the change too. That is the point: they are the equivalence harness for
Step 3, not a red test. Confirm they pass now, so any later failure is
attributable to the rewrite.

Run: `bash tests/test-sdlc-backend.sh 2>&1 | grep -cE '^ok:'; bash tests/test-sdlc-backend.sh 2>&1 | grep '^FAIL:'`
Expected: count rises from 109 to 115, no `FAIL:` lines.

- [ ] **Step 3: Replace the pipeline**

In `bin/sdlc-backend.sh`, replace lines 214-220 (the body of `cmd_sniff` after
the `git rev-parse` guard) with:

```sh
  # Word boundaries are deliberately not a regex operator here. `\b` is a
  # GNU extension (on BSD grep it reads as a literal `b`, so the whole
  # pipeline silently yields nothing) and `[[:<:]]`/`[[:>:]]` is the
  # BSD-only spelling GNU grep rejects -- there is no portable third
  # spelling. So `tr` splits the stream on every character that cannot
  # appear inside a key, and "on a word boundary" becomes "is the whole
  # token", which plain `^`/`$` express.
  #
  # A bracket class -- (^|[^[:alnum:]_]) -- was rejected because `grep -o`
  # consumes the boundary character: adjacent keys ("K-1 K-2 K-3") then
  # under-count, and the consumed character rides into the denylist below,
  # where " CVE-2024" no longer equals CVE and stops being rejected.
  #
  # The trailing (-|$) is what `\b` bought: within a token `-` is the only
  # possible non-word character, so it rejects PROJ-123abc while still
  # taking the CVE-2024 prefix of CVE-2024-1234.
  { git log -n 500 --format='%s%n%b' 2>/dev/null
    git branch -a --format='%(refname:short)' 2>/dev/null
  } | tr -cs 'A-Za-z0-9_-' '\n' \
    | grep -E '^[A-Z][A-Z0-9]{1,9}-[0-9]+(-|$)' \
    | sed 's/-[0-9].*$//' \
    | grep -vxE "$SNIFF_DENYLIST" \
    | sort | uniq -c | sort -rn \
    | awk '$1 >= 3 { print $2, $1 }'
```

- [ ] **Step 4: Run the full backend suite**

Run: `bash tests/test-sdlc-backend.sh 2>&1 | tail -1`
Expected: `passed=115 failed=0`

- [ ] **Step 5: Commit**

```bash
git add bin/sdlc-backend.sh tests/test-sdlc-backend.sh
git commit -m "fix(sniff): replace GNU-only \\b with portable tokenisation

BSD grep leaves \\<ordinary-char> undefined, so on stock macOS the key
regex most likely matched a literal b and sniff silently returned
nothing -- indistinguishable from a repo with no JIRA keys. Split the
stream with tr instead, so the boundary is expressed with ^/\$ anchors
that both greps agree on."
```

---

### Task 2: Portable `git push` detection in the lint hook

**Files:**
- Modify: `hooks/lint-before-push.sh:12-14`
- Test: `tests/test-lint-before-push.sh` (append before the final `echo passed=`)

**Interfaces:**
- Consumes: `$cmd`, the `.tool_input.command` string (`hooks/lint-before-push.sh:10`).
- Produces: unchanged control flow — non-push commands `exit 0` silently before
  any linter detection runs.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-lint-before-push.sh`, immediately before the final
`echo "passed=$pass failed=$fail"` line:

```bash
# 10. Word-boundary discrimination in the push gate. The comment above the
# gate has always claimed `git commit && push` does not match; nothing
# tested it. These pin both halves -- what must match and what must not --
# so the portable rewrite of that regex is provably equivalent. A repo with
# a Makefile whose `lint` target fails is used so a *matched* command denies
# and an *unmatched* one allows: the two outcomes are distinguishable.
r=$(mkrepo); track "$r"
printf 'lint:\n\tfalse\n' > "$r/Makefile"
for c in "git push" "git push origin main" "git -C /tmp/x push" \
         "git push --force-with-lease" "echo git push" "git   push"; do
  run "$c" "$r"
  deny "push gate matches: $c"
done
for c in "ls -la" "git commit && push" "git commit; push" "gitx push" \
         "mygit push" "git pushed" "git push2" "git push_hard" "push git"; do
  run "$c" "$r"
  allow "push gate ignores: $c"
done
```

Note: `run` builds its JSON with `printf '{"tool_input":{"command":"%s"}}'`, so
these command strings must contain no double quotes or backslashes. None do.

- [ ] **Step 2: Run the tests to verify they pass against the current GNU form**

As in Task 1, these pin existing behaviour and pass before the rewrite on
Linux; they exist to prove the rewrite changes nothing.

Run: `bash tests/test-lint-before-push.sh 2>&1 | tail -1`
Expected: `passed=24 failed=0`

- [ ] **Step 3: Replace the gate**

In `hooks/lint-before-push.sh`, replace lines 12-14 with:

```sh
# Gate only `git push`. Tolerate flags/remotes between the words; stop at
# a shell separator so `git commit && push` does not match. `tr` breaks the
# command at those separators so both words must land in one segment, and
# the bracket classes stand in for `\b` -- a GNU-only extension whose BSD
# counterpart `[[:<:]]` GNU grep rejects. Same reasoning as cmd_sniff in
# bin/sdlc-backend.sh; here the match is boolean, so `grep -q` may consume
# the boundary characters freely.
printf '%s' "$cmd" | tr ';&|' '\n\n\n' \
  | grep -Eq '(^|[^[:alnum:]_])git([^[:alnum:]_].*)?[^[:alnum:]_]push([^[:alnum:]_]|$)' \
  || exit 0
```

- [ ] **Step 4: Run the hook suite**

Run: `bash tests/test-lint-before-push.sh 2>&1 | tail -1`
Expected: `passed=24 failed=0`

- [ ] **Step 5: Commit**

```bash
git add hooks/lint-before-push.sh tests/test-lint-before-push.sh
git commit -m "fix(lint-hook): replace GNU-only \\b in the git-push gate

Same portability defect as cmd_sniff: on BSD grep the gate would not
detect pushes and the lint check would silently never run. Splits on
shell separators with tr, then uses POSIX bracket classes."
```

---

### Task 3: Static portability guard

**Files:**
- Create: `tests/test-portability.sh`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 at runtime; it scans `bin/*.sh` and
  `hooks/*.sh` as files. It fails while either `\b` remains, so it must land
  after both fixes.
- Produces: `passed=N failed=M` on stdout and a non-zero exit on failure — the
  same contract every other script in `tests/` follows, which is what the
  README's runner loop expects.

- [ ] **Step 1: Write the test**

Create `tests/test-portability.sh`:

```bash
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
```

- [ ] **Step 2: Prove the guard is real (it must reject the pre-fix code)**

A green static test proves nothing unless it goes red on the code it exists to
reject. `origin/main` still carries both `\b` forms, so check the scanner
against those exact bytes:

```bash
pc=$(mktemp -d); mkdir -p "$pc/bin" "$pc/hooks" "$pc/tests"
git show origin/main:bin/sdlc-backend.sh       > "$pc/bin/sdlc-backend.sh"
git show origin/main:hooks/lint-before-push.sh > "$pc/hooks/lint-before-push.sh"
cp tests/test-portability.sh "$pc/tests/"
bash "$pc/tests/test-portability.sh"; echo "exit=$?"
rm -rf "$pc"
```

Expected: `passed=9 failed=2`, `exit=1`, with the two `FAIL:` lines naming
`bin/sdlc-backend.sh` and `hooks/lint-before-push.sh` for the GNU-only escape
check and quoting the offending line. (The fixture holds 2 files, so
5 checks × 2 + 1 file-count assertion = 11 total.) Record the output as evidence.

- [ ] **Step 3: Run the guard against the fixed tree**

Run: `bash tests/test-portability.sh; echo "exit=$?"`
Expected: all `ok:`, `passed=21 failed=0`, `exit=0`.
(5 checks × 4 shipped scripts — `bin/sdlc-backend.sh`, `hooks/context-tripwire.sh`,
`hooks/handoff-pickup.sh`, `hooks/lint-before-push.sh` — plus 1 file-count assertion.)
Verified in advance: none of the 5 patterns produces a false positive on the
other three scripts.

- [ ] **Step 4: Run the whole suite the way the README documents**

Run:
```bash
for t in tests/test-*.sh tests/validate-skills.sh; do
  printf '%s: ' "$t"; bash "$t" 2>&1 | tail -1
done
```
Expected: every line `passed=N failed=0`, with these totals —
`test-cleanup-skill` 13, `test-context-tripwire` 8, `test-handoff-pickup` 9,
`test-handoff-worktree` 2, `test-lint-before-push` 24, `test-portability` 21,
`test-sdlc-backend` 115, `validate-skills` 20.

- [ ] **Step 5: Commit**

```bash
git add tests/test-portability.sh
git commit -m "test: guard bin/ and hooks/ against non-portable regex

The behavioural tests for sniff all pass on Linux with the buggy \\b in
place -- the coverage existed, the platform did not. This scans the
shipped scripts statically so the gap is detectable from a Linux box."
```

---

## Acceptance criteria → evidence map

| Criterion (issue #16) | Task | Evidence |
|---|---|---|
| No `\b` or other GNU-only extension under `bin/`/`hooks/` | 1, 2, 3 | `tests/test-portability.sh` green; red against `origin/main` |
| `sniff` returns the same keys, ranks, counts; existing assertions pass unweakened | 1 | `test-sdlc-backend.sh` 109 → 115 ok, 0 FAIL; no existing line edited |
| Denylist still rejects, 3-hit floor still suppresses | 1 | Existing `UTF`/`CVE`/`RFC`/`ARM` and `RARE` assertions unchanged and green; new `PRE` assertion pins the `CVE-2024-1234` prefix path that carries the boundary character |
| A test asserts the portability constraint itself | 3 | `tests/test-portability.sh`, collected by the README runner glob |
| Chosen construct recorded in a comment naming why `\b` and `[[:<:]]` were rejected | 1, 2 | Comments above `cmd_sniff`'s pipeline and the hook's gate |

## Plan corrections during implementation

**1. The static guard must not scan comments (found after Task 1 landed).**
As first written, `tests/test-portability.sh` scanned whole files, which put
acceptance criteria 1 and 5 in direct conflict: AC-5 *requires* a comment
naming `\b` and `[[:<:]]` as rejected, and AC-1's guard would then flag that
very comment (`bin/sdlc-backend.sh:214,227`). Only one reading satisfies both —
AC-1 governs *executed regex*, not prose — so `scan()` now blanks whole-line
comments with `sed` before grepping. `sed` blanks rather than deletes so
`grep -n` still reports true line numbers; verified against the half-fixed tree,
where it correctly reported exactly one hit at `hooks/lint-before-push.sh:14`
and zero hits from Task 1's comments.

## Out of scope (per the issue)

Auditing for non-regex portability gaps — `sed -i`, `timeout`, `readlink -f`,
`mktemp` flags, `base64 -w`. Worth its own pass; do not widen this PR.
