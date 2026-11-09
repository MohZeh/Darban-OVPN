#!/usr/bin/env bash
# Prepares a fresh Ubuntu 24.04 or 26.04 VPS: current OpenVPN from the OpenVPN project's stable repository, the
# Virtual HWE kernel only if the running kernel lacks the ovpn module (no DKMS or headers), a new CA and server.
# Refuses to run on a server that already has an OpenVPN configuration or a PKI it did not create.
# A setup that stopped half way continues when it runs again.
#   server-setup.sh [--host NAME|IP] [--port N] [--subnet A.B.C.0] [--dns "IP [IP]"] [--split-tunnel] [--open-ufw] [--install-kernel] [--yes]
# Only the address and port are asked, and Enter accepts a usable default for each. --yes takes those defaults
# without asking, and leaves ufw alone without --open-ufw. The details of each step go to a log file.
set -Eeuo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib/common.sh
source ./lib/ui.sh

OS_RELEASE=/etc/os-release
PKI=/root/pki
EASYRSA_BIN=/usr/share/easy-rsa/easyrsa
SERVER_DIR=/etc/openvpn/server
CONFIG_DIR=/etc/darban
APT_KEY=/etc/apt/keyrings/openvpn-repo-public.asc
APT_LIST=/etc/apt/sources.list.d/openvpn-aptrepo.list
SYSCTL_FILE=/etc/sysctl.d/99-darban.conf
MODULES_FILE=/etc/modules-load.d/darban-ovpn.conf
NAT_UNIT=/etc/systemd/system/darban-nat.service
TUN_DEV=/dev/net/tun
UNIT=openvpn-server@server.service
SERVER_NAME=darban-server
DEFAULT_DNS='1.1.1.1 8.8.8.8'
MIN_BOOT_FREE_KB=150000
MARKER=$CONFIG_DIR/.server-setup-started
TOOL=/usr/local/sbin/darban
SETUP_LOG=/var/log/darban-setup.log
TOOL_LIB=/usr/local/lib/darban
OUT_DIR=/root/openvpn-clients
# Never stop for a question, and never restart services such as sshd behind the user's back.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l

die() { fail "$*"; exit 1; }
port_busy() { [[ -n $(ss -H -lun "sport = :$1" 2>/dev/null) ]]; }
run_step() {
    # run_step <text> <function>...: one line on the screen, and the details in the log.
    local name=$1 work
    shift
    STEP=$((STEP + 1))
    if (( UI_TTY )); then
        printf '%s [%d/%d] %s%s' "$S_INFO" "$STEP" "$STEP_COUNT" "$name" "$S_ELL" || true
    else
        printf '%s [%d/%d] %s%s\n' "$S_INFO" "$STEP" "$STEP_COUNT" "$name" "$S_ELL" || true
    fi
    for work; do "$work" >>"$SETUP_LOG" 2>&1 </dev/null; done
    if (( UI_TTY )); then printf '\r\e[K' || true; fi
    ok "[$STEP/$STEP_COUNT] $name"
}
public_address() {
    # This machine sits behind NAT, so only an outside service can say which address the internet sees.
    local url answer
    command -v curl >/dev/null || return 1
    for url in https://api.ipify.org https://ifconfig.me/ip; do
        answer=$(curl -4 -fsS --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 5 "$url" 2>/dev/null) || continue
        if valid_ipv4 "$answer" && ! is_private_ip "$answer"; then printf '%s\n' "$answer"; return 0; fi
    done
    return 1
}
PORT_FIRST=1024
PORT_LAST=1999
free_port() {
    # A random free UDP port from 1024 to 1999, so the server does not stand out on 1194, the usual one.
    local port tries
    for (( tries = 0; tries < 50; tries++ )); do
        port=$(shuf -n 1 -i "$PORT_FIRST-$PORT_LAST" 2>/dev/null) || port=''
        [[ $port =~ ^[0-9]+$ ]] || break
        if (( port != 1194 )) && ! port_busy "$port"; then printf '%s\n' "$port"; return 0; fi
    done
    # Without shuf, or with a crowded range: the first free one.
    for (( port = PORT_FIRST; port <= PORT_LAST; port++ )); do
        if (( port != 1194 )) && ! port_busy "$port"; then printf '%s\n' "$port"; return 0; fi
    done
    printf '%s\n' "$PORT_LAST"
}
easyrsa() { env EASYRSA_PKI="$PKI" EASYRSA_BATCH=1 "$EASYRSA_BIN" "$@" </dev/null >/dev/null; }
# A fresh VPS often runs unattended-upgrades right after boot, so wait for the dpkg lock instead of failing.
apt_run() { apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }
# apt marks an upgrade with the old version in brackets. Those packages were already here, so they are
# neither shown as new nor recorded for removal.
new_packages() { awk '$1=="Inst" && $3 !~ /^\[/ {print $2}'; }
in_container() { command -v systemd-detect-virt >/dev/null && systemd-detect-virt --container --quiet; }
on_exit() {
    local rc=$?
    # Back to the terminal, even if a step that was writing to the log called exit.
    exec 1>&3 2>&4
    ui_restore
    if (( rc != 0 && CHANGES_STARTED )); then
        say
        if [[ -s $SETUP_LOG ]]; then
            say "The last lines of $SETUP_LOG:"
            tail -n 20 "$SETUP_LOG" | sed 's/^/  /' || true
            say
        fi
        warn 'The setup did not finish.'
        say 'To try again, run the same command. It continues from where it stopped.'
        say 'To undo everything it did so far:'
        say "  sudo bash $TOOL_LIB/remove-server.sh --yes"
    fi
}
check_system() {
    local id='' version=''
    [[ $EUID == 0 ]] || die 'Run with sudo/root.'
    [[ -r $OS_RELEASE ]] || die "Cannot read $OS_RELEASE."
    id=$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' "$OS_RELEASE")
    version=$(awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2); print $2}' "$OS_RELEASE")
    case $id/$version in
        ubuntu/24.04) REPO_SUITE=noble ;;
        ubuntu/26.04) REPO_SUITE=resolute ;;
        *) die "This setup supports Ubuntu 24.04 and 26.04 only; this is ${id:-unknown} ${version:-unknown}." ;;
    esac
    KERNEL_PKG=linux-image-virtual-hwe-$version
    ARCH=$(dpkg --print-architecture)
    [[ $ARCH == amd64 || $ARCH == arm64 ]] || die "Unsupported architecture: $ARCH."
    command -v systemctl >/dev/null || die 'systemd is required.'
    # A record without the last step, and no installed tool, means an earlier run of this setup stopped half way.
    if [[ -e $MARKER && ! -e $TOOL ]] && ! grep -qx setup_complete "$MARKER"; then RESUMING=1; fi
    if [[ -e $SERVER_DIR/server.conf ]] && (( ! RESUMING )); then die "$SERVER_DIR/server.conf already exists. Nothing was changed."; fi
    if [[ -e $PKI && ! -e $MARKER ]]; then die "$PKI already exists and this setup did not create it. Nothing was changed."; fi
    # Some VPS containers do not offer a TUN device at all, and OpenVPN cannot run without one.
    modprobe tun 2>/dev/null || true
    [[ -c $TUN_DEV ]] || die "$TUN_DEV is missing. This VPS does not offer a TUN device; ask your provider to enable it."
    IFACE=$(ip -4 route show default | awk '{for (i=1; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    [[ $IFACE =~ ^[A-Za-z0-9_.@-]+$ ]] || die 'Cannot detect the network interface of the default route.'
    LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)
    valid_ipv4 "$LOCAL_IP" || LOCAL_IP=''
    if command -v timedatectl >/dev/null && [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == no ]]; then
        warn 'The system clock is not synchronized. Certificates and the CRL depend on correct time.'
    fi
    if (( RESUMING )); then
        info 'An earlier setup did not finish. It continues from where it stopped.'
        # Its own OpenVPN may hold the port, and the address and network it chose stay the defaults.
        systemctl stop "$UNIT" >/dev/null 2>&1 || true
        RESUME_HOST=$(head -n 1 "$CONFIG_DIR/domain" 2>/dev/null || true)
        RESUME_PORT=$(awk '$1=="port" {print $2; exit}' "$SERVER_DIR/server.conf" 2>/dev/null || true)
        if [[ -z $VPN_NET ]]; then VPN_NET=$(awk '$1=="server" {print $2; exit}' "$SERVER_DIR/server.conf" 2>/dev/null || true); fi
    fi
}
choose_host() {
    local default='' resolved
    if [[ -n $LOCAL_IP ]] && ! is_private_ip "$LOCAL_IP"; then default=$LOCAL_IP; fi
    if [[ -z $default ]]; then default=$(public_address || true); fi
    if [[ -n $RESUME_HOST ]]; then default=$RESUME_HOST; fi
    if [[ -z $HOST ]] && (( ASSUME_YES )); then HOST=$default; fi
    if [[ -n $HOST ]]; then
        valid_endpoint "$HOST" || die "Not a valid hostname or IPv4 address: $HOST"
    elif (( ASSUME_YES )); then
        die 'Could not detect a public IPv4 address. Give the address clients connect to: --host NAME|IP'
    else
        say
        printf '%s Step 1 of 2: Server address%s\n' "$C_BOLD" "$C_RESET"
        say ' Clients use this address to connect.'
        if [[ -n $default ]]; then
            say " Detected address: $default"
            say
            say "   Press Enter to use $default"
            say '   Or type another IP or hostname, then press Enter'
        else
            say ' The public address could not be detected.'
            say " Type this server's IP or hostname, then press Enter."
            say ' Example: 203.0.113.10 or vpn.example.com'
        fi
        say
        say ' With a domain name or a public IP, the tool can get a trusted certificate,'
        say ' so temporary links open without a browser warning.'
        say
        while :; do
            ask "Server address${default:+ [$default]}: " || die 'Cancelled; nothing was changed.'
            HOST=${REPLY:-$default}
            if [[ -n $HOST ]] && valid_endpoint "$HOST"; then break; fi
            warn 'Enter a hostname such as vpn.example.com, or an IPv4 address such as 203.0.113.10.'
        done
    fi
    HOST=${HOST,,}
    if [[ $HOST =~ ^[0-9.]+$ ]]; then
        if is_private_ip "$HOST"; then warn "$HOST is a private address; clients outside this network cannot reach it without port forwarding."; fi
        return 0
    fi
    info 'A DNS record must not be proxied (for example, Cloudflare must be DNS only): this is UDP traffic.'
    resolved=$(timeout 5 getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1 {print $1}' || true)
    if [[ -z $resolved ]]; then
        warn "$HOST does not resolve to an IPv4 address yet. Clients need that DNS record before they can connect."
    elif [[ -n $default && $resolved != "$default" ]]; then
        warn "$HOST resolves to $resolved, but this server is $default. Check the DNS record."
    else
        ok "$HOST resolves to $resolved."
    fi
}
choose_port() {
    local default=${RESUME_PORT:-$(free_port)}
    if [[ -z $PORT ]] && (( ASSUME_YES )); then PORT=$default; fi
    if [[ -n $PORT ]]; then
        valid_port "$PORT" || die "Port must be a number from 1024 to 65535: $PORT"
        PORT=$((10#$PORT))
        if [[ $PORT != "$RESUME_PORT" ]] && port_busy "$PORT"; then die "UDP $PORT is already in use."; fi
        return 0
    fi
    say
    printf '%s Step 2 of 2: VPN port (UDP)%s\n' "$C_BOLD" "$C_RESET"
    if [[ -n $RESUME_PORT ]]; then
        say ' The earlier setup chose this port.'
    else
        say " A free port was picked at random, so this server does not stand out on 1194, the usual OpenVPN port."
    fi
    say
    say "   Press Enter to use $default"
    say '   Or type another port from 1024 to 65535, then press Enter'
    say
    while :; do
        ask "VPN port [$default]: " || die 'Cancelled; nothing was changed.'
        PORT=${REPLY:-$default}
        if ! valid_port "$PORT"; then warn "Enter a number from 1024 to 65535. Suggested: $default"; continue; fi
        PORT=$((10#$PORT))
        if [[ $PORT != "$RESUME_PORT" ]] && port_busy "$PORT"; then warn "Port $PORT is already in use. Suggested: $default"; continue; fi
        return 0
    done
}
choose_subnet() {
    # Not asked: the first free default is right almost everywhere. Settings > Advanced changes it later.
    local octet
    if [[ -n $VPN_NET ]]; then
        local clash
        valid_subnet "$VPN_NET" || die "The VPN network must be a private /24 ending in .0: $VPN_NET"
        if clash=$(subnet_conflict "$VPN_NET"); then die "$VPN_NET/24 overlaps the existing route $clash."; fi
        return 0
    fi
    for octet in {8..30}; do
        if ! subnet_conflict "10.$octet.0.0" >/dev/null; then
            VPN_NET=10.$octet.0.0
            return 0
        fi
    done
    die 'Could not find a free private network. Choose one: --subnet A.B.C.0'
}
choose_dns() {
    # Not asked either. A split tunnel keeps the client's own DNS, so nothing is pushed.
    if (( SPLIT_TUNNEL )); then return 0; fi
    valid_dns "${DNS_LIST:-$DEFAULT_DNS}" || die "DNS must be one or two IPv4 addresses: $DNS_LIST"
}
choose_firewall() {
    # A firewall that is off, or not installed, needs nothing and is not asked about.
    local status
    command -v ufw >/dev/null || return 0
    status=$(ufw status 2>/dev/null || true)
    [[ $status == *'Status: active'* ]] || return 0
    UFW_ACTIVE=1
    if (( OPEN_UFW || ASSUME_YES )); then return 0; fi
    say
    say " ufw is active here. It would block the VPN unless it allows UDP $PORT and forwarding from tun0."
    say
    if confirm_choice 'Add those two rules?' 'No, I will handle ufw myself' 'Add the two rules' caution '' 2; then
        OPEN_UFW=1
    fi
}
plan_kernel() {
    # The plan shown to the user is apt's own simulation, not a guess.
    local free
    KERNEL_INSTALL=''
    KERNEL_PLAN=''
    # A container runs on the host's kernel; installing one here would do nothing.
    if in_container; then return 0; fi
    # A kernel that already has the module needs nothing: no large download and no reboot.
    if (( ! FORCE_KERNEL )) && modinfo -k "$(uname -r)" ovpn >/dev/null 2>&1; then KERNEL_READY=1; return 0; fi
    if dpkg-query -W -f='${Status}' "$KERNEL_PKG" 2>/dev/null | grep -q 'install ok installed'; then return 0; fi
    KERNEL_PLAN=$(apt_run -s --no-install-recommends install "$KERNEL_PKG" | new_packages) ||
        die "apt cannot install $KERNEL_PKG."
    [[ -n $KERNEL_PLAN ]] || die "apt planned nothing for $KERNEL_PKG."
    if grep -Eq '^(linux-firmware|xserver|x11|libx11|libgl|libwayland|wayland|mesa|gnome|kde)' <<<"$KERNEL_PLAN"; then
        die "The kernel would pull in firmware or graphics packages; stopping. Planned: ${KERNEL_PLAN//$'\n'/ }"
    fi
    free=$(df -Pk /boot 2>/dev/null | awk 'NR==2 {print $4}' || true)
    if [[ $free =~ ^[0-9]+$ ]] && (( free < MIN_BOOT_FREE_KB )); then
        die "/boot has only $((free / 1024)) MB free, too little for a new kernel. Remove old kernels first."
    fi
    KERNEL_INSTALL=$KERNEL_PKG
}
show_plan() {
    say
    section 'What this setup will do'
    kv Address "$HOST"
    kv Port "$PORT/UDP"
    kv Network "$VPN_NET/24 through $IFACE"
    if (( SPLIT_TUNNEL )); then
        kv Routing 'split tunnel: only the VPN network'
    else
        kv Routing 'full tunnel: all client IPv4 traffic'
        kv DNS "$DNS_LIST"
    fi
    say
    bullet 'Only IPv4 goes through the VPN. A client with its own IPv6 connection still uses it directly for IPv6.'
    bullet 'adds the OpenVPN project apt repository (stable channel) and installs openvpn, easy-rsa, socat, nftables'
    if links_can_be_trusted; then bullet 'installs certbot, so temporary links can get a trusted certificate from Let'"'"'s Encrypt at once'; fi
    if in_container; then
        bullet 'this is a container, so it uses the host kernel; no kernel is installed and DCO depends on the host'
    elif (( KERNEL_READY )); then
        bullet 'the running kernel already has the ovpn module, so no kernel is installed'
    elif [[ -n $KERNEL_INSTALL ]]; then
        bullet "installs $KERNEL_PKG without recommended packages:"
        printf '      %s\n' "${KERNEL_PLAN//$'\n'/ }"
        bullet 'keeps the current kernel as a fallback; no automatic reboot'
    else
        bullet "$KERNEL_PKG is already installed"
    fi
    bullet "creates a new CA without a passphrase in $PKI, and a server certificate valid for 10 years"
    bullet "writes $SERVER_DIR/server.conf, enables IPv4 forwarding and adds NAT for the VPN only"
    if (( UFW_ACTIVE && OPEN_UFW )); then bullet "adds ufw rules for UDP $PORT and forwarding from tun0"; fi
    if (( UFW_ACTIVE && ! OPEN_UFW )); then bullet 'does not change ufw, which will block the VPN until you allow it'; fi
    info "These defaults, and more, can be changed later: darban $S_ARROW Settings $S_CRUMB Advanced."
    say
}
keep_or_claim() {
    # keep_or_claim <file>: records whether this setup created the file, or saved the one that was there.
    local file=$1 saved=$CONFIG_DIR/saved
    if grep -Eq "^apt_(added|saved) $file\$" "$MARKER"; then return 0; fi
    if [[ -e $file ]]; then
        install -d -m 700 "$saved"
        cp -a -- "$file" "$saved/${file##*/}"
        printf 'apt_saved %s\n' "$file" >>"$MARKER"
    else
        printf 'apt_added %s\n' "$file" >>"$MARKER"
    fi
}
add_repository() {
    local key
    key=$(mktemp)
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 60 -o "$key" https://swupdate.openvpn.net/repos/repo-public.gpg ||
        die 'Could not download the OpenVPN repository key.'
    grep -q 'BEGIN PGP PUBLIC KEY' "$key" || die 'The downloaded file is not a PGP public key.'
    install -d -m 755 "$(dirname -- "$APT_KEY")"
    # A file that was already here is kept aside, so a removal can put it back instead of deleting it.
    keep_or_claim "$APT_KEY"
    keep_or_claim "$APT_LIST"
    install -m 644 "$key" "$APT_KEY"
    rm -f -- "$key"
    printf 'deb [arch=%s signed-by=%s] https://build.openvpn.net/debian/openvpn/stable %s main\n' "$ARCH" "$APT_KEY" "$REPO_SUITE" >"$APT_LIST"
    chmod 644 "$APT_LIST"
}
install_packages() {
    local version pkg planned
    apt_run -qq update
    planned=$(apt_run -s --no-install-recommends install openvpn easy-rsa socat nftables | new_packages) ||
        die 'apt cannot install the OpenVPN packages.'
    for pkg in $planned; do
        case $pkg in
            openvpn|easy-rsa|socat|nftables)
                dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || printf 'package %s\n' "$pkg" >>"$MARKER" ;;
            *) printf 'dep %s\n' "$pkg" >>"$MARKER" ;;
        esac
    done
    # shellcheck disable=SC2086  # an empty KERNEL_INSTALL must add no argument
    apt_run -y -q --no-install-recommends install openvpn easy-rsa socat nftables $KERNEL_INSTALL
    version=$(openvpn --version | awk 'NR==1 {print $2}')
    case $version in
        2.[7-9]*|[3-9].*) ok "OpenVPN $version installed." ;;
        *) die "Expected OpenVPN 2.7 or newer from the OpenVPN repository, but got ${version:-nothing}." ;;
    esac
    [[ -x $EASYRSA_BIN ]] || die "Easy-RSA is not at $EASYRSA_BIN."
    # Called in a list, so nothing that fails inside it can stop the setup: certbot is only a convenience here.
    install_certbot_for_links || warn 'certbot was not installed; the first link tries again.'
}
links_can_be_trusted() { [[ $HOST != localhost ]] && ! { valid_ipv4 "$HOST" && is_private_ip "$HOST"; }; }
install_certbot_for_links() {
    # certbot now, so the first link can get a trusted certificate at once. A failure here is no reason to
    # stop the VPN: the first link tries again. An IP address needs certbot 5.3 or newer, from the snap.
    local candidate pkg planned
    links_can_be_trusted || return 0
    if valid_ipv4 "$HOST"; then
        if [[ -x /snap/bin/certbot ]]; then return 0; fi
        # awk reads to the end: leaving early would kill apt-cache with SIGPIPE, which pipefail turns into
        # a failure, and errexit into a setup that stops without a word.
        candidate=$(apt-cache policy certbot 2>/dev/null | awk '$1=="Candidate:" && v == "" {v=$2} END {print v}') || candidate=''
        candidate=${candidate#*:}
        if [[ $candidate =~ ^[0-9.]+ && $(printf '%s\n5.3\n' "${BASH_REMATCH[0]}" | sort -V | head -n 1) == 5.3 ]]; then
            :
        elif command -v snap >/dev/null; then
            if timeout 600 snap install --classic certbot; then
                printf 'snap certbot\n' >>"$MARKER"
            else
                warn 'Could not install certbot from the snap store; the first link tries again.'
            fi
            return 0
        else
            return 0
        fi
    fi
    if dpkg-query -W -f='${Status}' certbot 2>/dev/null | grep -q 'install ok installed'; then return 0; fi
    planned=$(apt_run -s --no-install-recommends install certbot | new_packages) || { warn 'apt cannot install certbot; the first link tries again.'; return 0; }
    if apt_run -y -q --no-install-recommends install certbot; then
        for pkg in $planned; do
            if [[ $pkg == certbot ]]; then printf 'package certbot\n' >>"$MARKER"; else printf 'dep %s\n' "$pkg" >>"$MARKER"; fi
        done
    else
        warn 'Could not install certbot; the first link tries again.'
    fi
}
create_pki() {
    # Nothing renews the server certificate automatically, so it gets a long life under a longer-lived CA.
    [[ -s $PKI/ca.crt ]] || {
        easyrsa init-pki
        EASYRSA_CA_EXPIRE=7300 EASYRSA_REQ_CN="Darban OpenVPN CA" easyrsa build-ca nopass
    }
    if [[ ! -s $PKI/issued/$SERVER_NAME.crt ]]; then
        # Easy-RSA refuses to start over from what an interrupted run left behind.
        rm -f -- "$PKI/reqs/$SERVER_NAME.req" "$PKI/private/$SERVER_NAME.key"
        EASYRSA_CERT_EXPIRE=3650 easyrsa build-server-full "$SERVER_NAME" nopass
    fi
    easyrsa gen-crl
    ok "CA and server certificate are ready in $PKI."
}
write_server_config() {
    local temp item
    install -d -m 755 "$SERVER_DIR"
    # The stock unit hides /root from OpenVPN, so the server reads its own copies from here.
    install -m 644 "$PKI/ca.crt" "$SERVER_DIR/ca.crt"
    install -m 644 "$PKI/issued/$SERVER_NAME.crt" "$SERVER_DIR/server.crt"
    install -m 600 "$PKI/private/$SERVER_NAME.key" "$SERVER_DIR/server.key"
    install -m 644 "$PKI/crl.pem" "$SERVER_DIR/crl.pem"
    [[ -s $SERVER_DIR/tls-crypt.key ]] || openvpn --genkey secret "$SERVER_DIR/tls-crypt.key"
    chmod 600 "$SERVER_DIR/tls-crypt.key"
    temp=$(mktemp "$SERVER_DIR/.server-conf.XXXXXXXX")
    # All data ciphers are AEAD and nothing compresses, which keeps the connection eligible for DCO.
    cat >"$temp" <<EOF
# Created by Darban OVPN server-setup.
port $PORT
proto udp4
dev tun
topology subnet
server $VPN_NET 255.255.255.0
ca ca.crt
cert server.crt
key server.key
tls-crypt tls-crypt.key
crl-verify $SERVER_DIR/crl.pem
dh none
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
keepalive 10 60
explicit-exit-notify 1
persist-key
persist-tun
user nobody
group nogroup
management /run/openvpn-server/darban.sock unix
verb 3
EOF
    if (( ! SPLIT_TUNNEL )); then
        printf 'push "redirect-gateway def1 bypass-dhcp"\n' >>"$temp"
        for item in $DNS_LIST; do printf 'push "dhcp-option DNS %s"\n' "$item" >>"$temp"; done
    fi
    chmod 644 "$temp"
    mv -f -- "$temp" "$SERVER_DIR/server.conf"
    ok "$SERVER_DIR/server.conf written."
}
write_tool_settings() {
    # The address clients connect to, and how to download profiles; an existing file is kept as is.
    local ssh_port ssh_host ssh_user
    printf '%s\n' "$HOST" >"$CONFIG_DIR/domain"
    chmod 600 "$CONFIG_DIR/domain"
    [[ ! -e $CONFIG_DIR/config ]] || return 0
    ssh_port=$( { sshd -T 2>/dev/null || true; } | awk '$1=="port" && p=="" {p=$2} END {print p}')
    ssh_host=$HOST
    if [[ -n $LOCAL_IP ]] && ! is_private_ip "$LOCAL_IP"; then ssh_host=$LOCAL_IP; fi
    # The person running this setup is the one who will download profiles.
    ssh_user=${SUDO_USER:-root}
    [[ $ssh_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || ssh_user=root
    printf 'DOWNLOAD_SSH_HOST=%s\nDOWNLOAD_SSH_PORT=%s\nDOWNLOAD_SSH_USER=%s\n' "$ssh_host" "${ssh_port:-22}" "$ssh_user" >"$CONFIG_DIR/config"
    chmod 600 "$CONFIG_DIR/config"
}
configure_network() {
    local rules
    printf 'net.ipv4.ip_forward=1\n' >"$SYSCTL_FILE"
    chmod 644 "$SYSCTL_FILE"
    sysctl -q -p "$SYSCTL_FILE"
    # One table of its own: nothing else in the host's firewall is touched.
    darban_nat_rules "$VPN_NET" "$IFACE" >"$CONFIG_DIR/nat.nft"
    chmod 600 "$CONFIG_DIR/nat.nft"
    cat >"$NAT_UNIT" <<EOF
[Unit]
Description=Darban OpenVPN NAT
After=network-pre.target
Before=$UNIT

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/sbin/nft -f $CONFIG_DIR/nat.nft
ExecStop=/usr/sbin/nft delete table ip darban

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$NAT_UNIT"
    systemctl daemon-reload
    systemctl enable --now darban-nat.service >/dev/null
    ok "IPv4 forwarding and NAT through $IFACE are on."
    if (( UFW_ACTIVE && OPEN_UFW )); then
        # A rule that was already there stays the user's. Each new one is recorded before it is added, so a
        # removal knows about it even if adding the next one fails.
        rules=$(ufw status 2>/dev/null || true)
        if ! grep -Eq "^$PORT/udp[[:space:]]" <<<"$rules"; then
            printf 'ufw_port %s\n' "$PORT" >>"$MARKER"
            ufw allow "$PORT/udp" >/dev/null
        fi
        if ! grep -Eq "on ${IFACE}[[:space:]].*ALLOW FWD.*on tun0" <<<"$rules"; then
            printf 'ufw_iface %s\n' "$IFACE" >>"$MARKER"
            ufw route allow in on tun0 out on "$IFACE" >/dev/null
        fi
        ok 'ufw now allows the VPN.'
    fi
}
start_server() {
    local attempt
    printf 'ovpn\n' >"$MODULES_FILE"
    chmod 644 "$MODULES_FILE"
    # On the old kernel this module may not exist yet; OpenVPN then runs in user space until the reboot.
    modprobe ovpn 2>/dev/null || true
    systemctl enable openvpn-server@server.service >/dev/null
    systemctl restart "$UNIT" || die "OpenVPN did not start. Check: journalctl -u $UNIT -n 50 --no-pager"
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "$UNIT" && port_busy "$PORT"; then
            ok "OpenVPN is running and listening on UDP $PORT."
            return 0
        fi
        sleep 1
    done
    die "OpenVPN is not listening on UDP $PORT. Check: journalctl -u $UNIT -n 50 --no-pager"
}
confirm_install() {
    while :; do
        say
        section 'Ready to install'
        kv Address "$HOST"
        kv Port "$PORT/UDP"
        say
        say ' Nothing is installed yet.'
        say
        choose_one 'Install this server?' 'Install now' 'Show details' 'Cancel' || return 1
        case $CHOSEN in
            1) return 0 ;;
            2) say; show_plan ;;
            *) return 1 ;;
        esac
    done
}
configure_server() {
    write_server_config
    write_tool_settings
    configure_network
}
finish() {
    say
    ok "OpenVPN is running on UDP $PORT."
    if (( UFW_ACTIVE && ! OPEN_UFW )); then
        warn "ufw is active and was not changed. It needs: ufw allow $PORT/udp, and: ufw route allow in on tun0 out on $IFACE"
    fi
}

HOST=''
PORT=''
VPN_NET=''
DNS_LIST=''
SPLIT_TUNNEL=0
OPEN_UFW=0
UFW_ACTIVE=0
ASSUME_YES=0
FORCE_KERNEL=0
KERNEL_READY=0
RESUMING=0
RESUME_HOST=''
RESUME_PORT=''
CHANGES_STARTED=0
STEP=0
STEP_COUNT=5
ARCH=''
REPO_SUITE=''
KERNEL_PKG=''
IFACE=''
LOCAL_IP=''
while (( $# )); do
    case $1 in
        --host) (( $# >= 2 )) || die '--host needs a value.'; HOST=$2; shift 2 ;;
        --port) (( $# >= 2 )) || die '--port needs a value.'; PORT=$2; shift 2 ;;
        --subnet) (( $# >= 2 )) || die '--subnet needs a value.'; VPN_NET=$2; shift 2 ;;
        --dns) (( $# >= 2 )) || die '--dns needs a value.'; DNS_LIST=$2; shift 2 ;;
        --split-tunnel) SPLIT_TUNNEL=1; shift ;;
        --open-ufw) OPEN_UFW=1; shift ;;
        --install-kernel) FORCE_KERNEL=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        *) printf 'Usage: server-setup.sh [--host NAME|IP] [--port N] [--subnet A.B.C.0] [--dns "IP [IP]"] [--split-tunnel] [--open-ufw] [--install-kernel] [--yes]\n' >&2; exit 2 ;;
    esac
done
# Kept so the end of the setup can always reach the terminal.
exec 3>&1 4>&2
trap on_exit EXIT
ui_init
check_system
choose_host
choose_port
choose_subnet
choose_dns
choose_firewall
info "Checking this server${S_ELL}"
apt_run -qq update >/dev/null
plan_kernel
if (( ASSUME_YES )); then
    say
    show_plan
elif ! confirm_install; then
    info 'Cancelled; nothing was changed.'
    exit 0
fi
install -d -m 700 "$CONFIG_DIR"
# The record remove-server.sh works from: only what this setup added is ever removed.
if [[ ! -e $MARKER ]]; then
    printf 'ip_forward_before %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)" >"$MARKER"
fi
# A profile folder that already holds files is not this setup's to delete later.
if [[ -d $OUT_DIR && -n $(ls -A -- "$OUT_DIR" 2>/dev/null) ]] && ! grep -qx out_dir_existed "$MARKER"; then
    printf 'out_dir_existed\n' >>"$MARKER"
fi
# The way back is in place before the first change, because the tool itself is installed only at the end.
install -d -m 700 "$TOOL_LIB"
install -m 700 setup/remove-server.sh setup/uninstall.sh "$TOOL_LIB/"
CHANGES_STARTED=1
# A lost SSH connection must not stop apt half way; running the same command again shows where it stands.
trap '' HUP
if [[ -n $KERNEL_INSTALL ]]; then
    # shellcheck disable=SC2086  # one line per planned package
    printf 'kernel %s\n' $KERNEL_PLAN >>"$MARKER"
fi
say
: >>"$SETUP_LOG"
chmod 600 "$SETUP_LOG"
run_step 'Preparing the system' add_repository
if [[ -n $KERNEL_INSTALL ]]; then
    run_step 'Installing OpenVPN and the kernel (a few minutes)' install_packages
else
    run_step 'Installing OpenVPN' install_packages
fi
run_step 'Creating the certificates' create_pki
run_step 'Configuring the server' configure_server
run_step 'Starting OpenVPN' start_server
printf 'setup_complete\n' >>"$MARKER"
finish
