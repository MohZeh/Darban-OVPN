#!/usr/bin/env bash
# Darban OVPN installer for an EXISTING OpenVPN server and PKI. Also used for updates.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run install.sh with sudo/root.' >&2; exit 1; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
VERSION=$(cat VERSION)

for file in setup/install.sh setup/server-setup.sh setup/get.sh setup/uninstall.sh setup/remove-server.sh bin/darban bin/darban-crl-maintain lib/common.sh lib/ui.sh; do
    bash -n "$file" || exit 1
done
for cmd in bash openssl awk grep date mktemp flock install mv systemctl ss sort timeout; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
# Preflight using exactly the same checks as the manager/maintainer.
source ./lib/common.sh
darban_require_root
darban_preflight || { echo 'Preflight FAILED; nothing installed.' >&2; exit 1; }
[[ -s $DARBAN_SERVER_DIR/tls-crypt.key ]] || { echo 'Missing TLS-crypt server key.' >&2; exit 1; }
darban_crl_configured || { echo 'OpenVPN crl-verify is missing or points elsewhere. No installation performed.' >&2; exit 1; }
darban_verify_crl "$DARBAN_CRL" || { echo 'Current CRL not valid or incomplete. Fix CRL before installing.' >&2; exit 1; }
systemctl is-active --quiet "$DARBAN_UNIT" || { echo 'OpenVPN server is not running. No installation performed.' >&2; exit 1; }
darban_server_serial >/dev/null || {
    echo "Cannot read the server certificate from server.conf ('cert' directive or inline <cert>). No installation performed." >&2; exit 1;
}
mode=$(stat -c '%a' "$DARBAN_PKI/private/ca.key")
owner=$(stat -c '%u' "$DARBAN_PKI/private/ca.key")
if [[ $owner != 0 ]] || (( (8#$mode & 077) != 0 )); then
    echo 'CA private key must belong to root and must not permit group/other access. No installation performed.' >&2
    exit 1
fi

# This tool was first installed under another name; take over its settings and remove the old files.
if [[ -d /etc/mzx-openvpn-manager && ! -e /etc/darban ]]; then
    mv -- /etc/mzx-openvpn-manager /etc/darban
    printf 'Moved settings from /etc/mzx-openvpn-manager to /etc/darban.\n'
fi
if [[ -e /etc/systemd/system/mzx-openvpn-crl.timer ]]; then
    systemctl disable --now mzx-openvpn-crl.timer >/dev/null 2>&1 || true
    rm -f -- /etc/systemd/system/mzx-openvpn-crl.timer /etc/systemd/system/mzx-openvpn-crl.service
    rm -f -- /usr/local/sbin/mzx-vpn /usr/local/sbin/mzx-openvpn-crl-maintain
    rm -rf -- /usr/local/lib/mzx-openvpn-manager
    systemctl daemon-reload
    printf 'Removed the previous mzx-vpn command; use: sudo darban\n'
fi

# Each update keeps the version it replaces, for Setup > Restore previous version.
LIB=$DARBAN_LIB
install -d -o root -g root -m 700 "$LIB"
if [[ -e /usr/local/sbin/darban && -e $LIB/common.sh ]]; then
    backup_dir="/var/backups/darban/$(date -u +%Y%m%dT%H%M%S)"
    install -d -o root -g root -m 700 /var/backups/darban "$backup_dir" "$backup_dir/sbin" "$backup_dir/lib" "$backup_dir/units"
    cp -a -- /usr/local/sbin/darban /usr/local/sbin/darban-crl-maintain "$backup_dir/sbin/"
    cp -a -- "$LIB/." "$backup_dir/lib/"
    cp -a -- /etc/systemd/system/darban-crl.service /etc/systemd/system/darban-crl.timer "$backup_dir/units/"
    if [[ -e /etc/systemd/system/darban-links.service ]]; then cp -a -- /etc/systemd/system/darban-links.service "$backup_dir/units/"; fi
    # The newest three are enough.
    find /var/backups/darban -mindepth 1 -maxdepth 1 -type d -print | sort | head -n -3 | xargs -r rm -rf --
    printf 'The previous version was kept in: %s\n' "$backup_dir"
fi

install -o root -g root -m 600 lib/common.sh "$LIB/common.sh"
install -o root -g root -m 600 lib/ui.sh "$LIB/ui.sh"
install -o root -g root -m 600 lib/linkd.py "$LIB/linkd.py"
install -o root -g root -m 700 setup/get.sh "$LIB/get.sh"
install -o root -g root -m 700 setup/uninstall.sh "$LIB/uninstall.sh"
install -o root -g root -m 700 setup/remove-server.sh "$LIB/remove-server.sh"
install -o root -g root -m 700 bin/darban-crl-maintain /usr/local/sbin/darban-crl-maintain
install -o root -g root -m 700 bin/darban /usr/local/sbin/darban
install -o root -g root -m 644 systemd/darban-crl.service /etc/systemd/system/darban-crl.service
install -o root -g root -m 644 systemd/darban-crl.timer /etc/systemd/system/darban-crl.timer
install -o root -g root -m 644 systemd/darban-links.service /etc/systemd/system/darban-links.service
systemctl daemon-reload

# Download hints live in a config file instead of the script; an existing file is kept as is.
CONFIG_DIR=/etc/darban
install -d -o root -g root -m 700 "$CONFIG_DIR"
if [[ ! -e $CONFIG_DIR/config ]]; then
    ssh_host=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
    ssh_port=$( { sshd -T 2>/dev/null || true; } | awk '$1=="port" && p=="" {p=$2} END {print p}')
    printf 'DOWNLOAD_SSH_HOST=%s\nDOWNLOAD_SSH_PORT=%s\nDOWNLOAD_SSH_USER=root\n' "$ssh_host" "${ssh_port:-22}" >"$CONFIG_DIR/config"
    chmod 600 "$CONFIG_DIR/config"
    printf 'Download settings written to %s: host %s, SSH port %s. Edit it if this is not the public SSH address.\n' \
        "$CONFIG_DIR/config" "${ssh_host:-(not detected)}" "${ssh_port:-22}"
fi

# Checks current CRL integrity but does not replace it or restart OpenVPN.
/usr/local/sbin/darban-crl-maintain --check
systemctl enable --now darban-crl.timer
if ! systemctl is-active --quiet darban-crl.timer; then
    echo 'INSTALL INCOMPLETE: CRL timer is not active. Inspect systemctl status darban-crl.timer' >&2
    exit 1
fi
# One run under the hardened unit proves the sandbox allows the job; it only renews if renewal is due.
if ! systemctl start darban-crl.service; then
    echo 'INSTALL INCOMPLETE: CRL service failed under systemd. Inspect journalctl -u darban-crl.service' >&2
    exit 1
fi
printf '\nDarban OVPN v%s installed. Run: sudo darban\n' "$VERSION"
printf 'CRL daily maintenance timer is active; no standalone CRL user menu.\n'
printf 'Project: https://github.com/MohZeh/darban-ovpn | Contact: zehtabex@gmail.com\n'
systemctl list-timers --all darban-crl.timer --no-pager
