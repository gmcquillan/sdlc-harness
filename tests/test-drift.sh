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
@@ -1,2 +1,4 @@
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
@@ -1,2 +1,3 @@
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

# --- an ADDED line whose content starts with "++ " must not be mistaken --
# --- for a "+++ " file header (headers only occur BETWEEN hunks) --------
plusplus="$tmp/plusplus.diff"
cat >"$plusplus" <<'PLUSPLUS'
--- a/doc.md
+++ b/doc.md
@@ -1,1 +1,3 @@
 existing line
+++ hunk sample from a plan doc
+Use Gadget here
PLUSPLUS

got=$(bash "$SUT" check --glossary "$glossary" <"$plusplus")
eq "doc.md:3 — 'Gadget' found — should be 'Widget'" "$got" \
   "an added line starting with '++ ' is not mistaken for a +++ file header"

# --- the same, but the "++ " line directly follows a REMOVED line whose --
# --- content starts with "-- " (rendering as "--- "). The pair looks     --
# --- exactly like a file header, so nothing but the hunk's line budget   --
# --- can tell them apart. Two added lines carry the alias: the first     --
# --- proves the "+++ " line itself is still checked, the second proves   --
# --- path and line counter are not corrupted for the rest of the hunk.   --
sqlpair="$tmp/sqlpair.diff"
cat >"$sqlpair" <<'SQLPAIR'
--- a/q.sql
+++ b/q.sql
@@ -1,2 +1,3 @@
 SELECT 1;
--- legacy note
+++ new Gadget marker
+another Gadget here
SQLPAIR

got=$(bash "$SUT" check --glossary "$glossary" <"$sqlpair")
want=$(printf '%s\n%s' \
  "q.sql:2 — 'Gadget' found — should be 'Widget'" \
  "q.sql:3 — 'Gadget' found — should be 'Widget'")
eq "$want" "$got" \
   "a '-- '/'++ ' content pair inside a hunk is not mistaken for a file header"

# --- "\ No newline at end of file" is diff metadata, not a content line --
# --- (the old file lacked a trailing newline, so the marker sits between
# --- the removed line and the added one -- it must not count as a line)
nonl="$tmp/nonl.diff"
cat >"$nonl" <<'NONL'
--- a/nn.txt
+++ b/nn.txt
@@ -1,2 +1,2 @@
 line one
-old last line
\ No newline at end of file
+Gadget here
NONL

got=$(bash "$SUT" check --glossary "$glossary" <"$nonl")
eq "nn.txt:2 — 'Gadget' found — should be 'Widget'" "$got" \
   "a no-newline marker does not advance the line counter"

# --- the glossary's own diff never self-reports, but a sibling file in ---
# --- the SAME diff is still checked (proves the file is skipped, not the -
# --- whole run) -----------------------------------------------------------
selfdiff="$tmp/glossary-self.diff"
cat >"$selfdiff" <<'SELFDIFF'
--- a/docs/domain/glossary.md
+++ b/docs/domain/glossary.md
@@ -1,2 +1,3 @@
 ### Widget
 The unit of work a user schedules. Created by a Plan, consumed by a Run.
+**Not:** Gadget, Item
--- a/src/app.js
+++ b/src/app.js
@@ -1,1 +1,2 @@
 const x = 1;
+const Gadget = made();
SELFDIFF

got=$(bash "$SUT" check --glossary "$glossary" <"$selfdiff")
eq "src/app.js:2 — 'Gadget' found — should be 'Widget'" "$got" \
   "the glossary's own file is skipped, but a sibling file in the same diff is still checked"

# --- a multi-file diff reports correct per-file paths and line numbers ---
multifile="$tmp/multifile.diff"
cat >"$multifile" <<'MULTIFILE'
--- a/src/a.js
+++ b/src/a.js
@@ -1,1 +1,2 @@
 const x = 1;
+const Gadget = 1;
--- a/src/b.js
+++ b/src/b.js
@@ -5,1 +5,2 @@
 const y = 2;
+const Job = 2;
MULTIFILE

got=$(bash "$SUT" check --glossary "$glossary" <"$multifile")
want=$(printf '%s\n%s' \
  "src/a.js:2 — 'Gadget' found — should be 'Widget'" \
  "src/b.js:6 — 'Job' found — should be 'Run'")
eq "$want" "$got" "a multi-file diff reports correct per-file paths and line numbers"

# --- a multi-hunk diff resets the line counter for the second hunk -------
multihunk="$tmp/multihunk.diff"
cat >"$multihunk" <<'MULTIHUNK'
--- a/src/multi.js
+++ b/src/multi.js
@@ -1,1 +1,2 @@
 const x = 1;
+const y = 2;
@@ -10,1 +11,2 @@
 const z = 3;
+const Gadget = 4;
MULTIHUNK

got=$(bash "$SUT" check --glossary "$glossary" <"$multihunk")
eq "src/multi.js:12 — 'Gadget' found — should be 'Widget'" "$got" \
   "a multi-hunk diff reports the correct line number in the second hunk"

# --- an unreadable glossary is exit 3, never a silent clean result -------
# An ABSENT glossary is exit 0 and silence (the project opted out); a
# PRESENT but unreadable one is a real failure, and must not be reported
# as "no drift" -- silence is this tool's only clean signal, so a failure
# that stays silent is indistinguishable from a pass.
unreadable="$tmp/unreadable.md"
cp "$glossary" "$unreadable"
chmod 000 "$unreadable"
if [ -r "$unreadable" ]; then
  # root ignores the mode bits, so the branch cannot be exercised here
  echo "skip: unreadable glossary is exit 3 (running as root)"
else
  bash "$SUT" check --glossary "$unreadable" >/dev/null 2>&1 <"$dirty"
  eq "3" "$?" "an unreadable glossary is exit 3"
fi
chmod 644 "$unreadable"

# --- usage errors are exit 2 --------------------------------------------
bash "$SUT" >/dev/null 2>&1; eq "2" "$?" "no subcommand is a usage error"
bash "$SUT" bogus >/dev/null 2>&1; eq "2" "$?" "unknown subcommand is a usage error"
bash "$SUT" check --glossary >/dev/null 2>&1 </dev/null
eq "2" "$?" "--glossary without a value is a usage error"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
