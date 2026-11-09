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

bash setup/server-setup.sh --yes --host "$HOST" --port 1194
grep -qx setup_complete "$MARKER"
echo "PASS: the setup on a public IP address finished."

# certbot 5.3 or newer is needed for an IP address; Ubuntu's is older, so it comes from the snap.
if command -v snap >/dev/null; then
    grep -qx 'snap certbot' "$MARKER"
    [[ -x /snap/bin/certbot ]]
    echo 'PASS: the setup installed certbot from the snap, and recorded it for removal.'
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
