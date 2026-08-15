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
#
# Matching is deliberately case-sensitive: case-insensitive matching on
# short aliases (Item, Job, Run) would flag ordinary identifiers in nearly
# every diff, which is unacceptable noise for an advisory check.
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
  awk -v glossary_path="$glossary" '
    function esc(s,   t) {
      t = s
      gsub(/[][(){}.*+?^$|]/, "\\\\&", t)
      return t
    }
    # A hunk header'\''s range is "<start>[,<count>]"; an omitted count is 1.
    function rstart(r,   p) { p = index(r, ","); return (p ? substr(r, 1, p - 1) : r) + 0 }
    function rcount(r,   p) { p = index(r, ","); return (p ? substr(r, p + 1) + 0 : 1) }

    # True while the current hunk still owes body lines. Header patterns
    # are only honoured when this is false -- see pass 2.
    function inhunk() { return (rem_old > 0 || rem_new > 0) }

    BEGIN {
      path = "(unknown)"; ln = 0; na = 0; term = ""; skip = 0
      rem_old = 0; rem_new = 0
    }

    # ---- pass 1: the glossary ------------------------------------------
    # FILENAME != "-" excludes stdin (the diff) from pass 1. With an empty
    # glossary file, bare FNR == NR is still true for stdin'\''s first line,
    # so diff text would be parsed as glossary entries; guarding on the
    # real glossary filename keeps pass 1 scoped to the glossary only.
    FNR == NR && FILENAME != "-" {
      # Strip a trailing CR once here so every field derived below (the
      # heading term and each alias) is CR-clean, rather than trimming CR
      # at each sub() site. A CRLF-authored glossary would otherwise parse
      # aliases like "Gadget\r", which never matches clean diff text -- a
      # silent false negative from an advisory tool whose only signal is
      # its own silence.
      sub(/\r$/, "", $0)
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
    # Inside a hunk every body line carries a one-character prefix, so a
    # line of file content beginning with "-- " or "++ " renders exactly
    # like a "--- "/"+++ " file header and no pattern can tell them apart.
    # File headers only ever occur BETWEEN hunks, though, and the hunk
    # header states precisely how many old and new lines the body holds --
    # so track that budget and honour header patterns only once it is
    # spent. Content is then structurally incapable of being read as a
    # header, which matters beyond the one line: a misread header silently
    # rewrites "path" and stalls the line counter for the whole hunk.

    # Unconditional, so a diff with counts that disagree with its own body
    # (hand-written fixtures, plan-doc excerpts) re-syncs at the next hunk
    # rather than staying wedged. Body lines are prefixed, so a real line
    # of content can never reach this pattern at column 0.
    /^@@ -[0-9]/ {
      hdr = $0
      # Drop the trailing section heading -- it is arbitrary source text
      # and may hold its own "+12"-shaped runs (awk'\''s match() is greedy
      # left-to-right, so an unbounded search could pick one up).
      i = index(substr(hdr, 3), "@@")
      if (i > 0) hdr = substr(hdr, 1, i + 1)
      rem_old = 1; rem_new = 1
      if (match(hdr, /-[0-9]+(,[0-9]+)?/)) {
        rem_old = rcount(substr(hdr, RSTART + 1, RLENGTH - 1))
      }
      if (match(hdr, /\+[0-9]+(,[0-9]+)?/)) {
        r = substr(hdr, RSTART + 1, RLENGTH - 1)
        ln = rstart(r); rem_new = rcount(r)
      }
      next
    }

    # Eating a "--- " line costs nothing: it is either a header or a
    # removed line, and removed lines never advance the line counter.
    !inhunk() && /^--- / { next }

    !inhunk() && /^\+\+\+ / {
      path = substr($0, 5)
      sub(/\t.*$/, "", path)
      if (path ~ /^b\//) path = substr(path, 3)
      # Skip the glossary file itself: it DEFINES the vocabulary, so its
      # own "**Not:**" lines are not drift. Match both the path this run
      # was actually pointed at (glossary_path, passed in with -v so a
      # fixture path works too) and the canonical repo path, so a real
      # PR diff is covered even when --glossary points elsewhere.
      skip = (path == glossary_path || path == "docs/domain/glossary.md")
      next
    }

    # Between hunks: "diff --git", "index", mode and rename lines. None of
    # them are file content, so none may touch the line counter.
    !inhunk() { next }

    # ---- hunk body ------------------------------------------------------
    # "\ No newline at end of file" is diff metadata, not a line of file
    # content: it neither advances the line counter nor spends budget.
    /^\\/ { next }

    /^\+/ {
      text = substr($0, 2)
      if (!skip) {
        for (i = 1; i <= na; i++) {
          if (text ~ pat[i]) {
            printf "%s:%d — '\''%s'\'' found — should be '\''%s'\''\n", \
                   path, ln, alias[i], canon[i]
          }
        }
      }
      ln++; rem_new--
      next
    }
    /^-/ { rem_old--; next }
    { ln++; rem_old--; rem_new-- }
  ' "$glossary" -
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  "") die "usage: sdlc-drift.sh check [--glossary <path>] < unified.diff" 2 ;;
  *) die "unknown subcommand: $1" 2 ;;
esac
