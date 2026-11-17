#!/usr/bin/env bash
# Fast checks that need no server. CI runs this first; run it yourself on Linux before a commit.
set -Eeuo pipefail
cd -- "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

mapfile -t scripts < <(git ls-files 'setup/*.sh' 'bin/*' 'lib/*.sh' 'scripts/*.sh' 'tests/*.sh' 'docs/assets/*.sh')
shellcheck --severity=warning "${scripts[@]}"
printf 'ShellCheck: %d files clean.\n' "${#scripts[@]}"
# Every Python file compiles, read only: no __pycache__ is written.
git ls-files -z '*.py' | python3 -c '
import sys
files = [f for f in sys.stdin.buffer.read().decode().split("\0") if f]
for f in files:
    with open(f, encoding="utf-8") as src:
        compile(src.read(), f, "exec")
print(f"Python: {len(files)} files compile.")
'
python3 scripts/check-repo.py
# The suite's runner fails when its filter matches no test, so a mistyped name never passes with nothing run. This
# ends before any test starts.
if bash tests/run-tests.sh no_test_has_this_name >/dev/null 2>&1; then echo 'run-tests.sh passed a filter that matched no test' >&2; exit 1; fi
echo 'run-tests.sh: a filter that matches no test fails.'
# A test that calls exit ends the whole run; with status 0 it must still fail, and a test that passes must not.
extra=$(mktemp)
trap 'rm -f -- "$extra"' EXIT
printf '%s\n' "test_zz_lint_ends_early() { ok_if 'one check' true; exit 0; }" "test_zz_lint_passes() { ok_if 'one check' true; }" >"$extra"
if RUN_TESTS_EXTRA=$extra bash tests/run-tests.sh test_zz_lint_ends_early >/dev/null 2>&1; then echo 'run-tests.sh passed a run a test ended early with exit 0' >&2; exit 1; fi
RUN_TESTS_EXTRA=$extra bash tests/run-tests.sh test_zz_lint_passes >/dev/null 2>&1 || { echo 'run-tests.sh failed a test that passes' >&2; exit 1; }
echo 'run-tests.sh: a run that ends early fails, and a test that passes passes.'
