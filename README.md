# bats-ghost-test-check

> 日本語版: [README.ja.md](README.ja.md)

Detects **ghost tests** in [bats-core](https://github.com/bats-core/bats-core) suites:
tests that are declared, counted in the TAP plan, and never actually executed.

```
$ bats tests/
1..889
ok 1 ...
...
# bats warning: Executed 804 instead of expected 889 tests
```

85 tests had not been running. The plan line said 889. Nothing in the `ok` stream looked
wrong.

## The bug

`bats_encode_test_name` in `libexec/bats-core/bats-preprocess` picks an encoding strategy
with a locale-dependent regex:

```sh
if [[ ! "$name" =~ [^[:alnum:]\ _-] ]]; then
```

Under `LC_ALL=C`, non-ASCII characters are not `[:alnum:]`, so the safe hex-encoding
branch runs and the generated shell function name is pure ASCII.

Under a UTF-8 locale, `[:alnum:]` matches CJK, Cyrillic, Hangul, fullwidth and accented
letters. The fast branch runs instead and embeds raw multibyte bytes into the function
name. For a subset of those names the runtime `declare -F` lookup then fails, and the
test never runs.

Same bats binary, same test file, same bash — only `LC_ALL` differs:

| | declared | executed | ghosts | exit |
|---|---|---|---|---|
| `LC_ALL=C` | 21 | 21 | 0 | 0 |
| `LC_ALL=en_US.UTF-8` | 21 | 16 | 5 | 1 |

**The affected character set is not predictable.** `件` (U+4EF6) runs; `中` (U+4E2D)
ghosts. Both are CJK ideographs. It is not per-script, not per-length, and not
"non-ASCII" — it is per-codepoint, and we have not characterised the boundary. That is
precisely why the recommendation below is *avoid non-ASCII test names entirely* rather
than *avoid the bad ones*.

Filed upstream: (link to be added)

## Why bats' own warning is not enough

bats does print `# bats warning: Executed N instead of expected M tests` and exits
non-zero. In practice that diagnostic is easy to lose:

- it is a comment line on stderr, easily swallowed by a formatter
- `bats tests/ | tail -40` shows a healthy tail and **`tail`'s exit code**, not bats'
- CI steps that grep for `not ok` see none, because ghosts produce no line at all

A ghost test is a test that passes by not existing. It deserves a dedicated check.

## The two checks

### 1. Static — `bats-nonascii-name-check.py`

Scans `.bats` files for `@test` names containing non-ASCII characters. O(files), no bats
invocation, locale-independent.

```sh
./bats-nonascii-name-check.py tests/
```

```
tests/unit/test_sync.bats:42: non-ASCII @test name: "同期が7件で成功する"
tests/unit/test_sync.bats:58: non-ASCII @test name: "Кириллица"
2 test name(s) may not execute under a UTF-8 locale.
```

Exit codes: `0` clean, `1` findings, `2` usage error.

**This is the check to wire into CI.** It fires regardless of the locale the CI runner
happens to have, which the dynamic check does not — see below.

### 2. Dynamic — `bats-declared-vs-executed.sh`

Runs the suite and compares the TAP plan against the number of result lines, per file, so
a shortfall names the file that caused it.

```sh
./bats-declared-vs-executed.sh tests/
```

```
tests/unit/test_sync.bats: declared=12 executed=10 shortfall=2
  ghost: 同期が7件で成功する
  ghost: Кириллица
```

Slower — it re-runs bats per file — but it catches ghosting from causes other than
non-ASCII names.

## The trap: the dynamic check inherits the bug's own trigger

The ghosting only happens under a UTF-8 locale. The dynamic check runs bats through
whatever locale it inherits. **If your CI runner has `LC_ALL` unset (which behaves like
`C`), the dynamic check will report a clean suite on a file that ghosts on a developer's
UTF-8 machine.**

We hit this: a repo wired the dynamic check into its pre-push hook, and the hook chain
inherited an ambient `LC_CTYPE=C`. The gate reported `shortfall=0` against a fixture
built specifically to contain ghosting names.

If you use the dynamic check, force the locale:

```sh
LC_ALL=en_US.UTF-8 ./bats-declared-vs-executed.sh tests/
```

The static check has no such dependency.

## Recommendation

Keep `@test` names ASCII. Put the non-ASCII description in the test body:

```bash
@test "sync succeeds with 7 records" {
  # 同期が7件で成功すること
  ...
}
```

This is not a style preference. Because the affected codepoint set is uncharacterised,
there is no reliable way to tell whether a given non-ASCII name is one of the safe ones.

## Install

Both scripts are standalone — Python 3.8+ and bash respectively, no dependencies.

```sh
git clone https://github.com/KinohTaGo/bats-ghost-test-check
cp bats-ghost-test-check/bin/* /usr/local/bin/
```

## License

MIT
