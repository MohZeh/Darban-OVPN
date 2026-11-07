#!/usr/bin/env bash
# Fast checks that need no server. CI runs this first; run it yourself on Linux before a commit.
set -Eeuo pipefail
cd -- "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

mapfile -t scripts < <(git ls-files 'setup/*.sh' 'bin/*' 'lib/*.sh' 'scripts/*.sh' 'tests/*.sh' 'docs/assets/*.sh')
shellcheck --severity=warning "${scripts[@]}"
printf 'ShellCheck: %d files clean.\n' "${#scripts[@]}"
python3 scripts/check-repo.py
