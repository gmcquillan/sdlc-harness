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
