# Advisory Naming-Drift Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `sdlc:review` a deterministic, advisory check that flags glossary-disallowed aliases introduced on a PR's added diff lines.

**Architecture:** A self-contained `bin/sdlc-drift.sh check` reads a unified diff on **stdin** and the glossary from `docs/domain/glossary.md`, and prints one advisory line per hit. Reading the diff from stdin is load-bearing: `skills/review/SKILL.md` step 1 forbids pulling the diff into main-loop context, so `gh pr diff <PR#> | bin/sdlc-drift.sh check` keeps the diff inside a shell pipe while only violation lines come back. A single two-pass `awk` program does the work — pass 1 parses the glossary into an alias→canonical map, pass 2 walks the diff tracking `+++ b/<path>` and `@@` hunk headers to compute real new-file line numbers.

**Tech Stack:** POSIX-portable `bash` + `awk`. No dependencies. Must run on stock macOS (BSD userland) and Linux.

**Spec:** `docs/specs/2026-08-13-domain-model-skill.md` §T2 (lines 141–150), design at §"Drift check in `review`" (lines 116–124).

## Global Constraints

Copied verbatim from the spec and from the conventions the scouts confirmed in-repo:

- **Default path free.** "The only change to `interview`/`implement`/`review` is a single conditional read guarded on the glossary existing." No glossary ⇒ `review` behaves byte-for-byte as today.
- **Git-portable string matching.** "The drift check must use the repo's established BSD/macOS-portable word-boundary idiom — a bracket class, **not** `\b`." The canonical idiom is `(^|[^[:alnum:]_-])` (see `tests/validate-skills.sh:76,82`); the trailing side is `([^[:alnum:]_-]|$)`.
- **Deterministic drift check.** "Alias detection is pure string matching — run by the main loop, no reviewer subagent, no skeptic-verify round."
- **Advisory and non-blocking.** Hits must never flip `gh pr review` to `--request-changes`.
- **Banned constructs** (enforced by `tests/test-portability.sh`, which auto-sweeps `bin/*.sh` and `tests/*.sh` with no registration): `\b \B \w \W \s \S`, `\< \>`, `[[:<:]]`/`[[:>:]]`, `grep -P`/`--perl-regexp`, `sed -i`, `readlink -f`, `base64 -w`, `date -d`, `stat -c`, and bare `timeout`.
- **Comment convention:** the portability scanner strips **whole-line** comments only. Any explanation that must name `\b` or `[[:<:]]` has to sit on its own comment line, never as a trailing comment.
- **`bin/` script conventions** (from `bin/sdlc-backend.sh`): `#!/usr/bin/env bash`; `set -u` only (no `-e`, no `pipefail`); a `die()` helper printing `sdlc-drift: <msg>` to stderr; one `cmd_<name>` function per subcommand; a trailing `case "${1:-}"` dispatcher whose empty arm prints usage via `die "..." 2`.
- **Exit-code convention:** `0` means success **including "no findings"** — `sdlc-backend.sh sniff` sets this precedent. Findings are stdout lines, never a nonzero status. Reserve `2` for usage errors and `3` for an unreadable glossary.
- **Test conventions** (from `tests/test-sdlc-backend.sh:1-16`): `set -u`; `here=`/`SUT=`; `tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT`; `ok()`/`bad()`/`eq()` helpers; file ends `echo "passed=$pass failed=$fail"` then `[ "$fail" -eq 0 ]`.
- **Test naming:** must be `tests/test-*.sh` to be auto-discovered by the README runner loop (`README.md:158`): `for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t"; done`. There is no CI in this repo.
- **SKILL.md house style:** ~72-column wrapping; numbered steps with a `**Bold imperative label:**` lead; sub-bullets `-` with `**bold lead term:**`; a closing `## Red flags` section of `<bad behavior> → <consequence>` bullets.

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/sdlc-drift.sh` *(create)* | The whole check: glossary parse, diff walk, advisory output. Self-contained, no sourced lib — matches `sdlc-backend.sh`. |
| `tests/test-drift.sh` *(create)* | Exercises the helper against seeded glossary + diff fixtures. |
| `skills/review/SKILL.md` *(modify)* | Gains one deterministic main-loop step; later steps renumber. |

Two tasks. A reviewer could reasonably accept the helper while rejecting the skill wording, or vice versa, so they split there.

---

### Task 1: The `bin/sdlc-drift.sh` helper

**Files:**
- Create: `bin/sdlc-drift.sh`
- Test: `tests/test-drift.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: CLI contract `bin/sdlc-drift.sh check [--glossary <path>] < unified.diff`.
  - stdout: zero or more lines, each exactly `<file>:<line> — '<alias>' found — should be '<canonical>'` (em dash `—`, U+2014).
  - exit `0` = ran successfully, findings or not. exit `2` = usage error. exit `3` = glossary exists but is unreadable.
  - Absent glossary ⇒ no output, exit `0`.
  - Task 2 relies on this exact invocation string and on findings-do-not-set-a-nonzero-status.

- [ ] **Step 1: Write the failing test**

Create `tests/test-drift.sh`:

```bash
#!/usr/bin/env bash
# bin/sdlc-drift.sh — glossary alias detection over a unified diff's added
# lines. Fixtures are seeded under $tmp so the suite never reads a real
# project glossary.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
SUT="$here/../bin/sdlc-drift.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { # want got desc
  [ "$1" = "$2" ] && ok "$3" || bad "$3 (want '$1' got '$2')"
}

glossary="$tmp/glossary.md"
cat >"$glossary" <<'GLOSSARY'
### Widget
The unit of work a user schedules. Created by a Plan, consumed by a Run.
**Not:** Gadget, Item

### Run
An execution of a Widget.
**Not:** Job
GLOSSARY

# --- a diff that introduces a disallowed alias ---------------------------
dirty="$tmp/dirty.diff"
cat >"$dirty" <<'DIRTY'
diff --git a/src/app.js b/src/app.js
index 1111111..2222222 100644
--- a/src/app.js
+++ b/src/app.js
@@ -1,3 +1,5 @@
 const x = 1;
+const gadgetCount = 0;
+const Gadget = makeGadget();
 const y = 2;
DIRTY

got=$(bash "$SUT" check --glossary "$glossary" <"$dirty"); rc=$?
eq "0" "$rc" "findings still exit 0 (advisory, not a gate)"
eq "src/app.js:3 — 'Gadget' found — should be 'Widget'" "$got" \
   "reports file:line, alias and canonical term"

# --- a clean diff reports nothing ---------------------------------------
clean="$tmp/clean.diff"
cat >"$clean" <<'CLEAN'
diff --git a/src/app.js b/src/app.js
index 1111111..2222222 100644
--- a/src/app.js
+++ b/src/app.js
@@ -1,3 +1,4 @@
 const x = 1;
+const Widget = makeWidget();
 const y = 2;
CLEAN

got=$(bash "$SUT" check --glossary "$glossary" <"$clean"); rc=$?
eq "0" "$rc" "clean diff exits 0"
eq "" "$got" "clean diff reports nothing"

# --- the word boundary is a bracket class, so substrings do not match ----
sub="$tmp/sub.diff"
cat >"$sub" <<'SUB'
--- a/src/app.js
+++ b/src/app.js
@@ -1,1 +1,2 @@
 const x = 1;
+const Gadgetry = 1; const subGadget = 2;
SUB

got=$(bash "$SUT" check --glossary "$glossary" <"$sub")
eq "" "$got" "Gadgetry/subGadget are not bare-word Gadget"

# --- removed lines are not added lines ----------------------------------
del="$tmp/del.diff"
cat >"$del" <<'DEL'
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,1 @@
 const x = 1;
-const Gadget = old();
DEL

got=$(bash "$SUT" check --glossary "$glossary" <"$del")
eq "" "$got" "a removed alias is not a finding"

# --- a second entry's aliases are mapped to their own term --------------
job="$tmp/job.diff"
cat >"$job" <<'JOB'
--- a/src/run.js
+++ b/src/run.js
@@ -10,1 +10,2 @@
 const a = 1;
+const Job = start();
JOB

got=$(bash "$SUT" check --glossary "$glossary" <"$job")
eq "src/run.js:11 — 'Job' found — should be 'Run'" "$got" \
   "aliases map to their own entry's canonical term"

# --- no glossary: silent, exit 0, default path pays nothing -------------
got=$(bash "$SUT" check --glossary "$tmp/does-not-exist.md" <"$dirty"); rc=$?
eq "0" "$rc" "absent glossary exits 0"
eq "" "$got" "absent glossary reports nothing"

# --- usage errors are exit 2 --------------------------------------------
bash "$SUT" >/dev/null 2>&1; eq "2" "$?" "no subcommand is a usage error"
bash "$SUT" bogus >/dev/null 2>&1; eq "2" "$?" "unknown subcommand is a usage error"
bash "$SUT" check --glossary >/dev/null 2>&1 </dev/null
eq "2" "$?" "--glossary without a value is a usage error"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-drift.sh`
Expected: FAIL — every `eq` mismatches because `bin/sdlc-drift.sh` does not exist yet (bash reports "No such file or directory", exit 127).

- [ ] **Step 3: Write minimal implementation**

Create `bin/sdlc-drift.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
# Advisory naming-drift check: reads a unified diff on stdin and reports
# ADDED lines that use an alias the project glossary marks disallowed on
# its "**Not:**" lines.
#
# Unlike hooks/*.sh (which fail open with a silent exit 0), this is a CLI:
# exit codes are its interface. 2 = usage error, 3 = glossary unreadable.
# Findings are deliberately NOT an error condition -- the check is
# advisory, so hits print to stdout and the command still exits 0. A
# caller that wants to gate on drift must test for non-empty output, never
# for a nonzero status.
set -u

die() { printf 'sdlc-drift: %s\n' "$1" >&2; exit "${2:-1}"; }

cmd_check() {
  glossary="docs/domain/glossary.md"
  while [ $# -gt 0 ]; do
    case "$1" in
      --glossary)
        [ $# -ge 2 ] || die "--glossary requires a path" 2
        glossary="$2"; shift 2 ;;
      -*) die "unknown flag: $1" 2 ;;
      *)  die "unexpected argument: $1" 2 ;;
    esac
  done

  # An absent glossary means the project never adopted one: stay silent and
  # exit 0 so the default path pays nothing for a feature it does not use.
  [ -f "$glossary" ] || return 0
  [ -r "$glossary" ] || die "glossary not readable: $glossary" 3

  # The word boundary below is the bracket class (^|[^[:alnum:]_-]). The
  # GNU spelling \b is not portable to BSD grep/awk (it reads as a literal
  # b), and the BSD spelling [[:<:]] is rejected by GNU -- there is no
  # portable third spelling, so the bracket class is the repo idiom. See
  # tests/validate-skills.sh:76,82 for the same construction.
  awk '
    function esc(s,   t) {
      t = s
      gsub(/[][(){}.*+?^$|]/, "\\\\&", t)
      return t
    }
    BEGIN { path = "(unknown)"; ln = 0; na = 0; term = "" }

    # ---- pass 1: the glossary ------------------------------------------
    FNR == NR {
      if ($0 ~ /^### /) {
        term = substr($0, 5)
        sub(/[ \t]+$/, "", term)
      } else if ($0 ~ /^\*\*Not:\*\*/ && term != "") {
        n = split(substr($0, 9), parts, ",")
        for (i = 1; i <= n; i++) {
          a = parts[i]
          sub(/^[ \t]+/, "", a); sub(/[ \t]+$/, "", a)
          if (a != "") {
            na++
            alias[na] = a
            canon[na] = term
            pat[na] = "(^|[^[:alnum:]_-])" esc(a) "([^[:alnum:]_-]|$)"
          }
        }
      }
      next
    }

    # ---- pass 2: the diff ----------------------------------------------
    /^\+\+\+ / {
      path = substr($0, 5)
      sub(/\t.*$/, "", path)
      if (path ~ /^b\//) path = substr(path, 3)
      next
    }
    /^--- / { next }
    /^@@/ {
      if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0
      next
    }
    /^\+/ {
      text = substr($0, 2)
      for (i = 1; i <= na; i++) {
        if (text ~ pat[i]) {
          printf "%s:%d — '\''%s'\'' found — should be '\''%s'\''\n", \
                 path, ln, alias[i], canon[i]
        }
      }
      ln++
      next
    }
    /^-/ { next }
    { ln++ }
  ' "$glossary" -
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  "") die "usage: sdlc-drift.sh check [--glossary <path>] < unified.diff" 2 ;;
  *) die "unknown subcommand: $1" 2 ;;
esac
```

Notes for the implementer:
- `**Not:**` is exactly 8 characters, so the alias list starts at `substr($0, 9)`. `### ` is 4, so the term starts at `substr($0, 5)`.
- Rule order matters: `/^\+\+\+ /` must precede `/^\+/`, and each rule ends in `next`.
- Matching is **case-sensitive** by design. Case-insensitive matching on short aliases like `Item` or `Job` would flag ordinary identifiers (`for item in ...`) on nearly every diff, which is unacceptable noise for an advisory check.
- `esc()` deliberately omits backslash from its bracket class: `\\` inside a POSIX bracket expression is not portably interpreted, and a domain alias containing a backslash is not a real case.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-drift.sh`
Expected: PASS — `passed=13 failed=0`, exit 0.

- [ ] **Step 5: Verify the portability guard still passes**

Run: `bash tests/test-portability.sh`
Expected: PASS, exit 0. It auto-sweeps the two new files with no registration.

- [ ] **Step 6: Commit**

```bash
chmod +x bin/sdlc-drift.sh
git add bin/sdlc-drift.sh tests/test-drift.sh
git commit -m "feat: advisory glossary drift check helper"
```

---

### Task 2: The deterministic drift step in `review`

**Files:**
- Modify: `skills/review/SKILL.md`

**Interfaces:**
- Consumes: `bin/sdlc-drift.sh check [--glossary <path>] < unified.diff` from Task 1 — stdout lines, exit 0 regardless of findings.
- Produces: no programmatic interface; a documented step.

- [ ] **Step 1: Insert the new step**

Insert a new **step 4** between the existing skeptic-verify step (3) and
the post-the-verdict step, then renumber the old 4 → 5 and old 5 → 6.
Grep first for any internal cross-references to those numbers and update
them: `grep -n 'step [0-9]' skills/review/SKILL.md`.

Wrap at ~72 columns. The new step:

```markdown
4. **Naming drift (deterministic, advisory).** Skip entirely unless
   `docs/domain/glossary.md` exists. When it does, the main loop runs the
   helper directly — no reviewer subagent, no skeptic round, because the
   check is pure string matching:

   ```bash
   gh pr diff <PR#> | bin/sdlc-drift.sh check
   ```

   The diff stays inside the pipe; only violation lines
   (`file:line — 'alias' found — should be 'canonical'`) come back. Fold
   any hits into the review body under a **Naming drift (advisory)**
   heading. These are **non-blocking**: they never by themselves turn an
   approval into `--request-changes`, and a PR whose only findings are
   drift hits is still approved.
```

- [ ] **Step 2: Note the advisory rule in the verdict step**

In the (now) step 5 verdict step, after the existing `gh pr review`
block, add one line so the non-blocking rule is stated where the decision
is actually made:

```markdown
   Naming-drift hits are advisory: list them in the body, but never let
   them alone select `--request-changes`.
```

- [ ] **Step 3: Add a red flag**

Append to the `## Red flags` list, matching the existing
`<bad behavior> → <consequence>` shape:

```markdown
- Running the drift check with no glossary present, or letting a drift
  hit block approval → the check is advisory and the default path must
  stay free.
```

- [ ] **Step 4: Verify the skills validator still passes**

Run: `bash tests/validate-skills.sh`
Expected: PASS, exit 0. Note `gh_floors` carries `review:7`; the new
`gh pr diff` raises the count, and floors are minimums, so this is safe.

- [ ] **Step 5: Run the full suite**

Run: `for t in tests/test-*.sh tests/validate-skills.sh; do bash "$t" >/dev/null 2>&1 || echo "FAILED: $t"; done`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add skills/review/SKILL.md
git commit -m "feat: advisory naming-drift step in review"
```

---

## Self-Review

**1. Spec coverage** — every §T2 acceptance criterion maps to a step:

| AC | Covered by |
|---|---|
| `bin/` helper extracts `**Not:**` aliases, greps added lines, emits `file:line — '<alias>' found — should be '<canonical>'` | Task 1 Step 3; asserted Task 1 Step 1 (`reports file:line, alias and canonical term`) |
| Bracket-class word boundary, no `\b`, consistent with `tests/validate-skills.sh:71` | Task 1 Step 3 (`pat[na]` construction + the whole-line comment); asserted by the `Gadgetry/subGadget` case and by `tests/test-portability.sh` in Step 5 |
| A test under `tests/` — seeded glossary + alias diff reports, clean diff reports nothing, follows BSD conventions | Task 1 Step 1 (`tests/test-drift.sh`, `mktemp -d`/`trap`/`ok`/`bad`/`eq`) |
| `skills/review/SKILL.md` gains a deterministic step, main loop, no subagent, no skeptic, advisory | Task 2 Steps 1–3 |
| With no glossary, `review` behaves byte-for-byte as today | Task 1 Step 3 (`[ -f "$glossary" ] || return 0`); asserted by the absent-glossary case; Task 2 Step 1 ("Skip entirely unless ... exists") |

**2. Placeholder scan** — clean. No deferral markers, no "same as the
earlier task" cross-references, no vague directives standing in for code:
every step that calls for code carries that code literally.

**3. Type consistency** — the invocation `bin/sdlc-drift.sh check` and the
output shape `file:line — 'alias' found — should be 'canonical'` are
identical in Task 1's interface block, Task 1's test, Task 1's
implementation, and Task 2's step text.

## Known assumptions

- **Case-sensitive matching.** Justified in Task 1 Step 3. Worth flagging
  on the PR — a reviewer may want case-insensitive matching with a
  minimum alias length instead.
- **One finding per alias per line.** A line using the same alias twice
  reports once. This keeps output proportional to real drift.
