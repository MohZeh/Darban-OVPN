#!/usr/bin/env bash
# Removes Darban OVPN only. OpenVPN, the PKI, the CRL, server.conf and client profiles are kept.
set -Eeuo pipefail
LIB=/usr/local/lib/darban
SBIN=/usr/local/sbin
UNITS=/etc/systemd/system
LINKS=/run/darban-links
CONFIG_DIR=/etc/darban
LE_DIR=/etc/letsencrypt
# The deploy hook this tool puts in certbot's renewal file of the links' certificate.
RENEW_HOOK='/usr/local/sbin/darban reload-links'
CERT_NAME=darban-ovpn-links

[[ ${1:-} == --yes ]] || { echo 'This removes the Darban OVPN tool. To confirm: uninstall.sh --yes' >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
# The library beside this script, read now: it is removed below.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
if [[ -r $here/common.sh ]]; then source "$here/common.sh"; fi

# The links' Let's Encrypt certificate stays, and certbot goes on renewing it. Only this tool's hook in its
# renewal file goes, since the program it runs is removed: the certificate of this tool's own name, and any the
# setup recorded. A hook someone else set stays.
kept_certs=()
hook_left=()
while IFS= read -r name; do
    [[ -n $name && -f $LE_DIR/renewal/$name.conf ]] || continue
    kept_certs+=("$name")
    if ! declare -F darban_renew_hook >/dev/null \
        || ! darban_renew_hook absent "$LE_DIR/renewal/$name.conf" "$RENEW_HOOK" "${DARBAN_RENEW_HOOK_OLD:-systemctl try-restart darban-links.service}"; then
        hook_left+=("$name")
    fi
done < <({ printf '%s\n' "$CERT_NAME"; awk '$1=="certbot_cert" && $2 ~ /^[A-Za-z0-9._-]+$/ {print $2}' "$CONFIG_DIR/.server-setup-started" 2>/dev/null || true; } | sort -u)

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
EOF
for name in "${kept_certs[@]}"; do
    printf '  %s/live/%s   (the links'"'"' Let'"'"'s Encrypt certificate; certbot still renews it)\n' "$LE_DIR" "$name"
    printf '    To delete it: sudo certbot delete --cert-name %s\n' "$name"
done
for name in "${hook_left[@]}"; do
    printf 'WARNING: could not remove this tool'"'"'s hook from %s/renewal/%s.conf. Delete the line "renew_hook = %s" there yourself.\n' "$LE_DIR" "$name" "$RENEW_HOOK" >&2
done
cat <<'EOF'

Nothing renews the CRL any more. Renew it yourself before it expires, or OpenVPN may refuse clients.
EOF
