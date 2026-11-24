#!/usr/bin/env bash
# acme.sh on a server without snap, on the machine rc10-upgrade-ci.sh leaves: this code installed, with a server.
# Starts Pebble, runs tests/acme-sh-ci.sh, then Remove everything and the check that acme.sh went with it.
#   acme-short-ci.sh --i-know
set -Eeuo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This reconfigures the machine. Usage: acme-short-ci.sh --i-know' >&2; exit 2; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
LOG=$(mktemp -d)
UNIT=openvpn-server@server.service
trap 'echo "FAILED at line $LINENO"; journalctl -u "$UNIT" -n 30 --no-pager || true; tail -n 20 "$LOG"/*.log 2>/dev/null || true' ERR
systemctl is-active --quiet "$UNIT"
darban status >/dev/null
bash tests/pebble-start.sh "$LOG"
ca=$(cat "$LOG/pebble-ca")
bash tests/acme-sh-ci.sh issue "$ca" "$LOG"
kernel_answer=''
if [[ $(bash /usr/local/lib/darban/remove-server.sh --kernel-status) == removable ]]; then kernel_answer='1\n'; fi
printf "1\n1\n${kernel_answer}remove-everything\n" | darban remove-all | tee "$LOG/remove-all.log"
bash tests/acme-sh-ci.sh removed "$LOG"
echo 'All acme.sh checks passed.'
