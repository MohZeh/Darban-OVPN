#!/usr/bin/env bash
# Darban OVPN installer for an EXISTING OpenVPN server and PKI. Also used for updates.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run install.sh with sudo/root.' >&2; exit 1; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
VERSION=$(cat VERSION)

for file in setup/install.sh setup/server-setup.sh setup/get.sh setup/uninstall.sh setup/remove-server.sh bin/darban bin/darban-crl-maintain bin/darban-ovpn-event lib/common.sh lib/ui.sh lib/darban/*.sh; do
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

# Each update keeps the version it replaces, for Setup > Restore previous version.
LIB=$DARBAN_LIB
install -d -o root -g root -m 700 "$LIB"
# Written last, so a run that stops half way is repaired by the next one, even with the same version.
rm -f -- "$LIB/.installed"
if [[ -e /usr/local/sbin/darban && -e $LIB/common.sh ]]; then
    backup_dir="/var/backups/darban/$(date -u +%Y%m%dT%H%M%S)"
    install -d -o root -g root -m 700 /var/backups/darban "$backup_dir" "$backup_dir/sbin" "$backup_dir/lib" "$backup_dir/units"
    # An install that stopped half way may have left only some of these, and the repair must still go on.
    for file in /usr/local/sbin/darban /usr/local/sbin/darban-crl-maintain; do
        if [[ -e $file ]]; then cp -a -- "$file" "$backup_dir/sbin/"; fi
    done
    cp -a -- "$LIB/." "$backup_dir/lib/"
    for file in /etc/systemd/system/darban-crl.service /etc/systemd/system/darban-crl.timer /etc/systemd/system/darban-links.service /etc/systemd/system/darban-backup.service /etc/systemd/system/darban-geo.service /etc/systemd/system/darban-geo.timer; do
        if [[ -e $file ]]; then cp -a -- "$file" "$backup_dir/units/"; fi
    done
    # The units of connection events, when the version replaced had them: going back to it keeps them.
    for unit in $DARBAN_EVENT_UNITS; do
        if [[ -e /etc/systemd/system/$unit ]]; then cp -a -- "/etc/systemd/system/$unit" "$backup_dir/units/"; fi
    done
    # The newest three are enough.
    find /var/backups/darban -mindepth 1 -maxdepth 1 -type d -print | sort | head -n -3 | xargs -r rm -rf --
fi

install -o root -g root -m 600 lib/common.sh "$LIB/common.sh"
install -o root -g root -m 600 lib/ui.sh "$LIB/ui.sh"
install -o root -g root -m 600 lib/linkd.py "$LIB/linkd.py"
install -o root -g root -m 600 lib/backup.py "$LIB/backup.py"
install -o root -g root -m 600 lib/geolist.py "$LIB/geolist.py"
install -o root -g root -m 700 setup/get.sh "$LIB/get.sh"
install -o root -g root -m 700 setup/uninstall.sh "$LIB/uninstall.sh"
install -o root -g root -m 700 setup/remove-server.sh "$LIB/remove-server.sh"
# The manager's modules, which bin/darban sources from $LIB/modules. They come before the manager itself, so a run
# that stops half way never leaves a manager that sources a module it does not have.
install -d -o root -g root -m 700 "$LIB/modules"
for module in lib/darban/*.sh; do
    install -o root -g root -m 600 "$module" "$LIB/modules/${module##*/}"
done
install -o root -g root -m 700 bin/darban-crl-maintain /usr/local/sbin/darban-crl-maintain
install -o root -g root -m 700 bin/darban /usr/local/sbin/darban
install -o root -g root -m 644 systemd/darban-crl.service /etc/systemd/system/darban-crl.service
install -o root -g root -m 644 systemd/darban-crl.timer /etc/systemd/system/darban-crl.timer
install -o root -g root -m 644 systemd/darban-links.service /etc/systemd/system/darban-links.service
install -o root -g root -m 644 systemd/darban-backup.service /etc/systemd/system/darban-backup.service
# The daily list of blocked destinations; Settings turns its timer on and off.
install -o root -g root -m 644 systemd/darban-geo.service /etc/systemd/system/darban-geo.service
install -o root -g root -m 644 systemd/darban-geo.timer /etc/systemd/system/darban-geo.timer
# Connection events. The script OpenVPN runs lives outside $LIB, where OpenVPN's user can run it, so no uninstall
# or restore of any version leaves server.conf naming a script that is gone.
install -d -o root -g root -m 755 /usr/local/libexec
install -o root -g root -m 755 bin/darban-ovpn-event /usr/local/libexec/darban-ovpn-event
for unit in darban-events-setup.service darban-events.path darban-events.service darban-sweep.timer darban-sweep.service darban-expire.service; do
    install -o root -g root -m 644 "systemd/$unit" "/etc/systemd/system/$unit"
done
# systemd names the unit of a mount after its path.
install -o root -g root -m 644 systemd/darban-events.mount '/etc/systemd/system/run-darban\x2devents.mount'
systemctl daemon-reload

# A restore of the CA that stopped half way is finished before anything below touches OpenVPN or the CRL.
if [[ -e $DARBAN_RESTORE_JOURNAL ]]; then
    /usr/local/sbin/darban restore --resume </dev/null || { echo 'INSTALL INCOMPLETE: a restore of the CA is unfinished. See: sudo darban status' >&2; exit 1; }
fi

# What the install writes in /etc/darban and the NAT file, it writes under the lock every writer of the server's
# configuration takes, so a CRL renewal or a change in the menu never meets half of it.
darban_lock 60 || { echo 'INSTALL INCOMPLETE: another Darban operation holds the lock. Run the same command again.' >&2; exit 1; }
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
# The CRL check below takes the same lock itself.
flock -u 9; exec 9>&-

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
# The NAT file is written again from server.conf, so an install from before clients were kept apart gets
# that rule, and a network change that stopped half way is put right. Without success the install is not
# marked complete, so running the same command again tries once more.
darban_lock 60 || { echo 'INSTALL INCOMPLETE: another Darban operation holds the lock. Run the same command again.' >&2; exit 1; }
NAT_FILE=/etc/darban/nat.nft
NAT_UNIT=/etc/systemd/system/darban-nat.service
# A file that is gone, while the unit that loads it at boot is still there, is written again: the rules run now,
# but after a reboot clients would have no internet. Its interface comes from the rules that run, else from the
# default route.
if [[ -f $NAT_FILE || -e $NAT_UNIT ]]; then
    vpn_net=$(darban_conf_net)
    if [[ -f $NAT_FILE ]]; then
        nat_iface=$(darban_nat_iface "$NAT_FILE")
    else
        echo "$NAT_FILE was missing; it is written again from server.conf."
        nat_iface=$(nft list chain ip darban postrouting 2>/dev/null | darban_nat_iface || true)
        [[ -n $nat_iface ]] || nat_iface=$(darban_default_iface)
    fi
    # An interface that is gone, for example renamed by a new image, leaves clients without internet: NAT then
    # follows the default route. One that still exists is kept, because it may be chosen on purpose.
    if [[ -n $nat_iface ]] && ! ip link show dev "$nat_iface" >/dev/null 2>&1; then
        route_iface=$(darban_default_iface)
        if [[ $route_iface =~ ^[A-Za-z0-9_.@-]+$ ]]; then
            echo "NAT used $nat_iface, which this server no longer has; it now uses $route_iface, the interface of the default route."
            nat_iface=$route_iface
        fi
    fi
    if valid_ipv4 "${vpn_net:-}" && [[ $nat_iface =~ ^[A-Za-z0-9_.@-]+$ ]]; then
        darban_nat_rules "$vpn_net" "$nat_iface" > "$NAT_FILE.new"
        chmod 600 "$NAT_FILE.new"
        if cmp -s -- "$NAT_FILE.new" "$NAT_FILE" && darban_live_nat_ok "$vpn_net" && darban_live_isolation_ok "$vpn_net" && darban_live_mss_ok "$vpn_net"; then
            rm -f -- "$NAT_FILE.new"
        elif nft -c -f "$NAT_FILE.new" && { [[ ! -f $NAT_FILE ]] || cp -a -- "$NAT_FILE" "$NAT_FILE.before"; } && mv -f -- "$NAT_FILE.new" "$NAT_FILE" \
            && nft -f "$NAT_FILE" && darban_live_nat_ok "$vpn_net" && darban_live_isolation_ok "$vpn_net" && darban_live_mss_ok "$vpn_net"; then
            rm -f -- "$NAT_FILE.before"
            echo "The NAT rules are up to date: VPN clients are kept apart from each other, and TCP MSS for VPN traffic is limited to $(darban_mss)."
        else
            if [[ -f $NAT_FILE.before ]]; then mv -f -- "$NAT_FILE.before" "$NAT_FILE"; nft -f "$NAT_FILE" || true; fi
            rm -f -- "$NAT_FILE.new"
            echo 'INSTALL INCOMPLETE: could not load the NAT rules that keep VPN clients apart. Run the same command again; if it fails again, see: sudo darban status' >&2
            exit 1
        fi
    else
        # A file edited by hand is left as it is, so an update never blocks; but it is not passed over in silence.
        echo "NOTE: the NAT rules were not checked, because server.conf has no single /24 VPN network or $NAT_FILE names no outgoing interface. See: sudo darban status" >&2
    fi
fi
flock -u 9; exec 9>&-
# The links' Let's Encrypt certificate, kept through an uninstall, gets this tool's hook back, so a renewal by
# certbot reaches the links again. A hook someone else set there stays.
LE_RENEWAL=/etc/letsencrypt/renewal/darban-ovpn-links.conf
if [[ -e $LE_RENEWAL ]] && ! darban_renew_hook present "$LE_RENEWAL" '/usr/local/sbin/darban reload-links' "$DARBAN_RENEW_HOOK_OLD"; then
    echo "NOTE: could not add this tool's hook to $LE_RENEWAL. certbot still renews the links' certificate; links take a renewal with the next link." >&2
fi
# Connection events: the queue and its jobs first, then the lines in server.conf, which the tool writes only when
# every check passes, with one restart and the way back. Without them, links end as before: when they expire, or
# when the link service sees the connection.
if systemctl enable --now 'run-darban\x2devents.mount' darban-events-setup.service darban-events.path darban-sweep.timer >/dev/null 2>&1; then
    /usr/local/sbin/darban enable-events </dev/null || echo 'NOTE: connection events were not turned on. Running the same command again tries once more; see: sudo darban status' >&2
else
    echo 'NOTE: the queue of connection events did not start, so they stay off. See: systemctl status darban-events-setup.service' >&2
fi
printf '%s\n' "$VERSION" > "$LIB/.installed"
printf 'Darban OVPN v%s is installed. To open it: sudo darban\n' "$VERSION"
