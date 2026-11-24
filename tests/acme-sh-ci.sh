#!/usr/bin/env bash
# acme.sh on a server without snap, for tests/acceptance-ci.sh, which runs it on a throwaway runner as root:
#   acme-sh-ci.sh issue <CA file of the test ACME server> <log folder>
#       the tool installs acme.sh, checked by its SHA-256, and gets the links' certificate with it from Pebble,
#       Let's Encrypt's test server, which Acceptance started at https://localhost:14000/dir. A renewal reaches the
#       links, and a test with the "staging" server leaves the real certificate as it was.
#   acme-sh-ci.sh removed <log folder>
#       after Remove everything: acme.sh, its folder and its timer are gone.
# CI never asks the real Let's Encrypt, so it never uses its limit.
set -Eeuo pipefail
trap 'echo "FAIL: acme-sh-ci.sh line $LINENO: $BASH_COMMAND" >&2' ERR
ACME_HOME=/var/lib/darban-acme
ACME_BIN=$ACME_HOME/acme.sh-3.1.6/acme.sh
MARKER=/etc/darban/.server-setup-started
HOST=203.0.113.10

case ${1:-} in
issue)
    ca=$2 LOG=$3
    # A server without snap, where certbot cannot get an IP certificate: snap and every certbot are out of reach
    # for this test, and apt may install no certbot. All of it comes back at the end.
    hidden=()
    restore() {
        local path
        for path in "${hidden[@]}"; do mv -f -- "$path.darban-hidden" "$path"; done
        rm -f /etc/apt/preferences.d/darban-acme-test
    }
    trap restore EXIT
    for path in /usr/bin/snap /snap/bin/certbot /usr/bin/certbot /usr/local/bin/certbot; do
        if [[ -e $path ]]; then mv -- "$path" "$path.darban-hidden"; hidden+=("$path"); fi
    done
    printf 'Package: certbot\nPin: version *\nPin-Priority: -1\n' > /etc/apt/preferences.d/darban-acme-test
    if command -v snap >/dev/null || command -v certbot >/dev/null; then echo 'FAIL: snap or certbot is still reachable.'; exit 1; fi
    cp /etc/darban/domain "$LOG/acme-domain.before"
    echo "$HOST" > /etc/darban/domain
    export DARBAN_TEST_ACME_SERVER=https://localhost:14000/dir DARBAN_TEST_ACME_CA=$ca

    printf '7\n5\n2\n0\n0\n' | darban | tee "$LOG/acme-issue.log"
    grep 'acme.sh 3.1.6 is installed in /var/lib/darban-acme/acme.sh-3.1.6, checked by its SHA-256.' "$LOG/acme-issue.log" >/dev/null
    grep "New certificate from Let's Encrypt for $HOST, by acme.sh" "$LOG/acme-issue.log" >/dev/null
    # The one file acme.sh is all of it here: no DNS, deploy or notify scripts.
    [[ $(ls -A "$ACME_HOME/acme.sh-3.1.6") == acme.sh ]]
    [[ $(cat /etc/darban/link-cert/current/kind) == acme.sh ]]
    cmp -s /etc/darban/link-cert.pem "$ACME_HOME/links/fullchain.pem"
    openssl x509 -in /etc/darban/link-cert.pem -noout -checkip "$HOST" | grep 'does match' >/dev/null
    openssl x509 -in /etc/darban/link-cert.pem -noout -issuer | grep -i pebble >/dev/null
    grep -qx "acme_sh $ACME_HOME" "$MARKER"
    systemctl is-enabled --quiet darban-acme.timer
    systemctl is-active --quiet darban-acme.timer
    # Nothing of acme.sh in root's home or crontab.
    [[ ! -e /root/.acme.sh ]]
    if crontab -l 2>/dev/null | grep acme.sh >/dev/null; then echo "FAIL: acme.sh is in root's crontab."; exit 1; fi
    echo 'PASS: without snap, acme.sh 3.1.6, checked by its SHA-256, gets the links'"'"' certificate for an IP address (Pebble).'

    darban status >"$LOG/acme-status.log" 2>&1 || true
    grep "Link certificate from Let's Encrypt by acme.sh 3.1.6" "$LOG/acme-status.log" >/dev/null
    printf '7\n5\n4\n0\n0\n' | darban | tee "$LOG/acme-details.log"
    grep 'acme.sh 3.1.6, installed by this tool in /var/lib/darban-acme' "$LOG/acme-details.log" >/dev/null
    grep 'darban-acme.timer runs acme.sh twice a day' "$LOG/acme-details.log" >/dev/null
    echo 'PASS: Diagnostics and Details say acme.sh got it, and how it renews.'

    # The timer's own service runs as its unit says, with NoNewPrivileges and PrivateTmp.
    systemctl start darban-acme.service
    [[ $(systemctl show -p Result --value darban-acme.service) == success ]]
    cmp -s /etc/darban/link-cert.pem "$ACME_HOME/links/fullchain.pem"
    echo 'PASS: the renewal service of acme.sh runs as its unit says.'

    # A renewal by acme.sh reaches the links through the reload command the tool set.
    before=$(openssl x509 -in /etc/darban/link-cert.pem -noout -fingerprint -sha256)
    "$ACME_BIN" --home "$ACME_HOME/acme.sh-3.1.6" --config-home "$ACME_HOME/data" --renew -d "$HOST" --ecc --force \
        --server "$DARBAN_TEST_ACME_SERVER" --ca-bundle "$ca" 2>&1 | tee "$LOG/acme-renew.log"
    cmp -s /etc/darban/link-cert.pem "$ACME_HOME/links/fullchain.pem"
    [[ $(openssl x509 -in /etc/darban/link-cert.pem -noout -fingerprint -sha256) != "$before" ]]
    echo "PASS: acme.sh's renewal reaches the links through its reload command."

    # The staging test, here against Pebble as well: the real certificate, the links and the record stay.
    # Every file of the real certificate, the pair in use and the record, without acme.sh's backup folder.
    real_state() {
        { cat /etc/darban/link-cert.pem /etc/darban/link-key.pem /var/lib/darban/link-certificates.log
          find "$ACME_HOME/links" "$ACME_HOME/data/${HOST}_ecc" -type f -print0 | sort -z | xargs -0 sha256sum; } | sha256sum
    }
    real=$(real_state)
    printf '7\n5\n5\n2\n0\n0\n' | darban | tee "$LOG/acme-staging.log"
    grep "The staging server issued a test certificate for $HOST with acme.sh" "$LOG/acme-staging.log" >/dev/null
    [[ -s $ACME_HOME/staging/certificate/fullchain.pem ]]
    [[ $(real_state) == "$real" ]]
    printf '7\n5\n5\n1\n0\n0\n' | darban | tee "$LOG/acme-staging-delete.log"
    grep 'The test certificate was deleted.' "$LOG/acme-staging-delete.log" >/dev/null
    [[ ! -e $ACME_HOME/staging/certificate ]]
    echo 'PASS: the staging test leaves the real certificate, the links and the record as they were, and can be deleted.'
    cp "$LOG/acme-domain.before" /etc/darban/domain
    ;;
removed)
    if [[ -e $ACME_HOME ]]; then echo "FAIL: $ACME_HOME is still there after Remove everything."; exit 1; fi
    if [[ -e /etc/systemd/system/darban-acme.timer || -e /etc/systemd/system/darban-acme.service ]]; then echo 'FAIL: the acme.sh timer is still there.'; exit 1; fi
    if systemctl is-active --quiet darban-acme.timer; then echo 'FAIL: the acme.sh timer still runs.'; exit 1; fi
    echo 'PASS: Remove everything removes acme.sh, its folder and its timer.'
    ;;
*)
    echo 'Usage: acme-sh-ci.sh issue <CA file> <log folder> | removed <log folder>' >&2
    exit 2 ;;
esac
