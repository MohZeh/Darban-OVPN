#!/usr/bin/env bash
# Prints code=true when a change needs the full tests, and code=false when it only touches documentation.
# Anything uncertain counts as code: a skipped test must never hide a problem.
#   EVENT=push BEFORE=<sha> bash scripts/ci-scope.sh
#   EVENT=pull_request BASE=<sha> bash scripts/ci-scope.sh
set -Eeuo pipefail

scope() {
    local from='' changed file
    # A tag is a release, and it always gets the full tests.
    case ${EVENT:-} in
        push) if [[ ${GITHUB_REF:-refs/heads/main} == refs/heads/* ]]; then from=${BEFORE:-}; fi ;;
        pull_request) from=${BASE:-} ;;
    esac
    # All zeros means a new branch or tag: there is nothing to compare with.
    if [[ -z $from || $from =~ ^0+$ ]]; then echo true; return; fi
    if ! changed=$(git diff --name-only "$from" HEAD 2>/dev/null) || [[ -z $changed ]]; then echo true; return; fi
    while IFS= read -r file; do
        case $file in
            *.md|docs/*|LICENSE|.github/ISSUE_TEMPLATE/*) ;;
            *) echo true; return ;;
        esac
    done <<<"$changed"
    echo false
}
printf 'code=%s\n' "$(scope)"
