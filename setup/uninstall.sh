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
# The script OpenVPN runs for connection events; it stays, with its lines in server.conf.
EVENT_SCRIPT=/usr/local/libexec/darban-ovpn-event

[[ ${1:-} == --yes ]] || { echo 'This removes the Darban OVPN tool. To confirm: uninstall.sh --yes' >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
# The library beside this script, read now: it is removed below.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
if [[ -r $here/common.sh ]]; then source "$here/common.sh"; fi
# The timer for the next file kept on the server, before anything else: it would start a tool that is going.
systemctl stop darban-expire.timer >/dev/null 2>&1 || true

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

# Connection events: their units and queue go. The script and its lines in server.conf stay, so OpenVPN needs no
# restart and every connection goes on: without its queue, the script writes nothing and exits 0.
events_kept=0
server_conf=${DARBAN_SERVER_CONF:-/etc/openvpn/server/server.conf}
if grep -q "^client-connect $EVENT_SCRIPT\$" "$server_conf" 2>/dev/null; then events_kept=1; fi
if declare -F darban_events_units_remove >/dev/null; then
    darban_events_units_remove "$UNITS"
else
    systemctl stop darban-expire.timer >/dev/null 2>&1 || true
    for unit in darban-events.path darban-sweep.timer darban-events.service darban-sweep.service darban-expire.service darban-events-setup.service 'run-darban\x2devents.mount'; do
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f -- "$UNITS/$unit"
    done
fi
systemctl disable --now darban-crl.timer >/dev/null 2>&1 || true
systemctl disable --now darban-geo.timer >/dev/null 2>&1 || true
# Enabled only while port-share is on; its drop-in goes with it.
systemctl disable --now darban-links.service >/dev/null 2>&1 || true
rm -rf -- "$UNITS/darban-links.service.d"
rm -f -- "$UNITS/darban-crl.timer" "$UNITS/darban-crl.service" "$UNITS/darban-links.service" "$UNITS/darban-backup.service" \
    "$UNITS/darban-geo.timer" "$UNITS/darban-geo.service"
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
  /var/backups/darban-pki (encrypted backups of the CA)
EOF
for name in "${kept_certs[@]}"; do
    printf '  %s/live/%s   (the links'"'"' Let'"'"'s Encrypt certificate; certbot still renews it)\n' "$LE_DIR" "$name"
    printf '    To delete it: sudo certbot delete --cert-name %s\n' "$name"
done
if (( events_kept )); then
    removal="\\#$EVENT_SCRIPT#d"
    if grep -qx 'script-security 2' "$CONFIG_DIR/.event-lines" 2>/dev/null; then removal+='; /^script-security 2$/d'; fi
    printf '\nKept, so connections go on without a restart:\n'
    printf '  %s   (OpenVPN runs it at each connection; it no longer records anything)\n' "$EVENT_SCRIPT"
    printf '  its lines in %s: client-connect and client-disconnect%s\n' "$server_conf" \
        "$(grep -qx 'script-security 2' "$CONFIG_DIR/.event-lines" 2>/dev/null && printf ', and script-security 2')"
    printf '  A new install of the tool uses them again.\n'
    printf "  To remove them, in this order: sudo sed -i '%s' %s && sudo systemctl restart openvpn-server@server && sudo rm %s\n" \
        "$removal" "$server_conf" "$EVENT_SCRIPT"
fi
for name in "${hook_left[@]}"; do
    printf 'WARNING: could not remove this tool'"'"'s hook from %s/renewal/%s.conf. Delete the line "renew_hook = %s" there yourself.\n' "$LE_DIR" "$name" "$RENEW_HOOK" >&2
done
cat <<'EOF'

Nothing renews the CRL any more. Renew it yourself before it expires, or OpenVPN may refuse clients.
EOF
