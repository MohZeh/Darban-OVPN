#!/usr/bin/env bash
# Prints tested=true when a push to main holds exactly the files that its pull request's CI already tested
# and passed, so the slow tests do not run twice on the same content. Anything uncertain prints tested=false.
#   REPO=owner/name SHA=<pushed commit> GH_TOKEN=<token> bash scripts/ci-already-tested.sh
# The rules of main require a pull request that is up to date with main and green, so its last commit
# holds what the merge puts on main. That is checked here, not assumed: the same tree, and a green run.
set -Eeuo pipefail

tested() {
    local tree prs pr head runs
    tree=$(git rev-parse --verify --quiet "$SHA^{tree}") || return 1
    prs=$(gh api "repos/$REPO/commits/$SHA/pulls" --jq '.[] | select(.merged_at != null) | .number') || return 1
    for pr in $prs; do
        [[ $pr =~ ^[0-9]+$ ]] || continue
        head=$(gh api "repos/$REPO/pulls/$pr" --jq '.head.sha') || continue
        [[ $head =~ ^[0-9a-f]{40}$ ]] || continue
        git fetch -q --no-tags "${REMOTE:-origin}" "refs/pull/$pr/head" 2>/dev/null || continue
        [[ $(git rev-parse FETCH_HEAD) == "$head" ]] || continue
        [[ $(git rev-parse "$head^{tree}") == "$tree" ]] || continue
        runs=$(gh api "repos/$REPO/actions/workflows/ci.yml/runs?head_sha=$head&event=pull_request&status=success&per_page=1" --jq '.total_count') || continue
        [[ $runs =~ ^[0-9]+$ ]] && (( runs > 0 )) || continue
        printf 'Pull request #%s already tested these exact files, at %s, and passed.\n' "$pr" "$head" >&2
        return 0
    done
    return 1
}
if tested; then echo tested=true; else echo tested=false; fi
