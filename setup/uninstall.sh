#!/usr/bin/env bash
# Removes Darban OVPN only. OpenVPN, the PKI, the CRL, server.conf and client profiles are kept.
set -Eeuo pipefail
LIB=/usr/local/lib/darban
SBIN=/usr/local/sbin
UNITS=/etc/systemd/system
LINKS=/run/darban-links

[[ ${1:-} == --yes ]] || { echo 'This removes the Darban OVPN tool. To confirm: uninstall.sh --yes' >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }

systemctl disable --now darban-crl.timer >/dev/null 2>&1 || true
systemctl stop darban-links.service >/dev/null 2>&1 || true
rm -f -- "$UNITS/darban-crl.timer" "$UNITS/darban-crl.service" "$UNITS/darban-links.service"
# Links hold copies of profiles with private keys.
rm -rf -- "$LINKS"
systemctl daemon-reload >/dev/null 2>&1 || true
rm -f -- "$SBIN/darban" "$SBIN/darban-crl-maintain"
rm -rf -- "$LIB"

cat <<'EOF'
Darban OVPN was removed.

Kept: OpenVPN, /root/pki, the CRL and server.conf.
Kept, delete these yourself if unwanted:
  /root/openvpn-clients                (profiles that contain private keys)
  /etc/darban             (hostname and download settings)
  /var/backups/darban     (older copies of the tool)

Nothing renews the CRL any more. Renew it yourself before it expires, or OpenVPN may refuse clients.
EOF
