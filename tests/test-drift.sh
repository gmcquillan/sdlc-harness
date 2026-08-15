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

# --- a CRLF-authored glossary must not silently miss the alias ----------
# Built portably with printf (no sed -i / GNU-only flags): each glossary
# line ends in a literal CR before the shell-added LF.
crlf="$tmp/crlf-glossary.md"
printf '### Widget\r\nThe unit of work.\r\n**Not:** Gadget\r\n' >"$crlf"

crlfdiff="$tmp/crlf.diff"
cat >"$crlfdiff" <<'CRLFDIFF'
--- a/src/app.js
+++ b/src/app.js
@@ -1,1 +1,2 @@
 const x = 1;
+const Gadget = old();
CRLFDIFF

got=$(bash "$SUT" check --glossary "$crlf" <"$crlfdiff")
eq "src/app.js:2 — 'Gadget' found — should be 'Widget'" "$got" \
   "CRLF-authored glossary still reports the violation (no silent false negative)"

# --- usage errors are exit 2 --------------------------------------------
bash "$SUT" >/dev/null 2>&1; eq "2" "$?" "no subcommand is a usage error"
bash "$SUT" bogus >/dev/null 2>&1; eq "2" "$?" "unknown subcommand is a usage error"
bash "$SUT" check --glossary >/dev/null 2>&1 </dev/null
eq "2" "$?" "--glossary without a value is a usage error"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
