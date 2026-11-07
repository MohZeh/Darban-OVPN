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
source ./lib/common.sh
darban_require_root
server_checks() {
    # The same checks as the manager and the CRL maintainer.
    darban_preflight || return 1
    [[ -s $DARBAN_SERVER_DIR/tls-crypt.key ]] || { echo 'Missing TLS-crypt server key.' >&2; return 1; }
    darban_crl_configured || { echo 'OpenVPN crl-verify is missing or points elsewhere.' >&2; return 1; }
    darban_verify_crl "$DARBAN_CRL" || { echo 'The current CRL is not valid or complete.' >&2; return 1; }
    systemctl is-active --quiet "$DARBAN_UNIT" || { echo 'OpenVPN server is not running.' >&2; return 1; }
    darban_server_serial >/dev/null || {
        echo "Cannot read the server certificate from server.conf ('cert' directive or inline <cert>)." >&2; return 1;
    }
    local mode owner
    mode=$(stat -c '%a' "$DARBAN_PKI/private/ca.key")
    owner=$(stat -c '%u' "$DARBAN_PKI/private/ca.key")
    if [[ $owner != 0 ]] || (( (8#$mode & 077) != 0 )); then
        echo 'CA private key must belong to root and must not permit group/other access.' >&2
        return 1
    fi
}
# An update replaces only the tool, so a server problem must not block the version that may fix it.
UPDATING=0
if [[ -e /usr/local/sbin/darban ]]; then UPDATING=1; fi
if ! server_checks; then
    if (( ! UPDATING )); then echo 'Preflight FAILED; nothing installed.' >&2; exit 1; fi
    echo 'WARNING: this server has a problem; see: sudo darban status. The tool is still being updated.' >&2
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
    ssh_user=${SUDO_USER:-root}
    [[ $ssh_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || ssh_user=root
    printf 'DOWNLOAD_SSH_HOST=%s\nDOWNLOAD_SSH_PORT=%s\nDOWNLOAD_SSH_USER=%s\n' "$ssh_host" "${ssh_port:-22}" "$ssh_user" >"$CONFIG_DIR/config"
    chmod 600 "$CONFIG_DIR/config"
fi

systemctl enable --now darban-crl.timer >/dev/null 2>&1 || true
if ! systemctl is-active --quiet darban-crl.timer; then
    echo 'INSTALL INCOMPLETE: CRL timer is not active. Inspect systemctl status darban-crl.timer' >&2
    exit 1
fi
# Checks the current CRL without replacing it or restarting OpenVPN. One run under the hardened unit also
# proves the sandbox allows the job; it only renews if renewal is due. An update reports a failure and goes on.
if ! /usr/local/sbin/darban-crl-maintain --check >/dev/null || ! systemctl start darban-crl.service; then
    if (( ! UPDATING )); then
        echo 'INSTALL INCOMPLETE: CRL check or service failed. Inspect journalctl -u darban-crl.service' >&2
        exit 1
    fi
    echo 'WARNING: the CRL check did not pass; see: sudo darban status.' >&2
fi
printf 'Darban OVPN v%s is installed. To open it: sudo darban\n' "$VERSION"
