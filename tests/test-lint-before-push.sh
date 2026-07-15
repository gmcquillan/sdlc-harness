#!/usr/bin/env bash
# lint-before-push hook: git-push gating, linter auto-detection, and
# deny/allow decisions. Each case builds a throwaway git repo so the
# detection signals (Makefile / package.json / lockfiles) are real.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../hooks/lint-before-push.sh"
pass=0; fail=0
OUT=""; RC=0

tmpdirs=()
trap 'rm -rf "${tmpdirs[@]}"' EXIT

run() { # cmd_string repo_dir -> sets OUT, RC (hook runs with cwd=repo_dir)
  OUT=$( (cd "$2" && printf '{"tool_input":{"command":"%s"}}' "$1" \
    | bash "$script") 2>/dev/null )
  RC=$?
}
allow() { # desc  (allow == exit 0 with no stdout)
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}
deny() { # desc
  if printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'; then
    echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 (rc=$RC out=$OUT)"; fail=$((fail+1)); fi
}
# NOTE: mkrepo/mkbindir are always invoked as `x=$(mkrepo)`, which forks a
# subshell for the command substitution. Appending to tmpdirs *inside* the
# function would only mutate that subshell's copy of the array and vanish
# when it exits -- so callers must track the returned path themselves via
# track(), right after capturing it.
mkrepo() { local d; d=$(mktemp -d); git -C "$d" init -q; echo "$d"; }
mkbindir() { local d; d=$(mktemp -d); echo "$d"; }
track() { tmpdirs+=("$1"); }

# 1. Not a `git push` → allow (no repo, no linter needed).
tmp0=$(mktemp -d); track "$tmp0"
run "ls -la" "$tmp0"
allow "non-push command ignored"

# 2. `git push` but no linter detected → allow.
r=$(mkrepo); track "$r"
run "git push origin master" "$r"
allow "no linter detected -> allow"

# 3. Makefile lint target that FAILS → deny.
r=$(mkrepo); track "$r"; printf 'lint:\n\t@exit 1\n' > "$r/Makefile"
run "git push" "$r"
deny "failing make lint -> deny push"

# 4. Makefile lint target that PASSES → allow.
r=$(mkrepo); track "$r"; printf 'lint:\n\t@exit 0\n' > "$r/Makefile"
run "git push" "$r"
allow "passing make lint -> allow push"

# 5. SDLC_SKIP_LINT bypasses even a failing linter.
r=$(mkrepo); track "$r"; printf 'lint:\n\t@exit 1\n' > "$r/Makefile"
export SDLC_SKIP_LINT=1
run "git push" "$r"
unset SDLC_SKIP_LINT
allow "SDLC_SKIP_LINT bypasses gate"

# 6. package.json with a lint script that fails → deny (npm path).
r=$(mkrepo); track "$r"
printf '{"scripts":{"lint":"exit 1"}}\n' > "$r/package.json"
run "git push" "$r"
deny "failing npm lint -> deny push"

# 7. .pre-commit-config.yaml present; stub `pre-commit` exits 1 → deny.
# Stubbed on a temp PATH so this doesn't depend on pre-commit actually
# being installed (which would make a deny pass for the wrong reason).
r=$(mkrepo); track "$r"; : > "$r/.pre-commit-config.yaml"
bindir=$(mkbindir); track "$bindir"
cat > "$bindir/pre-commit" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$bindir/pre-commit"
PATH="$bindir:$PATH" run "git push" "$r"
deny "failing pre-commit -> deny push"

# 8. .pre-commit-config.yaml present; stub `pre-commit` exits 0 → allow.
r=$(mkrepo); track "$r"; : > "$r/.pre-commit-config.yaml"
bindir=$(mkbindir); track "$bindir"
cat > "$bindir/pre-commit" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bindir/pre-commit"
PATH="$bindir:$PATH" run "git push" "$r"
allow "passing pre-commit -> allow push"

# 9. package.json + pnpm-lock.yaml → hook must select `pnpm run lint`,
# not fall through to npm. Stub `pnpm` to allow and `npm` to deny: if
# the hook picked npm instead (wrong selection), this would deny, not
# allow, so an `allow` here is a real proof of pnpm selection.
r=$(mkrepo); track "$r"
printf '{"scripts":{"lint":"true"}}\n' > "$r/package.json"
: > "$r/pnpm-lock.yaml"
bindir=$(mkbindir); track "$bindir"
cat > "$bindir/pnpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$bindir/npm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$bindir/pnpm" "$bindir/npm"
PATH="$bindir:$PATH" run "git push" "$r"
allow "pnpm-lock.yaml -> selects pnpm over npm -> allow push"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
