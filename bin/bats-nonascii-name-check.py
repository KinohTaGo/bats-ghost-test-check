#!/usr/bin/env python3
"""Flag `@test` names that may silently fail to execute under a UTF-8 locale.

Background
----------
bats-core's `bats_encode_test_name` (libexec/bats-core/bats-preprocess) selects
between two encoding strategies using a locale-dependent regex:

    if [[ ! "$name" =~ [^[:alnum:]\\ _-] ]]; then

Under LC_ALL=C no non-ASCII character is [:alnum:], so the safe hex-encoding
branch runs and the generated shell function name is pure ASCII.

Under a UTF-8 locale, [:alnum:] matches CJK, Cyrillic, Hangul, fullwidth and
accented letters. The other branch runs and embeds raw multibyte bytes into the
function name. For a subset of those names the runtime `declare -F` lookup then
fails and the test never runs -- while the TAP plan line still counts it.

The affected codepoint set is NOT predictable: U+4EF6 runs, U+4E2D ghosts, and
both are CJK ideographs. Because there is no reliable way to tell a safe
non-ASCII name from an unsafe one, this checker flags all of them.

This check is static and locale-independent, which matters: the dynamic
declared-vs-executed check runs bats and therefore inherits the same locale
condition that triggers the bug, so it can report a clean suite on a runner
whose LC_ALL is unset.

Exit codes
----------
0  no findings
1  one or more non-ASCII test names found
2  usage error
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import unicodedata

# `@test "name" {` / `@test 'name' {` / `@test name {`
TEST_LINE = re.compile(r"""^\s*@test\s+(?P<name>.*?[^\s])\s+\{""")


def strip_quotes(s: str) -> str:
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    return s


def non_ascii_chars(name: str) -> list[tuple[str, str]]:
    """Return [(char, U+XXXX)] for each non-ASCII character, in order, deduped."""
    seen: dict[str, str] = {}
    for ch in name:
        if ord(ch) > 0x7F and ch not in seen:
            seen[ch] = f"U+{ord(ch):04X}"
    return list(seen.items())


def scan_file(path: pathlib.Path) -> list[tuple[int, str, list[tuple[str, str]]]]:
    findings = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"{path}: cannot read: {exc}", file=sys.stderr)
        return findings
    for lineno, line in enumerate(text.splitlines(), start=1):
        m = TEST_LINE.match(line)
        if not m:
            continue
        name = strip_quotes(m.group("name").strip())
        bad = non_ascii_chars(name)
        if bad:
            findings.append((lineno, name, bad))
    return findings


def iter_bats_files(targets: list[str]):
    for t in targets:
        p = pathlib.Path(t)
        if p.is_dir():
            yield from sorted(p.rglob("*.bats"))
        elif p.is_file():
            yield p
        else:
            print(f"{t}: no such file or directory", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Flag @test names that may silently not execute under a UTF-8 locale.",
    )
    ap.add_argument("targets", nargs="+", help=".bats files or directories to scan")
    ap.add_argument(
        "--verbose",
        action="store_true",
        help="show each offending codepoint with its Unicode name",
    )
    args = ap.parse_args()

    total = 0
    scanned = 0
    for path in iter_bats_files(args.targets):
        scanned += 1
        for lineno, name, bad in scan_file(path):
            total += 1
            print(f'{path}:{lineno}: non-ASCII @test name: "{name}"')
            if args.verbose:
                for ch, cp in bad:
                    try:
                        uname = unicodedata.name(ch)
                    except ValueError:
                        uname = "<unnamed>"
                    print(f"    {cp} {ch!r} {uname}")

    if scanned == 0:
        print("no .bats files found", file=sys.stderr)
        return 2

    if total:
        sys.stdout.flush()  # keep findings above the summary when both go to a terminal
        print(
            f"\n{total} test name(s) may not execute under a UTF-8 locale.\n"
            f"Rename them to ASCII; put the original text in a comment inside the test body.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
