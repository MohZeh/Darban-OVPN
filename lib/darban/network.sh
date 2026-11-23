#!/usr/bin/env bash
# The settings of server.conf: the protocol and ports, routing, DNS pushed, the VPN network, ciphers and MSS.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

port_listening() {
    # port_listening <udp|tcp> <port>: a socket of that protocol is bound there. The systemd check is separate, and
    # the provider firewall must be tested from outside.
    darban_port_busy "$1" "$2"
}
listeners_up() {
    # listeners_up <listeners>: every "udp N" or "tcp N" line has its socket.
    local proto port
    [[ -n $1 ]] || return 1
    while read -r proto port; do
        port_listening "$proto" "$port" || return 1
    done <<<"$1"
}
wait_for_listeners() {
    # wait_for_listeners [server.conf]: OpenVPN is active and listens on each listener of that file, each with its
    # own protocol, within 5 seconds.
    local listeners attempt
    listeners=$(server_listeners "${1:-}") || return 1
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "$DARBAN_UNIT" && listeners_up "$listeners"; then return 0; fi
        sleep 1
    done
    return 1
}
ufw_allows() {
    # ufw_allows <udp|tcp> <port> <ufw status>: an ALLOW rule for that port and protocol. A rule without a protocol
    # allows both.
    grep -Eq "^$2(/$1)?[[:space:]]+ALLOW[[:space:]]" <<<"$3"
}
host_firewall_check() {
    # host_firewall_check <old listeners> <new listeners>: read-only hints, for each port that is new. The manager
    # never edits host firewall rules.
    local old=$1 new=$2 status rules proto port
    while read -r proto port; do
        [[ -n $port ]] || continue
        grep -qx "$proto $port" <<<"$old" && continue
        if command -v ufw >/dev/null && status=$(ufw status 2>/dev/null) && [[ $status == *'Status: active'* ]]; then
            if ! ufw_allows "$proto" "$port" "$status"; then
                warn "ufw is active and has no rule for $port/$proto (ufw allow $port/$proto)."
            fi
        fi
        if command -v nft >/dev/null && rules=$(nft list ruleset 2>/dev/null) && [[ -n $rules ]] \
            && ! grep -Eq "dport[^;]*\\b$port\\b" <<<"$rules"; then
            while read -r _ old_port; do
                if [[ -n $old_port ]] && grep -Eq "dport[^;]*\\b$old_port\\b" <<<"$rules"; then
                    warn "Host nftables rules reference port $old_port but not $port; traffic to the new port may be filtered or not forwarded."
                    break
                fi
            done <<<"$old"
        fi
    done <<<"$new"
}
apply_server_conf() {
    # apply_server_conf <prepared file> <backup>: puts it in place of server.conf, restarts OpenVPN, and restores the
    # backup if it does not come back on each of its listeners. Returns 0 = applied, 1 = the previous configuration
    # is running again, 2 = the rollback failed.
    local temp=$1 backup=$2 new old
    new=$(listeners_label "$temp") || { rm -f -- "$temp"; fail 'The prepared server.conf has no listener form this tool knows; the original is unchanged.'; return 1; }
    old=$(listeners_label "$backup") || old=''
    if ! chmod --reference="$DARBAN_SERVER_CONF" "$temp" || ! chown --reference="$DARBAN_SERVER_CONF" "$temp" ||
       ! mv -f -- "$temp" "$DARBAN_SERVER_CONF"; then
        rm -f -- "$temp"
        fail 'Failed to write server.conf; the original is unchanged.'
        return 1
    fi
    ok "server.conf updated (backup: $backup)."
    info "Restarting OpenVPN and waiting for $new (up to 5 seconds)${S_ELL}"
    if ! systemctl restart "$DARBAN_UNIT" || ! wait_for_listeners; then
        warn "OpenVPN did not come up on $new. Restoring the previous server.conf${S_ELL}"
        cp -a -- "$backup" "$DARBAN_SERVER_CONF" || { urgent "Could not restore server.conf from $backup."; return 2; }
        if systemctl restart "$DARBAN_UNIT" && wait_for_listeners; then
            ok "Rolled back: OpenVPN is listening on ${old:-its previous ports} with the previous configuration."
            audit "server.conf change failed; rolled back (${old:-previous ports})"
        else
            urgent "Rollback restart or the previous listener ${old:+($old) }FAILED. Check the OpenVPN service immediately."
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

# ---------- the OpenVPN protocol: UDP only, TCP only, or both ----------
conf_port_share() {
    # conf_port_share [server.conf]: the local port of the link service when server.conf has this tool's one
    # port-share line; fails without one. Exit 2: a port-share line this tool did not write.
    awk -v dir="$PORT_SHARE_DIR" '
        $1 == "port-share" { n++; if (NF == 4 && $2 == "127.0.0.1" && $3 ~ /^[0-9][0-9]?[0-9]?[0-9]?[0-9]?$/ && $3 + 0 >= 1 && $3 + 0 <= 65535 && $4 == dir) port = $3 + 0; else bad = 1 }
        END { if (bad || n > 1) exit 2; if (!n) exit 1; print port }' "${1:-$DARBAN_SERVER_CONF}"
}
conf_listeners_file() {
    # conf_listeners_file <udp port or ''> <tcp port or ''> <port-share local port or ''> <output>: server.conf with
    # those listeners, in the form of server_listeners, where its listener lines were. explicit-exit-notify stays
    # with a UDP listener, in its place, or comes back after keepalive as the setup writes it; TCP alone has none.
    # So UDP only to TCP and back gives the same file, byte for byte.
    local udp=$1 tcp=$2 share=$3 out=$4 block een=0
    if [[ -n $udp && -n $tcp ]]; then block="local * $udp udp\\nlocal * $tcp tcp"
    elif [[ -n $udp ]]; then block="port $udp\\nproto udp4"
    else block="port $tcp\\nproto tcp4-server"; fi
    if [[ -n $udp ]]; then een=1; fi
    if [[ -n $tcp && -n $share ]]; then block+="\\nport-share 127.0.0.1 $share $PORT_SHARE_DIR"; fi
    awk -v block="$block" -v een="$een" '
        FNR == NR { if ($1 == "explicit-exit-notify") had = 1; next }
        $1 == "port" || $1 == "proto" || $1 == "local" || $1 == "port-share" { if (!done) print block; done = 1; next }
        $1 == "explicit-exit-notify" { if (een && !put) print; put = 1; next }
        { print }
        $1 == "keepalive" && een && !had && !put { print "explicit-exit-notify 1"; put = 1 }
        END { if (!done) print block; if (een && !put) print "explicit-exit-notify 1" }' "$DARBAN_SERVER_CONF" "$DARBAN_SERVER_CONF" >"$out"
}
tcp_port_problem() {
    # tcp_port_problem <port> <current OpenVPN TCP port or ''>: why it cannot be the OpenVPN TCP port; nothing when
    # it can. From 1024 to 65535, or 443; never the link port; free on TCP, unless OpenVPN itself holds it.
    local port=$1 current=${2:-}
    if ! { valid_port "$port" || [[ $port == 443 ]]; }; then printf 'range\n'; return 0; fi
    port=$((10#$port))
    if [[ -n $LINK_PORT && $port == "$LINK_PORT" ]]; then printf 'link\n'; return 0; fi
    if [[ $port != "$current" ]] && darban_port_busy tcp "$port"; then printf 'busy\n'; fi
}
ask_openvpn_port() {
    # ask_openvpn_port <udp|tcp> <other OpenVPN port or ''> <current port of this protocol or ''>: sets PICKED_PORT.
    # A random free port is suggested and Enter takes it; a typed one is checked. Fails when cancelled.
    local proto=$1 other=$2 current=$3 suggested name problem
    local -a avoid=()
    name=${proto^^}
    if [[ -n $other ]]; then avoid+=("$other"); fi
    if [[ -n $current ]]; then avoid+=("$current"); fi
    if [[ $proto == tcp && -n $LINK_PORT ]]; then avoid+=("$LINK_PORT"); fi
    suggested=$(darban_free_port "$proto" "${avoid[@]}")
    say "   Press Enter to use $suggested, a free port picked at random"
    if [[ $proto == tcp ]]; then
        say '   Or type another port from 1024 to 65535, or 443 where only web ports are open'
    else
        say '   Or type another port from 1024 to 65535'
    fi
    while :; do
        ask "$name port [$suggested]: " || { cancelled; return 1; }
        PICKED_PORT=${REPLY:-$suggested}
        if [[ $proto == tcp ]]; then
            problem=$(tcp_port_problem "$PICKED_PORT" "$current")
        elif ! valid_port "$PICKED_PORT"; then
            problem=range
        elif [[ $((10#$PICKED_PORT)) != "$current" ]] && darban_port_busy udp "$((10#$PICKED_PORT))"; then
            problem=busy
        else
            problem=''
        fi
        case $problem in
            range) if [[ $proto == tcp ]]; then warn "Enter a number from 1024 to 65535, or 443. Suggested: $suggested"; else warn "Enter a number from 1024 to 65535. Suggested: $suggested"; fi; continue ;;
            link) warn "TCP $((10#$PICKED_PORT)) is the link port (Settings $S_CRUMB 4). Suggested: $suggested"; continue ;;
            busy) warn "Port $((10#$PICKED_PORT)) is already in use. Suggested: $suggested"; continue ;;
        esac
        PICKED_PORT=$((10#$PICKED_PORT))
        return 0
    done
}
protocol_effect() {
    # protocol_effect <old mode> <new mode> <changed udp|tcp|''>: what happens to the profiles shared before. The
    # warning is general: which profile holds what is not read from the files. Returns 1 when every old profile, or
    # some, stop working, so the question defaults to No.
    local old=$1 new=$2 changed=$3
    if [[ $old == "$new" ]]; then
        case $new/$changed in
            both/udp) warn 'Profiles that use UDP only stop working; profiles with both connect over TCP, about 5 seconds later, until shared again (menu 5).' ;;
            both/tcp) warn 'Profiles that use TCP only stop working; profiles with both still connect over UDP. Share them again (menu 5).' ;;
            *) warn 'Every profile shared before names the old port and stops working. Every client needs its profile shared again (menu 5).' ;;
        esac
        return 1
    fi
    case $old/$new in
        udp/both) info 'Profiles shared before still connect over UDP. Share them again (menu 5) for the automatic fallback to TCP.'; return 0 ;;
        tcp/both) info 'Profiles shared before still connect over TCP. Share them again (menu 5) so they try UDP first.'; return 0 ;;
        udp/tcp) warn 'Every profile shared before uses UDP and STOPS WORKING. Every client needs its profile shared again (menu 5).' ;;
        tcp/udp) warn 'Every profile shared before uses TCP and STOPS WORKING. Every client needs its profile shared again (menu 5).' ;;
        both/udp) warn 'Profiles that use TCP only stop working; profiles with both keep working over UDP.' ;;
        both/tcp) warn 'Profiles with both connect about 5 seconds later, over TCP, and profiles that use UDP only stop working. Share them again (menu 5).' ;;
    esac
    return 1
}
protocol_label() {
    case $1 in udp) printf 'UDP only' ;; tcp) printf 'TCP only' ;; both) printf 'both, UDP first' ;; esac
}
apply_listeners() {
    # apply_listeners <description> <udp port or ''> <tcp port or ''> <port-share local port or ''>: under the lock,
    # from the current server.conf, with the backup, restart and rollback of every change.
    local description=$1 udp=$2 tcp=$3 share=$4
    new_conf_file || return 1
    conf_listeners_file "$udp" "$tcp" "$share" "$CONF_TEMP" || { fail 'Could not prepare server.conf. Nothing was changed.'; return 1; }
    server_listeners "$CONF_TEMP" >/dev/null || { fail 'The prepared server.conf is not in a form this tool knows. Nothing was changed.'; return 1; }
    conf_apply "$description" "$CONF_TEMP"
}
set_protocol() {
    # Settings > 2: UDP only, TCP only, or both; or a port of one of them.
    local mode udp tcp share=0 rc
    conf_ready || return 1
    mode=$(server_mode) || return 1
    udp=$(listener_port udp) || udp=''
    tcp=$(listener_port tcp) || tcp=''
    conf_port_share >/dev/null 2>&1 && share=1
    kv Current "$(listeners_label)"
    info 'How clients reach OpenVPN. UDP is faster, and is the default. TCP is for networks that block UDP; it does not hide the VPN. TCP inside TCP is slower, so with both, clients try UDP first.'
    say
    menu_item 1 "UDP only (recommended)"
    menu_item 2 'TCP only'
    menu_item 3 'Both: UDP first, TCP when UDP is blocked'
    menu_item 4 'Change a port'
    if [[ -n $tcp ]]; then menu_item 5 "$(printf '%-24s %s' 'Share the TCP port' "$(on_off "$([[ $share == 1 ]] && echo yes || echo no)") (link page on TCP $tcp)")"; fi
    say
    ask 'Choose (Enter = cancel): ' || { cancelled; return 0; }
    case $REPLY in
        '') cancelled; return 0 ;;
        1) protocol_switch "$mode" udp "$udp" "$tcp" ;;
        2) protocol_switch "$mode" tcp "$udp" "$tcp" ;;
        3) protocol_switch "$mode" both "$udp" "$tcp" ;;
        4) protocol_port "$mode" "$udp" "$tcp" ;;
        5) if [[ -n $tcp ]]; then set_port_share "$udp" "$tcp"; else warn "Unknown option \"$REPLY\"."; return 1; fi ;;
        *) warn "Unknown option \"$REPLY\"."; return 1 ;;
    esac
    rc=$?
    return "$rc"
}
protocol_switch() {
    # protocol_switch <current mode> <new mode> <udp port or ''> <tcp port or ''>
    local old=$1 new=$2 udp=$3 tcp=$4 share='' had_share='' description version
    if [[ $old == "$new" ]]; then info "OpenVPN already listens on $(protocol_label "$new"); nothing changed."; return 0; fi
    if [[ $new == both ]] && ! openvpn_at_least "$OPENVPN_BOTH_MIN"; then
        version=$(openvpn_version) || version=''
        fail "Both needs OpenVPN $OPENVPN_BOTH_MIN or newer; this server has ${version:-an unknown version}. Update it first: $(cmd sudo apt update) then $(cmd sudo apt install --only-upgrade openvpn)"
        return 1
    fi
    had_share=$(conf_port_share 2>/dev/null) || had_share=''
    say
    if [[ $new != tcp && -z $udp ]]; then
        printf '%sThe UDP port:%s\n' "$C_BOLD" "$C_RESET" || true
        ask_openvpn_port udp "$tcp" '' || return 0
        udp=$PICKED_PORT
    fi
    if [[ $new != udp && -z $tcp ]]; then
        printf '%sThe TCP port:%s\n' "$C_BOLD" "$C_RESET" || true
        ask_openvpn_port tcp "$udp" '' || return 0
        tcp=$PICKED_PORT
    fi
    if [[ $new == udp ]]; then tcp=''; fi
    if [[ $new == tcp ]]; then udp=''; fi
    # port-share stays only while TCP stays.
    if [[ -n $tcp ]]; then share=$had_share; fi
    if [[ -n $had_share && -z $tcp ]]; then info "Sharing the TCP port with the link page ends with TCP: links go back to their own port (Settings $S_CRUMB 4)."; fi
    protocol_confirm "$old" "$new" "$udp" "$tcp" '' || return 0
    description="OpenVPN protocol $(protocol_label "$new"): $(listeners_text "$udp" "$tcp")"
    ca_lock || return 1
    apply_listeners "$description" "$udp" "$tcp" "$share" || return 1
    if [[ -n $had_share && -z $tcp ]]; then port_share_service_off; fi
    protocol_done
}
protocol_port() {
    # protocol_port <mode> <udp port or ''> <tcp port or ''>: a new port for one of the listeners.
    local mode=$1 udp=$2 tcp=$3 which share=''
    case $mode in
        udp) which=udp ;;
        tcp) which=tcp ;;
        both)
            say
            menu_item 1 "UDP $udp"
            menu_item 2 "TCP $tcp"
            ask 'Which port? (Enter = cancel): ' || { cancelled; return 0; }
            case $REPLY in 1) which=udp ;; 2) which=tcp ;; '') cancelled; return 0 ;; *) warn "Unknown option \"$REPLY\"."; return 1 ;; esac ;;
    esac
    say
    if [[ $which == udp ]]; then
        kv Current "UDP $udp"
        ask_openvpn_port udp "$tcp" "$udp" || return 0
        if [[ $PICKED_PORT == "$udp" ]]; then info 'Same as the current port; nothing changed.'; return 0; fi
        udp=$PICKED_PORT
    else
        kv Current "TCP $tcp"
        ask_openvpn_port tcp "$udp" "$tcp" || return 0
        if [[ $PICKED_PORT == "$tcp" ]]; then info 'Same as the current port; nothing changed.'; return 0; fi
        tcp=$PICKED_PORT
    fi
    if [[ -n $tcp ]]; then share=$(conf_port_share 2>/dev/null) || share=''; fi
    protocol_confirm "$mode" "$mode" "$udp" "$tcp" "$which" || return 0
    ca_lock || return 1
    apply_listeners "OpenVPN port: $(listeners_text "$udp" "$tcp")" "$udp" "$tcp" "$share" || return 1
    protocol_done
}
listeners_text() {
    # listeners_text <udp port or ''> <tcp port or ''>: as listeners_label says them.
    if [[ -n $1 && -n $2 ]]; then printf 'UDP %s + TCP %s' "$1" "$2"
    elif [[ -n $1 ]]; then printf 'UDP %s' "$1"
    else printf 'TCP %s' "$2"; fi
}
protocol_confirm() {
    # protocol_confirm <old mode> <new mode> <udp port or ''> <tcp port or ''> <changed udp|tcp|''>: what happens,
    # the port to open, and the question. Fails when not confirmed.
    local old=$1 new=$2 udp=$3 tcp=$4 changed=$5 target listeners='' proto port
    if [[ -n $udp ]]; then listeners+="udp $udp"$'\n'; fi
    if [[ -n $tcp ]]; then listeners+="tcp $tcp"$'\n'; fi
    host_firewall_check "$(server_listeners)" "$listeners"
    say
    printf '%sWhat happens next:%s\n' "$C_BOLD" "$C_RESET" || true
    bullet "OpenVPN listens on $(listeners_text "$udp" "$tcp")"
    bullet 'OpenVPN restarts: all VPN users are disconnected for a few seconds'
    bullet 'if a port is not up within 5 seconds, the previous configuration is restored'
    protocol_effect "$old" "$new" "$changed" || true
    while read -r proto port; do
        [[ -n $port ]] || continue
        if ! grep -qx "$proto $port" <<<"$(server_listeners)"; then
            warn "Open ${proto^^} $port in your provider firewall BEFORE continuing; this tool cannot check it."
        fi
    done <<<"$listeners"
    say
    target=$(listeners_text "$udp" "$tcp")
    # The safe answer is the default: No.
    confirm_choice "Apply $target now?" 'No, keep the current setting' "Apply $target" caution || { cancelled; return 1; }
}
protocol_done() {
    say
    ok "OpenVPN is running and listening on $(listeners_label)."
    info 'Test from a real remote client: local checks cannot prove the provider firewall lets traffic through.'
    info 'Share profiles again (menu 5) so clients use the new setting.'
}
# ---------- advanced settings ----------
conf_value() { awk -v k="$1" '$1==k {$1=""; sub(/^ /,""); v=$0} END {print v}' "$DARBAN_SERVER_CONF"; }
conf_full_tunnel() { grep -Eq '^[[:space:]]*push[[:space:]]+"redirect-gateway' "$DARBAN_SERVER_CONF"; }
conf_dns() {
    awk '$1=="push" && $2=="\"dhcp-option" && $3=="DNS" {gsub(/"/,"",$4); s = s (s == "" ? "" : " ") $4} END {print s}' "$DARBAN_SERVER_CONF"
}
conf_ready() {
    # A change restarts the service, so it needs a healthy starting point and known listeners to check.
    server_listeners >/dev/null || { warn "server.conf has no listener form this tool knows: one 'port' with 'proto udp4' or 'proto tcp4-server', or the two 'local' lines of both."; return 1; }
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
    local description=$1 temp=$2 backup rc=0
    server_listeners >/dev/null || return 1
    backup="$DARBAN_SERVER_CONF.darban-backup.$(date -u +%Y%m%dT%H%M%S.%N)"
    cp -a -- "$DARBAN_SERVER_CONF" "$backup" || return 1
    critical_begin
    apply_server_conf "$temp" "$backup" || rc=$?
    critical_end
    if (( rc == 2 )); then fail 'The rollback did not finish, so the service may be down.'; return 2; fi
    if (( rc != 0 )); then fail 'Nothing was changed.'; return 1; fi
    prune_port_backups || warn 'Could not prune old server.conf backups.'
    audit "server.conf changed: $description"
    ok "Applied: $description. OpenVPN is listening on $(listeners_label)."
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
