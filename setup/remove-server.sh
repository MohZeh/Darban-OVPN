#!/usr/bin/env bash
# Removes what setup/server-setup.sh created: OpenVPN, the CA, client profiles, NAT, and this tool.
# It works only from the record that setup left, so a server it did not set up is never touched.
# Packages are removed only if setup added them and nothing else would be removed along with them.
#   remove-server.sh --yes [--backup] [--kernel]
#   remove-server.sh --kernel-status   prints: removable, running or none
set -Euo pipefail
umask 077

PKI=/root/pki
SERVER_DIR=/etc/openvpn/server
OUT_DIR=/root/openvpn-clients
CONFIG_DIR=/etc/darban
APT_KEY=/etc/apt/keyrings/openvpn-repo-public.asc
APT_LIST=/etc/apt/sources.list.d/openvpn-aptrepo.list
SYSCTL_FILE=/etc/sysctl.d/99-darban.conf
MODULES_FILE=/etc/modules-load.d/darban-ovpn.conf
NAT_UNIT=/etc/systemd/system/darban-nat.service
BACKUP_DIR=/root
TOOL_BACKUPS=/var/backups/darban
LOCK_FILE=/run/darban.lock
UNIT=openvpn-server@server.service
MARKER=$CONFIG_DIR/.server-setup-started
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l

FAILED=()
KEPT=()
KEPT_FILES=''
try() { "$@" || FAILED+=("$*"); }
recorded() { awk -v kind="$1" '$1==kind && $2 ~ /^[a-z0-9][a-z0-9+.:-]+$/ {print $2}' "$MARKER" | sort -u; }
base_names() { sed 's/:.*//' | sort -u; }

kernel_status() {
    local list
    list=$(recorded kernel)
    if [[ -z $list ]]; then echo none; return 0; fi
    if grep -Fxq -- "linux-image-$(uname -r)" <<<"$list"; then echo running; else echo removable; fi
}
purge_exact() {
    # Purges exactly these packages, or keeps them if apt would have to remove anything else too.
    local removed extra
    (( $# > 0 )) || return 0
    if ! removed=$(apt-get -s purge "$@" | awk '$1=="Remv" {print $2}' | base_names); then
        FAILED+=("simulating the removal of: $*")
        return 0
    fi
    extra=$(grep -Fvx -f <(printf '%s\n' "$@" | base_names) <<<"$removed" || true)
    if [[ -n $extra ]]; then
        KEPT+=("$* (removing them would also remove: ${extra//$'\n'/ })")
        return 0
    fi
    try apt-get -o DPkg::Lock::Timeout=300 -y -q purge "$@"
}

ALLOW=0 BACKUP=0 KERNEL=0
case "$#:${1:-}" in
    1:--kernel-status)
        [[ -r $MARKER ]] || { echo none; exit 0; }
        kernel_status
        exit 0 ;;
esac
while (( $# )); do
    case $1 in
        --yes) ALLOW=1 ;;
        --backup) BACKUP=1 ;;
        --kernel) KERNEL=1 ;;
        *) printf 'Usage: remove-server.sh --yes [--backup] [--kernel]\n' >&2; exit 2 ;;
    esac
    shift
done
(( ALLOW )) || { echo 'This permanently removes OpenVPN, the CA and all client profiles. To confirm: remove-server.sh --yes' >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
[[ -r $MARKER ]] || { echo 'This server was not set up by server-setup.sh, so nothing was removed.' >&2; exit 1; }
if (( KERNEL )) && [[ $(kernel_status) != removable ]]; then
    echo 'The kernel cannot be removed: the system is running it, or setup did not install one. Nothing was removed.' >&2
    exit 1
fi

backup_file=''
if (( BACKUP )); then
    backup_file=$BACKUP_DIR/darban-backup-$(date -u +%Y%m%dT%H%M%S).tar.gz
    paths=()
    for path in "$PKI" "$SERVER_DIR" "$OUT_DIR" "$CONFIG_DIR"; do
        if [[ -e $path ]]; then paths+=("$path"); fi
    done
    tar -czPf "$backup_file" -- "${paths[@]}" || { echo 'The backup failed, so nothing was removed.' >&2; rm -f -- "$backup_file"; exit 1; }
    chmod 600 "$backup_file"
    printf 'Backup written: %s\n' "$backup_file"
fi

# Read the record first: it is deleted further down, and a failure must leave it for another attempt.
mapfile -t added_packages < <(recorded package)
mapfile -t added_deps < <(recorded dep)
mapfile -t added_kernel < <(recorded kernel)
forward_before=$(awk '$1=="ip_forward_before" {print $2}' "$MARKER")
ufw_port=$(awk '$1=="ufw_port" {print $2}' "$MARKER")
ufw_iface=$(awk '$1=="ufw_iface" {print $2}' "$MARKER")

echo 'Stopping OpenVPN and NAT...'
systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
systemctl disable --now darban-nat.service >/dev/null 2>&1 || true
modprobe -r ovpn >/dev/null 2>&1 || true
try rm -f -- "$NAT_UNIT" "$SYSCTL_FILE" "$MODULES_FILE"
systemctl daemon-reload >/dev/null 2>&1 || true
# Only undone if setup is what turned it on; other software on this server may need it.
if [[ $forward_before == 0 ]]; then sysctl -q -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true; fi

# Only the rules the setup added; anything else in ufw stays.
if [[ $ufw_port =~ ^[0-9]+$ && $ufw_iface =~ ^[A-Za-z0-9_.@-]+$ ]] && command -v ufw >/dev/null; then
    ufw delete allow "$ufw_port/udp" >/dev/null 2>&1 || true
    ufw route delete allow in on tun0 out on "$ufw_iface" >/dev/null 2>&1 || true
fi

# The certificate for temporary links, if this tool requested one.
if grep -q '^certbot_cert darban$' "$MARKER" && command -v certbot >/dev/null; then
    certbot delete --non-interactive --cert-name darban >/dev/null 2>&1 || true
fi

echo 'Removing packages this setup added...'
purge_exact "${added_packages[@]}"
if (( ${#added_deps[@]} > 0 )); then
    # Only dependencies nothing else uses any more, and never another program's orphans.
    mapfile -t orphans < <(apt-get -s autoremove | awk '$1=="Remv" {print $2}' | base_names | grep -Fx -f <(printf '%s\n' "${added_deps[@]}" | base_names) || true)
    purge_exact "${orphans[@]}"
fi
if (( KERNEL )); then
    purge_exact "${added_kernel[@]}"
fi

echo 'Removing the repository, server files and CA...'
try rm -f -- "$APT_LIST" "$APT_KEY"
# Only what the setup and the tool created: another file there belongs to someone else.
try rm -f -- "$SERVER_DIR"/server.conf "$SERVER_DIR"/server.conf.darban-*backup.* "$SERVER_DIR"/ca.crt "$SERVER_DIR"/server.crt \
    "$SERVER_DIR"/server.key "$SERVER_DIR"/crl.pem "$SERVER_DIR"/tls-crypt.key "$SERVER_DIR"/.darban-*
if [[ -d $SERVER_DIR ]] && ! rmdir -- "$SERVER_DIR" 2>/dev/null; then
    KEPT_FILES=$SERVER_DIR
fi
try rm -rf -- "$OUT_DIR"
try rm -rf -- "$PKI"

if (( ${#FAILED[@]} > 0 )); then
    echo 'Some steps failed; the tool and its record were kept so this can be run again:' >&2
    printf '  %s\n' "${FAILED[@]}" >&2
    printf 'Run again after fixing the cause: sudo bash %s --yes\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$here/uninstall.sh" --yes >/dev/null || { echo 'Could not remove the tool itself; run uninstall.sh --yes.' >&2; exit 1; }
rm -rf -- "$CONFIG_DIR" "$TOOL_BACKUPS"
rm -f -- "$LOCK_FILE"

echo
echo 'OpenVPN, the CA, client profiles, NAT and this tool were removed.'
if [[ -n $backup_file ]]; then
    printf 'The backup holds the CA private key; keep it safe or delete it: %s\n' "$backup_file"
fi
if (( ${#added_kernel[@]} > 0 && ! KERNEL )); then
    printf 'The Virtual HWE kernel was kept. It is safe to leave installed.\n'
fi
if (( ${#KEPT[@]} > 0 )); then
    echo 'Kept because other software depends on them:'
    printf '  %s\n' "${KEPT[@]}"
fi
if [[ -n $KEPT_FILES ]]; then
    printf 'Kept, because this setup did not create them: the other files in %s\n' "$KEPT_FILES"
fi
echo 'Close the VPN port in your provider firewall; this tool cannot reach it.'
