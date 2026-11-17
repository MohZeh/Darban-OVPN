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
