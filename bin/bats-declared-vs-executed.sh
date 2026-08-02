#!/usr/bin/env bash
# bats-declared-vs-executed.sh -- find bats tests that are declared but never executed.
#
# Runs bats per file and compares the TAP plan (`1..N`) against the number of
# `ok` / `not ok` result lines. A shortfall means tests were counted but never
# ran. Per-file execution is deliberate: a suite-wide shortfall tells you a
# number, a per-file shortfall tells you which file to fix.
#
# NOTE ON LOCALE
#   The failure this detects is itself locale-dependent (bats-core's
#   bats_encode_test_name uses a locale-aware [[:alnum:]]). This script runs
#   bats and therefore inherits the same condition. On a runner with LC_ALL
#   unset -- which behaves like C -- a genuinely affected suite reports clean.
#   Set LC_ALL explicitly, or prefer the static check for CI:
#
#       LC_ALL=en_US.UTF-8 ./bats-declared-vs-executed.sh tests/
#
# Exit codes: 0 no shortfall, 1 shortfall found, 2 usage/environment error.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: bats-declared-vs-executed.sh <file-or-dir> [...]

  Runs each .bats file and reports any difference between the declared TAP
  plan and the number of executed tests.

  LC_ALL is honoured. If unset, a warning is printed because an unset locale
  suppresses the very failure this script looks for.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
command -v bats >/dev/null 2>&1 || { echo "bats not found in PATH" >&2; exit 2; }

if [ -z "${LC_ALL:-}" ] && [ -z "${LC_CTYPE:-}" ] && [ -z "${LANG:-}" ]; then
  echo "warning: LC_ALL/LC_CTYPE/LANG all unset (behaves like C)." >&2
  echo "         Locale-triggered ghost tests will NOT reproduce. Re-run with" >&2
  echo "         LC_ALL=en_US.UTF-8 to exercise that path." >&2
fi

# Collect targets.
files=()
for t in "$@"; do
  if [ -d "$t" ]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$t" -type f -name '*.bats' | sort)
  elif [ -f "$t" ]; then
    files+=("$t")
  else
    echo "$t: no such file or directory" >&2
    exit 2
  fi
done

[ "${#files[@]}" -gt 0 ] || { echo "no .bats files found" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

total_short=0
affected=0

for f in "${files[@]}"; do
  out="$tmp/out.tap"
  # bats exits non-zero on a shortfall; that is expected, so do not let set -e abort.
  set +e
  bats "$f" >"$out" 2>&1
  set -e

  # Use absolute grep: some shells ship a `grep` function that skips files.
  declared=$(/usr/bin/grep -oE '^1\.\.[0-9]+' "$out" | head -1 | /usr/bin/grep -oE '[0-9]+$' || true)
  [ -n "$declared" ] || declared=0
  executed=$(/usr/bin/grep -cE '^(ok|not ok) ' "$out" || true)

  short=$(( declared - executed ))
  if [ "$short" -gt 0 ]; then
    affected=$(( affected + 1 ))
    total_short=$(( total_short + short ))
    printf '%s: declared=%s executed=%s shortfall=%s\n' "$f" "$declared" "$executed" "$short"

    # Name the culprits: declared names minus executed names.
    #
    # Both sides MUST be sorted with LC_ALL=C. `comm` requires its inputs to be
    # sorted in the same collation, and a UTF-8 collation orders multibyte
    # strings differently from byte order -- which silently produces a wrong
    # diff (names that ran reported as ghosts, real ghosts omitted). The
    # comparison is over exact byte strings, so byte order is the correct
    # collation here regardless of the locale bats itself ran under.
    /usr/bin/grep -oE '^[[:space:]]*@test[[:space:]]+.*[^[:space:]][[:space:]]+\{' "$f" \
      | sed -E 's/^[[:space:]]*@test[[:space:]]+//; s/[[:space:]]+\{$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' \
      | LC_ALL=C sort > "$tmp/declared.txt"
    /usr/bin/grep -E '^(ok|not ok) ' "$out" \
      | sed -E 's/^(ok|not ok) [0-9]+ //; s/ # skip.*$//' \
      | LC_ALL=C sort > "$tmp/executed.txt"
    LC_ALL=C comm -23 "$tmp/declared.txt" "$tmp/executed.txt" | sed 's/^/  ghost: /'
  fi
done

if [ "$affected" -gt 0 ]; then
  printf '\n%s file(s) with ghost tests, %s test(s) never executed.\n' "$affected" "$total_short" >&2
  exit 1
fi

printf 'checked %s file(s): declared == executed everywhere.\n' "${#files[@]}"
exit 0
