#!/usr/bin/env bash
# For a CI runner only: puts the fastest Ubuntu mirror first in the runner's apt mirror list, so a mirror that
# is down or slow does not decide a test. Each mirror is timed on the first 2 MB of one large file of this release,
# all at once, for at most 5 seconds each. apt has a timeout only for a mirror that sends nothing, not for one that
# sends slowly, and it tries the next mirror only after one fails.
#   sudo bash scripts/ci-apt-mirrors.sh
# It changes nothing where the runner has no such list, or on a CPU other than amd64, whose packages come from
# other mirrors. It never fails the job: the list stays as it was when nothing can be measured.
set -uo pipefail
LIST=/etc/apt/apt-mirrors.txt
BYTES=2097152
summary() { printf '%s\n' "$*"; if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi; }

if [[ ! -s $LIST ]]; then summary "apt mirrors: this runner has no $LIST; nothing changed."; exit 0; fi
if [[ $(dpkg --print-architecture 2>/dev/null) != amd64 ]]; then summary 'apt mirrors: not amd64; nothing changed.'; exit 0; fi
. /etc/os-release
codename=${VERSION_CODENAME:-}
[[ $codename =~ ^[a-z]+$ ]] || { summary 'apt mirrors: no release codename; nothing changed.'; exit 0; }

# The mirrors the runner lists, then others that carry the whole archive. Each once, with a trailing slash.
mapfile -t mirrors < <({ awk '{print $1}' "$LIST"; printf '%s\n' http://mirrors.edge.kernel.org/ubuntu/ \
    http://azure.archive.ubuntu.com/ubuntu/ http://archive.ubuntu.com/ubuntu/; } |
    grep -E '^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]*$' | sed 's#/*$#/#' | awk '!seen[$0]++')
(( ${#mirrors[@]} )) || { summary 'apt mirrors: none could be read; nothing changed.'; exit 0; }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
for i in "${!mirrors[@]}"; do
    # Contents-amd64.gz is tens of megabytes on every full mirror, at the same path. The line ends in a newline:
    # without one, read below fails, and every mirror would count as one that did not answer.
    curl -sS -r "0-$((BYTES - 1))" -o /dev/null --connect-timeout 3 --max-time 5 \
        -w '%{http_code} %{size_download} %{speed_download}\n' "${mirrors[i]}dists/$codename/Contents-amd64.gz" \
        >"$work/$i" 2>/dev/null &
done
wait

# A mirror that did not send the whole 2 MB is judged by what it sent in its 5 seconds, so it ranks low.
for i in "${!mirrors[@]}"; do
    read -r code size speed <"$work/$i" 2>/dev/null || { code=000 size=0 speed=0; }
    [[ $code == 206 || $code == 200 ]] || speed=0
    [[ $size =~ ^[0-9]+$ ]] || size=0
    speed=${speed%%.*}
    [[ $speed =~ ^[0-9]+$ ]] || speed=0
    printf '%s %s %s %s\n' "$speed" "$i" "$code" "$size"
done | sort -k1,1nr -k2,2n >"$work/ranked"

if ! awk '$1 > 0 {found = 1} END {exit !found}' "$work/ranked"; then summary 'apt mirrors: no mirror answered the test; the list stays as it was.'; exit 0; fi
summary "apt mirrors on Ubuntu $VERSION_ID, fastest first (2 MB, at most 5 s each):"
: >"$work/list"
priority=1
while read -r speed i code size; do
    summary "- ${mirrors[i]}: $((speed / 1024)) KB/s, HTTP $code, $size bytes"
    printf '%s\tpriority:%s\n' "${mirrors[i]}" "$priority" >>"$work/list"
    priority=$((priority + 1))
done <"$work/ranked"
install -m 644 "$work/list" "$LIST"
