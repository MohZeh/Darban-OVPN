#!/usr/bin/env bash
# The real setup for a server on a public address, the path the other runs never take: they use 127.0.0.1,
# which needs no trusted certificate, so no certbot. Only for a disposable machine, such as a CI runner.
#   public-setup-ci.sh --i-know
set -Eeuo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This reconfigures the machine. Usage: public-setup-ci.sh --i-know' >&2; exit 2; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
MARKER=/etc/darban/.server-setup-started
# A documentation address: public to the tool, so it takes the public path, and nothing answers on it.
HOST=203.0.113.10
trap 'echo "FAILED at line $LINENO"; tail -n 40 /var/log/darban-setup.log 2>/dev/null || true' ERR
setup_times() {
    # setup_times <label>: how long each slow part of the setup took, in the summary of every run, not only a failed
    # one, so the weekly runs keep a record of how long installs take. The lines hold labels and times only.
    local times
    times=$(grep '^==' /var/log/darban-setup.log 2>/dev/null || true)
    printf 'Setup times:\n%s\n' "${times:-none recorded}"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '**Setup times, %s**\n\n```\n%s\n```\n' "$1" "${times:-none recorded}" >>"$GITHUB_STEP_SUMMARY"
    fi
}
snap_retry_lines() {
    # snap_retry_lines <label>: what the certbot snap install said about its second try, from the setup log, in
    # the job log and the summary. Those lines stay in the log on a passing run, so without this nobody sees
    # whether the retry ever fired. Never fails.
    local lines
    lines=$(grep -E 'trying once more|still installing certbot|snapd does not answer' /var/log/darban-setup.log 2>/dev/null || true)
    printf 'Snap retry lines:\n%s\n' "${lines:-none: certbot came on the first try, or was not installed}" || true
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '**Snap retry lines, %s**\n\n```\n%s\n```\n' "$1" "${lines:-none}" >>"$GITHUB_STEP_SUMMARY" || true
    fi
    return 0
}

bash setup/server-setup.sh --yes --host "$HOST" --port 1194
grep -qx setup_complete "$MARKER"
echo "PASS: the setup on a public IP address finished."
setup_times "Ubuntu $(. /etc/os-release && echo "$VERSION_ID"), public address, with certbot"
snap_retry_lines "Ubuntu $(. /etc/os-release && echo "$VERSION_ID"), public address"

# certbot 5.3 or newer is needed for an IP address; Ubuntu's is older, so it comes from the snap.
if command -v snap >/dev/null; then
    if grep -qx 'snap certbot' "$MARKER"; then
        [[ -x /snap/bin/certbot ]]
        echo 'PASS: the setup installed certbot from the snap, and recorded it for removal.'
    elif ! timeout 60 snap info certbot >/dev/null 2>&1; then
        # The Snap Store itself is down, which no change here can fix: the setup must still finish, and did.
        echo 'NOTE: the Snap Store does not answer, so the setup could not install certbot; this check is skipped.'
    elif DARBAN_SNAP_RETRY_DELAY=30 bash -c 'set -uo pipefail; source lib/common.sh; darban_snap_install_certbot "$1"' _ "$MARKER"; then
        # The store answered, the setup's two tries failed, and the same code installed it a moment later: the
        # store failed for a moment, which no change here can fix. The removal below is still checked.
        reason='the Snap Store failed both tries of the setup; the same code installed certbot a moment later'
        echo "NOT TESTED: certbot from the snap during the setup: $reason"
        if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then echo "Not tested: certbot from the snap during the setup: $reason" >>"$GITHUB_STEP_SUMMARY"; fi
    else
        echo 'FAIL: the Snap Store answers, but neither the setup nor the same code once more installed certbot.'
        grep -iE 'certbot|snap' /var/log/darban-setup.log 2>/dev/null | tail -n 20 || true
        echo "What snap says: $(timeout 300 snap install --classic certbot 2>&1 | tail -n 3 | tr '\n' ' ')"
        exit 1
    fi
else
    echo 'NOTE: this runner has no snap, so the setup could only skip certbot.'
fi

bash setup/install.sh
darban version >/dev/null
echo 'PASS: the tool installs on that server.'

bash /usr/local/lib/darban/remove-server.sh --yes
if [[ -x /snap/bin/certbot ]] && grep -q 'snap certbot' "$MARKER" 2>/dev/null; then echo 'FAIL: certbot was not removed.'; exit 1; fi
if command -v snap >/dev/null && snap list certbot >/dev/null 2>&1; then echo 'FAIL: the certbot snap is still installed.'; exit 1; fi
echo 'PASS: Remove everything takes the certbot it added away again.'
