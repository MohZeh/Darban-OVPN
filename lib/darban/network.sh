#!/usr/bin/env bash
# The settings of server.conf: the port, routing, DNS pushed, the VPN network, ciphers and MSS.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

port_listening() {
    # UDP socket existence plus separate systemd active check below; provider firewall must be tested externally.
    [[ -n $(ss -H -lun "sport = :$1" 2>/dev/null) ]]
}
wait_for_port() {
    local port=$1 attempt
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "$DARBAN_UNIT" && port_listening "$port"; then return 0; fi
        sleep 1
    done
    return 1
}
host_firewall_check() {
    # Read-only hint: the manager never edits host firewall rules.
    local old=$1 new=$2 status rules
    if command -v ufw >/dev/null && status=$(ufw status 2>/dev/null) && [[ $status == *'Status: active'* ]]; then
        if ! grep -Eq "^$new(/udp)?[[:space:]]" <<<"$status"; then
            warn "ufw is active and has no rule for $new/udp (ufw allow $new/udp)."
        fi
    fi
    if command -v nft >/dev/null && rules=$(nft list ruleset 2>/dev/null); then
        if grep -Eq "dport[^;]*\\b$old\\b" <<<"$rules" && ! grep -Eq "dport[^;]*\\b$new\\b" <<<"$rules"; then
            warn "Host nftables rules reference port $old but not $new; traffic to the new port may be filtered or not forwarded."
        fi
    fi
}
apply_port_change() {
    local old=$1 new=$2 backup=$3 temp
    temp=$(mktemp "$DARBAN_SERVER_DIR/.darban-serverconf.XXXXXXXX") || return 1
    darban_tmp_register "$temp"
    if ! awk -v p="$new" '$1=="port" {$0="port "p} {print}' "$DARBAN_SERVER_CONF" >"$temp"; then
        rm -f -- "$temp"
        fail 'Failed to write server.conf; the original is unchanged.'
        return 1
    fi
    apply_server_conf "$temp" "$old" "$new" "$backup"
}
apply_server_conf() {
    # Puts a prepared file in place of server.conf, restarts OpenVPN, and restores the backup if it does not
    # come back. Returns 0 = applied, 1 = the previous configuration is running again, 2 = the rollback failed.
    local temp=$1 old=$2 new=$3 backup=$4
    if ! chmod --reference="$DARBAN_SERVER_CONF" "$temp" || ! chown --reference="$DARBAN_SERVER_CONF" "$temp" ||
       ! mv -f -- "$temp" "$DARBAN_SERVER_CONF"; then
        rm -f -- "$temp"
        fail 'Failed to write server.conf; the original is unchanged.'
        return 1
    fi
    ok "server.conf updated (backup: $backup)."
    info "Restarting OpenVPN and waiting for UDP $new (up to 5 seconds)${S_ELL}"
    if ! systemctl restart "$DARBAN_UNIT" || ! wait_for_port "$new"; then
        warn "OpenVPN did not come up on UDP $new. Restoring the previous server.conf${S_ELL}"
        cp -a -- "$backup" "$DARBAN_SERVER_CONF" || { urgent "Could not restore server.conf from $backup."; return 2; }
        if systemctl restart "$DARBAN_UNIT" && wait_for_port "$old"; then
            ok "Rolled back: OpenVPN is listening on UDP $old with the previous configuration."
            audit "server.conf change failed; rolled back (UDP $old)"
        else
            urgent 'Rollback restart or the previous UDP listener FAILED. Check the OpenVPN service immediately.'
            return 2
        fi
        return 1
    fi
}
prune_port_backups() {
    # Timestamped names sort chronologically; keep only the newest few.
    local excess
    local -a backups
    mapfile -t backups < <(find "$DARBAN_SERVER_DIR" -maxdepth 1 -type f -name "${DARBAN_SERVER_CONF##*/}.darban-*backup.*" -print | sort)
    excess=$(( ${#backups[@]} - PORT_BACKUPS_KEPT ))
    (( excess > 0 )) || return 0
    rm -f -- "${backups[@]:0:excess}"
}
change_port() {
    local old new backup rc=0
    old=$(server_port) || { warn 'Expected exactly one port directive in server.conf.'; return 1; }
    server_proto_ok || { warn 'Only udp4 OpenVPN servers are supported.'; return 1; }
    systemctl is-active --quiet "$DARBAN_UNIT" || { warn 'OpenVPN service is not active. Refusing to change port.'; return 1; }
    kv Current "$old/UDP"
    info 'The UDP port clients connect to. It must be open in your provider firewall, and every client profile names it, so clients need a new profile afterwards (menu 5).'
    say
    while :; do
        prompt_valid 'New UDP port, 1024-65535 (Enter = cancel): ' valid_port 'Enter a number from 1024 to 65535.' || return 0
        new=$((10#$REPLY))
        if [[ $new == "$old" ]]; then info 'Same as the current port; nothing changed.'; return 0; fi
        if port_listening "$new"; then warn "UDP $new is already used by another program. Choose another port."; continue; fi
        break
    done
    host_firewall_check "$old" "$new"
    say
    printf '%sWhat happens next:%s\n' "$C_BOLD" "$C_RESET"
    bullet 'OpenVPN restarts: all VPN users are disconnected for a few seconds'
    bullet "if UDP $new is not up within 5 seconds, the previous configuration is restored"
    bullet 'every downloaded .ovpn must be shared again (menu 5)'
    warn "Open UDP $new in your provider firewall BEFORE continuing; this tool cannot check it."
    say
    confirm_choice "Apply UDP port $new now?" 'No, keep the current port' "Apply port $new" caution "$new" || { cancelled; return 0; }
    ca_lock || return 1
    # The file may have changed during the question.
    old=$(server_port) || { warn 'Expected exactly one port directive in server.conf.'; return 1; }
    backup="$DARBAN_SERVER_CONF.darban-backup.$(date -u +%Y%m%dT%H%M%S.%N)"
    cp -a -- "$DARBAN_SERVER_CONF" "$backup" || return 1
    critical_begin
    apply_port_change "$old" "$new" "$backup" || rc=$?
    critical_end
    if (( rc == 2 )); then fail "The rollback did not finish, so the service may be down. server.conf now has: $(server_port 2>/dev/null || printf 'no single port')"; return 1; fi
    if (( rc != 0 )); then fail "The port was NOT changed."; return 1; fi
    prune_port_backups || warn 'Could not prune old server.conf port backups.'
    audit "OpenVPN port changed: $old -> $new"
    say
    ok "OpenVPN is running and listening on UDP $new."
    info 'Test from a real remote client: local checks cannot prove the provider firewall lets traffic through.'
    info 'Share profiles again (menu 5) so clients use the new port.'
}
# ---------- advanced settings ----------
conf_value() { awk -v k="$1" '$1==k {$1=""; sub(/^ /,""); v=$0} END {print v}' "$DARBAN_SERVER_CONF"; }
conf_full_tunnel() { grep -Eq '^[[:space:]]*push[[:space:]]+"redirect-gateway' "$DARBAN_SERVER_CONF"; }
conf_dns() {
    awk '$1=="push" && $2=="\"dhcp-option" && $3=="DNS" {gsub(/"/,"",$4); s = s (s == "" ? "" : " ") $4} END {print s}' "$DARBAN_SERVER_CONF"
}
conf_ready() {
    # A change restarts the service, so it needs a healthy starting point and a known port to check.
    server_port >/dev/null || { warn 'Expected exactly one port directive in server.conf.'; return 1; }
    systemctl is-active --quiet "$DARBAN_UNIT" || { warn 'OpenVPN service is not active; fix that first (Maintenance).'; return 1; }
}
show_presets() {
    # show_presets <label> <value>...: a numbered list of common values; a number typed at the next question picks
    # that value, and anything else is taken as typed.
    local i=0
    PRESETS=()
    while (( $# >= 2 )); do
        i=$((i + 1))
        PRESETS+=("$2")
        say "  $C_KEY$i$C_RESET  $1 ($2)"
        shift 2
    done
}
preset_value() {
    # preset_value <answer>: the value of a listed number, or the answer as typed.
    if [[ $1 =~ ^[1-9]$ ]] && (( $1 <= ${#PRESETS[@]} )); then printf '%s\n' "${PRESETS[$1 - 1]}"; else printf '%s\n' "$1"; fi
}
saved() {
    # saved <what> <from when>: the same last line for every setting that is saved without a restart.
    ok "Saved: $1. It applies $2."
}
restart_notice() {
    bullet 'OpenVPN restarts: connected users drop for a few seconds and reconnect by themselves'
    bullet 'if it does not come back, the previous configuration is restored'
}
conf_apply() {
    # conf_apply <description> <prepared file>: applies it with a backup, a restart and a rollback.
    local description=$1 temp=$2 port backup rc=0
    port=$(server_port) || return 1
    backup="$DARBAN_SERVER_CONF.darban-backup.$(date -u +%Y%m%dT%H%M%S.%N)"
    cp -a -- "$DARBAN_SERVER_CONF" "$backup" || return 1
    critical_begin
    apply_server_conf "$temp" "$port" "$port" "$backup" || rc=$?
    critical_end
    if (( rc == 2 )); then fail 'The rollback did not finish, so the service may be down.'; return 2; fi
    if (( rc != 0 )); then fail 'Nothing was changed.'; return 1; fi
    prune_port_backups || warn 'Could not prune old server.conf backups.'
    audit "server.conf changed: $description"
    ok "Applied: $description. OpenVPN is listening on UDP $port."
}
conf_set_directive() {
    # conf_set_directive <key> <value> <output>: one line for the key, in its old place or at the end.
    awk -v k="$1" -v v="$2" '$1==k {if (!done) print k " " v; done=1; next} {print} END {if (!done) print k " " v}' "$DARBAN_SERVER_CONF" >"$3"
}
new_conf_file() {
    # Taken before the file is read, so the change starts from the current configuration.
    ca_lock || return 1
    CONF_TEMP=$(mktemp "$DARBAN_SERVER_DIR/.darban-serverconf.XXXXXXXX") || return 1
    darban_tmp_register "$CONF_TEMP"
}
set_routing() {
    local dns item
    conf_ready || return 1
    if conf_full_tunnel && [[ $DNS_SERVER == yes ]]; then
        info 'In a split tunnel clients keep their own DNS. Turn DNS on this server off first (Settings > 8 > 1).'
        return 0
    fi
    if conf_full_tunnel; then
        kv Current 'full tunnel: all client IPv4 traffic goes through the VPN'
        info 'Full tunnel is what most people want from a VPN: their whole internet goes through this server. A split tunnel only reaches the VPN network itself.'
        say
        restart_notice
        bullet 'clients keep their own internet path and DNS'
        say
        confirm_choice 'Switch to split tunnel?' 'No, keep the full tunnel' 'Switch to split tunnel' caution split || { cancelled; return 0; }
        new_conf_file || return 1
        awk '!($1=="push" && ($2=="\"redirect-gateway" || ($2=="\"dhcp-option" && $3=="DNS")))' "$DARBAN_SERVER_CONF" >"$CONF_TEMP"
        conf_apply 'split tunnel' "$CONF_TEMP"
        return
    fi
    kv Current 'split tunnel: only traffic for the VPN network'
    info 'A split tunnel only reaches the VPN network itself. Full tunnel is what most people want from a VPN: their whole internet goes through this server.'
    say
    restart_notice
    bullet "clients send all IPv4 traffic through this server; DNS: $DEFAULT_CLIENT_DNS unless already set"
    warn 'The server must do NAT for the VPN network, or clients lose their internet.'
    say
    confirm_choice 'Switch to full tunnel?' 'No, keep the split tunnel' 'Switch to full tunnel' caution full || { cancelled; return 0; }
    dns=$(conf_dns)
    new_conf_file || return 1
    cat -- "$DARBAN_SERVER_CONF" >"$CONF_TEMP"
    printf 'push "redirect-gateway def1 bypass-dhcp"\n' >>"$CONF_TEMP"
    if [[ -z $dns ]]; then
        for item in $DEFAULT_CLIENT_DNS; do printf 'push "dhcp-option DNS %s"\n' "$item" >>"$CONF_TEMP"; done
    fi
    conf_apply 'full tunnel' "$CONF_TEMP"
}
set_dns() {
    local item current DNS_LIST=''
    if [[ $DNS_SERVER == yes ]]; then
        info 'DNS on this server is on (Settings > 8): clients ask this server, and what is set here is the DNS it asks.'
        say
        set_dns_upstream
        return
    fi
    conf_ready || return 1
    if ! conf_full_tunnel; then
        info 'In a split tunnel, clients keep their own DNS. Switch to the full tunnel first (item 1).'
        return 0
    fi
    current=$(conf_dns)
    kv Current "${current:-none pushed}"
    info 'The DNS servers clients use for names while connected. Any of these works; the last two also block some sites.'
    # Google passes the first three parts of the address that asks, here this server's, on to each site's DNS
    # (EDNS Client Subnet). Cloudflare and Quad9 on these addresses do not.
    show_presets 'Cloudflare' '1.1.1.1 1.0.0.1' "Google, tells each site's DNS part of this server's address" '8.8.8.8 8.8.4.4' \
        'Quad9, blocks known malicious sites' '9.9.9.9 149.112.112.112' 'AdGuard, blocks ads and trackers' '94.140.14.14 94.140.15.15'
    say
    prompt_valid "Choose 1-${#PRESETS[@]}, or type one or two IPv4 addresses (Enter = cancel): " valid_dns_choice 'Enter a number from the list, or one or two IPv4 addresses, such as 1.1.1.1 9.9.9.9.' || return 0
    if [[ $DNS_LIST == "$current" ]]; then info 'Same as the current DNS; nothing changed.'; return 0; fi
    say
    restart_notice
    say
    confirm_choice "Use $DNS_LIST for clients?" 'No, keep the current DNS' 'Apply and restart OpenVPN' caution "$DNS_LIST" || { cancelled; return 0; }
    new_conf_file || return 1
    awk '!($1=="push" && $2=="\"dhcp-option" && $3=="DNS")' "$DARBAN_SERVER_CONF" >"$CONF_TEMP"
    for item in $DNS_LIST; do printf 'push "dhcp-option DNS %s"\n' "$item" >>"$CONF_TEMP"; done
    conf_apply "DNS $DNS_LIST" "$CONF_TEMP"
}
valid_dns_choice() { valid_dns "$(preset_value "$1")"; }
free_vpn_network() {
    # free_vpn_network <current>: the first private /24 from 10.8.0.0 up that no route uses.
    local n candidate
    for n in $(seq 8 250); do
        candidate=10.$n.0.0
        [[ $candidate != "$1" ]] || continue
        if ! subnet_conflict "$candidate" >/dev/null; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}
set_vpn_network() {
    local current mask candidate clash nat=$CONFIG_DIR/nat.nft nat_saved rc=0
    conf_ready || return 1
    read -r current mask < <(awk '$1=="server" {print $2, $3; exit}' "$DARBAN_SERVER_CONF") || true
    if ! valid_ipv4 "${current:-}" || [[ ${mask:-} != 255.255.255.0 ]]; then
        warn "This option works with a single 'server A.B.C.0 255.255.255.0' line in server.conf; this server has another layout."
        return 1
    fi
    if [[ ! -f $nat ]]; then
        warn "NAT on this server was not set up by this tool, so it cannot follow a new network. Change server.conf and NAT together by hand."
        return 1
    fi
    kv Current "$current/24"
    info 'The private addresses clients get inside the VPN. Change it only when it clashes with a network your clients use at home or at work.'
    if candidate=$(free_vpn_network "$current"); then info "A free one on this server: $candidate"; fi
    say
    prompt_valid 'New VPN network, a private /24 ending in .0 (Enter = cancel): ' valid_subnet 'Enter a private network ending in .0, such as 10.9.0.0.' || return 0
    candidate=$REPLY
    if [[ $candidate == "$current" ]]; then info 'Same as the current network; nothing changed.'; return 0; fi
    if clash=$(subnet_conflict "$candidate"); then warn "$candidate/24 overlaps the existing route $clash. Nothing changed."; return 1; fi
    say
    restart_notice
    bullet 'clients get new VPN addresses when they reconnect; their .ovpn files stay valid'
    if grep -Eq '^[[:space:]]*(client-config-dir|ifconfig-pool-persist)[[:space:]]' "$DARBAN_SERVER_CONF"; then
        warn 'Fixed client addresses (client-config-dir, ifconfig-pool-persist) are not updated. Check them afterwards.'
    fi
    say
    confirm_choice "Move the VPN to $candidate/24?" 'No, keep the current network' 'Apply and restart OpenVPN' caution "$candidate" || { cancelled; return 0; }
    ca_lock || return 1
    # Everything is prepared before anything changes. Then NAT and server.conf change together, or not at all,
    # and Ctrl+C cannot stop it in between.
    new_conf_file || return 1
    conf_set_directive server "$candidate 255.255.255.0" "$CONF_TEMP" || { fail 'Could not prepare server.conf. Nothing was changed.'; return 1; }
    if [[ $DNS_SERVER == yes ]]; then
        sed -i "s#^push \"dhcp-option DNS ${current%.0}\.1\"\$#push \"dhcp-option DNS ${candidate%.0}.1\"#" "$CONF_TEMP" || return 1
    fi
    nat_saved=$(mktemp) || return 1
    darban_tmp_register "$nat_saved"
    cp -- "$nat" "$nat_saved" || return 1
    critical_begin
    # nft loads a whole file in one transaction, so a refused file leaves the running rules as they were.
    if ! sed -i -e "s#$current/24#$candidate/24#g" -e "s#dnat to ${current%.0}\.1\$#dnat to ${candidate%.0}.1#" -e "s#!= ${current%.0}\.1 #!= ${candidate%.0}.1 #" "$nat" \
        || ! nft -f "$nat"; then
        cp -- "$nat_saved" "$nat" || true
        critical_end
        fail 'Could not load the new NAT rule. Nothing was changed.'
        return 1
    fi
    conf_apply "VPN network $candidate/24" "$CONF_TEMP" || rc=$?
    # Unbound answers on the new address from now on; until it does, clients cannot open any name.
    if (( rc == 0 )) && [[ $DNS_SERVER == yes ]] && ! unbound_apply; then
        warn "DNS on this server still answers on the old address: $DNS_WHY. Clients cannot open names until it is fixed $S_ARROW sudo darban, then Settings > DNS on this server > 2"
    fi
    if (( rc != 0 )); then
        cp -- "$nat_saved" "$nat" || true
        nft -f "$nat" || urgent 'Could not restore the previous NAT rule. Check: nft list ruleset'
        critical_end
        return 1
    fi
    critical_end
}
valid_ciphers() {
    # AEAD ciphers only: anything else would turn DCO off.
    local item
    local -a items
    IFS=: read -r -a items <<<"$1"
    (( ${#items[@]} > 0 )) || return 1
    for item in "${items[@]}"; do
        case $item in AES-128-GCM|AES-256-GCM|CHACHA20-POLY1305) ;; *) return 1 ;; esac
    done
}
set_ciphers() {
    local current
    conf_ready || return 1
    current=$(conf_value data-ciphers)
    kv Current "${current:-OpenVPN default}"
    info 'How the VPN traffic is encrypted. All of these are strong; most servers keep the first. Other names would turn off DCO, the fast kernel path.'
    show_presets 'AES first, then CHACHA20' 'AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305' \
        'CHACHA20 first, faster on phones without AES hardware' 'CHACHA20-POLY1305:AES-256-GCM:AES-128-GCM' \
        'AES-256-GCM only' 'AES-256-GCM'
    say
    prompt_valid "Choose 1-${#PRESETS[@]}, or type the names separated by colons (Enter = cancel): " valid_ciphers_choice 'Enter a number from the list, or only AES-256-GCM, AES-128-GCM and CHACHA20-POLY1305, separated by colons.' || return 0
    local value
    value=$(preset_value "$REPLY")
    if [[ $value == "$current" ]]; then info 'Same as the current list; nothing changed.'; return 0; fi
    say
    restart_notice
    warn 'Clients whose .ovpn has no cipher in common with the new list cannot connect until shared again (menu 5).'
    say
    confirm_choice "Use $value?" 'No, keep the current ciphers' 'Apply and restart OpenVPN' caution "$value" || { cancelled; return 0; }
    new_conf_file || return 1
    conf_set_directive data-ciphers "$value" "$CONF_TEMP"
    conf_apply "data ciphers $value" "$CONF_TEMP"
}
valid_ciphers_choice() { valid_ciphers "$(preset_value "$1")"; }
valid_keepalive() {
    local interval timeout extra
    read -r interval timeout extra <<<"$1"
    [[ -z $extra && $interval =~ ^[0-9]{1,3}$ && $timeout =~ ^[0-9]{1,4}$ ]] || return 1
    (( 10#$interval >= 1 && 10#$timeout >= 2 * 10#$interval ))
}
set_keepalive() {
    local value
    conf_ready || return 1
    kv Current "$(conf_value keepalive)"
    info 'How often the server checks that a client is still there, and when it gives up: two numbers in seconds.'
    show_presets 'Normal' '10 60' 'Mobile networks: fewer checks, more patience' '20 120' 'Notice a lost client sooner' '5 30'
    say
    prompt_valid "Choose 1-${#PRESETS[@]}, or type two numbers such as 10 60 (Enter = cancel): " valid_keepalive_choice 'Enter a number from the list, or two numbers such as 10 60; the second at least twice the first.' || return 0
    value=$(preset_value "$REPLY" | awk '{print $1, $2}')
    say
    restart_notice
    say
    confirm_choice "Use keepalive $value?" 'No, keep the current value' 'Apply and restart OpenVPN' caution "$value" || { cancelled; return 0; }
    new_conf_file || return 1
    conf_set_directive keepalive "$value" "$CONF_TEMP"
    conf_apply "keepalive $value" "$CONF_TEMP"
}
valid_keepalive_choice() { valid_keepalive "$(preset_value "$1")"; }
valid_verb() { [[ $1 =~ ^[0-9]$ ]] && (( $1 <= 6 )); }
set_verb() {
    local value
    conf_ready || return 1
    kv Current "$(conf_value verb)"
    info 'How much OpenVPN writes to its log: 0 to 2 quiet, 3 normal (the default), 4 to 6 for troubleshooting only, since they can log private details. Go back to 3 afterwards.'
    say
    prompt_valid 'New log detail, 0 to 6 (Enter = cancel): ' valid_verb 'Enter a number from 0 to 6.' || return 0
    value=$REPLY
    say
    restart_notice
    say
    confirm_choice "Use log detail $value?" 'No, keep the current value' 'Apply and restart OpenVPN' caution "$value" || { cancelled; return 0; }
    new_conf_file || return 1
    conf_set_directive verb "$value" "$CONF_TEMP"
    conf_apply "log detail $value" "$CONF_TEMP"
}
mss_label() { if [[ -z $TCP_MSS ]]; then printf '%s, the default' "$DARBAN_MSS_DEFAULT"; else printf '%s' "$TCP_MSS"; fi; }
valid_mss_answer() { [[ $1 == 0 ]] || darban_valid_mss "$1"; }
mss_apply() {
    # mss_apply <value, or empty for the default>: NAT written with that TCP MSS, checked by nft, the setting saved,
    # and the rules loaded in one transaction. When anything fails, the rules, the file and the setting stay as they
    # were. Needs the lock.
    local nat=$CONFIG_DIR/nat.nft net iface nat_new nat_old old=$TCP_MSS
    if [[ ! -f $nat ]]; then
        fail 'NAT on this server was not set up by this tool, so it has no TCP MSS rule to change. Nothing was changed.'
        return 1
    fi
    net=$(darban_conf_net)
    iface=$(darban_nat_iface "$nat" 2>/dev/null) || iface=''
    if ! valid_ipv4 "${net:-}" || [[ ! $iface =~ ^[A-Za-z0-9_.@-]+$ ]]; then
        fail 'server.conf has no single /24 VPN network, or NAT names no outgoing interface. Nothing was changed.'
        return 1
    fi
    nat_new=$(mktemp "$CONFIG_DIR/.nat.XXXXXXXX") || return 1
    darban_tmp_register "$nat_new"
    nat_old=$(mktemp) || return 1
    darban_tmp_register "$nat_old"
    DARBAN_MSS=${1:-$DARBAN_MSS_DEFAULT} darban_nat_rules "$net" "$iface" >"$nat_new" && chmod 600 "$nat_new" || return 1
    if ! nft -c -f "$nat_new" >/dev/null 2>&1; then fail 'nft refused the new rules. Nothing was changed.'; return 1; fi
    cp -a -- "$nat" "$nat_old" || return 1
    TCP_MSS=$1
    if ! save_config; then TCP_MSS=$old; fail 'The setting could not be saved. Nothing was changed.'; return 1; fi
    critical_begin
    mv -f -- "$nat_new" "$nat"
    if ! nft -f "$nat" >/dev/null 2>&1; then
        cp -a -- "$nat_old" "$nat" || true
        nft -f "$nat" >/dev/null 2>&1 || urgent 'Could not load the previous NAT rules again. Check: nft list ruleset'
        TCP_MSS=$old
        save_config || urgent "Could not put TCP_MSS in $CONFIG_FILE back. Check it."
        critical_end
        fail 'The new rules did not load. Nothing was changed.'
        return 1
    fi
    critical_end
}
set_tcp_mss() {
    local value
    kv Current "$(mss_label)"
    info "The largest piece of data in one TCP packet through the VPN, so the packet fits the tunnel and is never split: many mobile and home networks drop split packets, and then websites do not open while apps still work. $DARBAN_MSS_DEFAULT suits most networks. Lower it, for example to 1280 or 1200, only when websites still do not open on some network. No restart is needed."
    say
    prompt_valid "TCP MSS, $DARBAN_MSS_MIN to $DARBAN_MSS_MAX; 0 = the default, $DARBAN_MSS_DEFAULT (Enter = cancel): " valid_mss_answer \
        "Enter a whole number from $DARBAN_MSS_MIN to $DARBAN_MSS_MAX, or 0 for the default." || return 0
    value=''
    if [[ $REPLY != 0 ]]; then value=$((10#$REPLY)); fi
    if [[ $value == "$DARBAN_MSS_DEFAULT" ]]; then value=''; fi
    if [[ $value == "$TCP_MSS" ]]; then info 'Same as the current TCP MSS; nothing changed.'; return 0; fi
    ca_lock || return 1
    mss_apply "$value" || return 1
    audit "TCP MSS changed: ${value:-default $DARBAN_MSS_DEFAULT}"
    saved "TCP MSS $(mss_label)" 'at once, to new TCP connections'
}
