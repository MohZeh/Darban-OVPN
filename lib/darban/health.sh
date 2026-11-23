#!/usr/bin/env bash
# Diagnostics.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

check() {
    # check <ok|bad|warn|info> <text>: one line of the diagnostics checklist.
    local symbol=$S_INFO color=''
    case $1 in
        ok) symbol=$S_OK color=$C_GREEN HEALTH_OK=$((HEALTH_OK + 1)) ;;
        bad) symbol=$S_BAD color=$C_RED HEALTH_BAD=$((HEALTH_BAD + 1)) ;;
        warn) symbol=$S_WARN color=$C_YELLOW HEALTH_WARN=$((HEALTH_WARN + 1)) ;;
    esac
    if [[ $1 == bad || $1 == warn ]]; then HEALTH_PROBLEMS+=("$(printf '  %s%s%s %s' "$color" "$symbol" "$C_RESET" "$(with_action "$2")")"); fi
    printf '  %s%s%s %s\n' "$color" "$symbol" "$C_RESET" "$(with_action "$2")" || true
}
group() { printf '\n %s%s%s\n' "$C_GROUP" "$1" "$C_RESET" || true; }
crl_readable_by_openvpn() {
    # OpenVPN reads the CRL at start as root, and again, after a change, as the user server.conf names. Without
    # a user it stays root, which reads anything.
    local user
    user=$(darban_conf_single user 2>/dev/null) || return 0
    [[ $user != root ]] || return 0
    runuser -u "$user" -- test -r "$DARBAN_CRL" 2>/dev/null
}
link_service_health() {
    # Only while a link is open does the service run; then its HTTPS answer is checked, not only its files.
    local port want
    if ! systemctl is-active --quiet darban-links.service 2>/dev/null; then
        check info 'No link is open, so the link service is not running'
        return 0
    fi
    port=$(awk -F= '$1 == "LINK_PORT" {print $2; exit}' "$LINK_ENV" 2>/dev/null)
    if ! cert_key_matches "$LINK_CERT" "$LINK_KEY"; then
        check bad "The link certificate and its key do not belong together, so a link may not open $S_ARROW Settings $S_CRUMB 5"
        return 0
    fi
    want=$(cert_fingerprint "$LINK_CERT")
    if [[ -n $want && $(served_link_cert_fingerprint) == "$want" ]]; then
        check ok "The link service answers over HTTPS${port:+ on TCP $port} with the link certificate"
    else
        check bad "The link service does not answer over HTTPS with the link certificate, so open links may not open $S_ARROW sudo systemctl restart darban-links.service"
    fi
}
check_expiry() {
    # check_expiry <label> <epoch>
    if (( $2 <= $(date -u +%s) )); then check bad "$1 EXPIRED on $(date -u -d "@$2" +%Y-%m-%d)"
    elif (( $(days_until "$2") <= EXPIRY_WARN_DAYS )); then check warn "$1 valid until $(describe_expiry "$2") $S_ARROW renew soon (not automated)"
    else check ok "$1 valid until $(describe_expiry "$2")"; fi
}
network_rules_health() {
    # What the kernel runs now is checked, not what a file says: a flushed chain or an old network must not pass.
    local net nat=$CONFIG_DIR/nat.nft fix reinstall live_iface route_iface mss
    if ! nft list table ip darban >/dev/null 2>&1; then
        if [[ -f $nat ]]; then
            check bad "The NAT rules of this tool are not loaded $S_ARROW sudo systemctl restart darban-nat.service"
        else
            check info 'NAT table of this tool not found; NAT may be managed elsewhere'
        fi
        return 0
    fi
    # The rules run now, but the file that loads them at boot is gone.
    if [[ ! -f $nat ]] && [[ -e /etc/systemd/system/darban-nat.service ]]; then
        check warn "The NAT rules run now, but $nat is gone, so after a reboot clients have no internet through the VPN $S_ARROW sudo bash -c 'curl -fsSL https://github.com/$DARBAN_REPO/releases/download/v$DARBAN_VERSION/get.sh | bash -s -- --version v$DARBAN_VERSION'"
    fi
    net=$(darban_conf_net)
    if ! valid_ipv4 "${net:-}"; then
        check info 'NAT table present; the VPN network in server.conf is not a single /24, so it was not compared'
        return 0
    fi
    # A file that is already right only needs loading; otherwise the installer writes it again.
    reinstall="sudo bash -c 'curl -fsSL https://github.com/$DARBAN_REPO/releases/download/v$DARBAN_VERSION/get.sh | bash -s -- --version v$DARBAN_VERSION'"
    if [[ -f $nat ]] && grep -Fq "ip saddr $net/24 ip daddr 169.254.0.0/16 drop" "$nat" && grep -Fq "ip saddr $net/24 oifname" "$nat"; then
        fix='sudo systemctl restart darban-nat.service'
    else
        fix=$reinstall
    fi
    if ! darban_live_nat_ok "$net"; then
        check bad "NAT does not match the VPN network $net/24 of server.conf, so clients cannot reach the internet through the VPN $S_ARROW $fix"
    else
        # The rule can be right for the network and still send traffic out through the wrong interface.
        live_iface=$(nft list chain ip darban postrouting 2>/dev/null | grep -F "ip saddr $net/24 oifname " | darban_nat_iface)
        route_iface=$(darban_default_iface)
        if [[ -n $live_iface ]] && ! ip link show dev "$live_iface" >/dev/null 2>&1; then
            check bad "NAT sends VPN traffic out through $(safe_text "$live_iface"), which this server no longer has, so clients cannot reach the internet through the VPN $S_ARROW $reinstall"
        elif [[ $live_iface =~ ^[A-Za-z0-9_.@-]+$ && $route_iface =~ ^[A-Za-z0-9_.@-]+$ && $live_iface != "$route_iface" ]]; then
            check warn "NAT sends VPN traffic out through $(safe_text "$live_iface"), but the default route uses $(safe_text "$route_iface"). If that is not on purpose $S_ARROW sudo sed -i 's/oifname \"$live_iface\"/oifname \"$route_iface\"/' $nat && sudo systemctl restart darban-nat.service"
        else
            check ok "NAT for the VPN network $net/24 present"
        fi
    fi
    # With client-to-client, OpenVPN passes traffic between clients itself, so it never reaches these rules.
    if awk '$1 == "client-to-client" {found = 1} END {exit !found}' "$DARBAN_SERVER_CONF" 2>/dev/null; then
        check bad "VPN clients reach each other: server.conf has client-to-client, so OpenVPN passes their traffic itself, past the firewall $S_ARROW remove that line, then: sudo systemctl restart openvpn-server@server"
    elif darban_live_isolation_ok "$net"; then
        check ok 'VPN clients are kept apart, and away from the cloud metadata service'
    else
        check bad "VPN clients may reach each other, or the cloud metadata service $S_ARROW $fix"
    fi
    mss=$(darban_mss)
    if darban_live_mss_ok "$net"; then
        check ok "TCP MSS for VPN traffic is limited to $mss in both directions"
    else
        check warn "The TCP MSS rule for VPN traffic is missing or different from the configured $mss; on some networks websites may not load $S_ARROW $reinstall"
    fi
    blocked_health "$net"
    dns_server_health "$net"
}
health() {
    local version state enabled dco port e crl_err host resolved next last value issue exports pending rows mine
    if [[ -n $SERVER_PROBLEM ]]; then
        group 'Server'
        check bad "$SERVER_PROBLEM"
        # The checks below report what they cannot read, so raw errors from missing files add nothing.
        exec 2>/dev/null
    fi
    group 'OpenVPN'
    version=$(openvpn --version 2>/dev/null | awk 'NR==1 {print $1, $2}' || true)
    if [[ -n $version ]]; then check info "$version"; else check warn 'openvpn binary not found in PATH'; fi
    state=$(systemctl is-active "$DARBAN_UNIT" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$DARBAN_UNIT" 2>/dev/null || true)
    if [[ $state == active ]]; then check ok "Service active (start at boot: ${enabled:-unknown})"; else check bad "Service ${state:-unknown} ($DARBAN_UNIT)"; fi
    if port=$(server_port); then
        if port_listening "$port"; then check ok "Listening on UDP $port"; else check bad "Nothing listening on UDP $port"; fi
    else
        check bad 'server.conf has no single numeric port directive'
    fi
    if [[ -d /sys/module/ovpn ]]; then dco=ovpn; elif [[ -d /sys/module/ovpn_dco_v2 ]]; then dco=ovpn_dco_v2; else dco=''; fi
    check info "DCO kernel module: ${dco:-not loaded}"
    if server_tls_ok; then check ok 'tls-crypt key matches what profiles embed'; else check bad "server.conf tls-crypt does not use $TLS_KEY"; fi
    if value=$(server_data_ciphers); then check info "Data ciphers: $value"; else check bad 'data-ciphers is repeated or malformed'; fi
    if mgmt_available; then check ok 'Management interface: single-client disconnect available'; else check info 'Management interface: not configured (revocation offers a full restart instead)'; fi

    group 'Certificates'
    if e=$(cert_end_epoch "$DARBAN_PKI/ca.crt"); then check_expiry 'CA certificate' "$e"; else check bad 'CA certificate unreadable'; fi
    if e=$(darban_server_cert_pem | openssl x509 -noout -enddate 2>/dev/null) && e=$(date -u -d "${e#notAfter=}" +%s); then
        check_expiry 'Server certificate' "$e"
    else
        check bad 'Server certificate unreadable'
    fi
    # Which program got the links' Let's Encrypt certificate, and how it renews.
    if value=$(link_cert_client); then check info "Link certificate from Let's Encrypt by $value; $(link_cert_renewal_text)"; fi

    group 'Revocation (CRL)'
    # What OpenVPN does with a broken CRL depends on when it breaks: gone at start, OpenVPN does not start; gone
    # while it runs, it keeps the last list it read; expired, or unreadable once it changed, every connection is
    # refused. So each of these is red, and none is called harmless.
    if ! darban_crl_configured; then
        check bad "server.conf has no single 'crl-verify $DARBAN_CRL'"
    elif [[ ! -e $DARBAN_CRL ]]; then
        check bad "The CRL file $DARBAN_CRL is missing. OpenVPN does not start without it, and a running one keeps the last list it read $S_ARROW Maintenance $S_CRUMB 2"
    elif crl_err=$(C_RED='' C_RESET='' darban_verify_crl "$DARBAN_CRL" 2>&1) && e=$(darban_crl_expiry_epoch "$DARBAN_CRL"); then
        if (( e - $(date -u +%s) < 7 * 86400 )); then
            check warn "Published CRL valid and complete, but its next update is due $(describe_expiry "$e"). Once it passes, every connection is refused $S_ARROW Maintenance $S_CRUMB 2"
        else
            check ok "Published CRL valid and complete; next update $(describe_expiry "$e")"
        fi
    else
        check bad "Published CRL problem: ${crl_err##*ERROR: } $S_ARROW Maintenance $S_CRUMB 2"
    fi
    if [[ -e $DARBAN_CRL ]] && ! crl_readable_by_openvpn; then
        check bad "OpenVPN runs as $(darban_conf_single user 2>/dev/null) and cannot read the CRL. When the file changes, every connection may be refused, or the last list it read stays in use $S_ARROW sudo chmod 644 $DARBAN_CRL"
    fi
    pending=$(revocation_pending_names 2>/dev/null | join_lines) || pending=''
    if [[ -n $pending ]]; then check bad "Revoked but NOT blocked yet: $(safe_text "$pending") $S_ARROW Maintenance $S_CRUMB 2"; fi
    rows=$(share_rows 2>/dev/null) || rows=''
    pending=$(share_names revoked "$rows" | join_lines) || pending=''
    if [[ -n $pending ]]; then check bad "Revocation unfinished, link or profile still on server: $(safe_text "$pending") $S_ARROW Maintenance $S_CRUMB 2"; fi
    pending=$(share_names unknown "$rows" | join_lines) || pending=''
    if [[ -n $pending ]]; then check warn "Link or file with a certificate this tool cannot identify: $(safe_text "$pending") $S_ARROW Links and files (menu 6)"; fi
    if systemctl is-active --quiet darban-crl.timer 2>/dev/null; then
        next=$(systemctl show -p NextElapseUSecRealtime --value darban-crl.timer 2>/dev/null || true)
        check ok "Daily renewal timer active${next:+; next run $next}"
    else
        check bad 'Daily renewal timer (darban-crl.timer) is not active'
    fi
    last=$(systemctl show -p Result --value darban-crl.service 2>/dev/null || true)
    if systemctl is-failed --quiet darban-crl.service 2>/dev/null; then
        check bad "Last renewal run FAILED $S_ARROW journalctl -u darban-crl.service"
    else
        check info "Last renewal run: ${last:-unknown}"
    fi

    group 'Network (read-only)'
    value=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)
    case $value in
        1) check ok 'IPv4 forwarding enabled' ;;
        0) check bad 'IPv4 forwarding disabled: VPN clients have no internet access' ;;
        *) check info 'IPv4 forwarding: unknown' ;;
    esac
    # ufw can be turned on long after the setup, and then it quietly blocks the VPN.
    if [[ -n ${port:-} ]] && command -v ufw >/dev/null && value=$(ufw status 2>/dev/null) && [[ $value == *'Status: active'* ]]; then
        # Only an ALLOW rule counts: a DENY rule for the same port, or tun0 named in another rule, is not one.
        if ! grep -Eq "^$port(/udp)?[[:space:]]+ALLOW[[:space:]]" <<<"$value"; then
            check bad "ufw is active and blocks UDP $port $S_ARROW sudo ufw allow $port/udp"
        elif ! grep -Eq '[[:space:]]ALLOW FWD[[:space:]].*[[:space:]]on tun0([[:space:]]|$)' <<<"$value"; then
            check bad "ufw is active and blocks forwarding from the VPN $S_ARROW sudo ufw route allow in on tun0 out on $(ip -4 route show default 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
        else
            check ok 'ufw allows the VPN'
        fi
    fi
    network_rules_health

    group 'Temporary links'
    link_service_health

    group 'Connection events'
    events_health

    group 'Backup of the CA'
    backup_health

    group 'Profiles & downloads'
    host=$(domain)
    if valid_domain "$host"; then
        resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}' || true)
        if [[ -z $resolved ]]; then
            check warn "Server address $host does not resolve to IPv4"
        elif mine=$(address_elsewhere "$host"); then
            # As after a restore from another server: profiles made now would connect to that one.
            check warn "Server address $host $S_ARROW $resolved is not this server, which is $mine $S_ARROW Settings $S_CRUMB 1, then share each client again"
        else
            check ok "Server address $host $S_ARROW $resolved"
        fi
    else
        check bad "Server address not set $S_ARROW Settings $S_CRUMB 1"
    fi
    if [[ -n $DOWNLOAD_SSH_HOST ]]; then check ok "Download endpoint $DOWNLOAD_SSH_USER@$DOWNLOAD_SSH_HOST:$DOWNLOAD_SSH_PORT"; fi
    home_copy_health
    for issue in "${CONFIG_ISSUES[@]}"; do check warn "$issue"; done
    exports=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.ovpn' 2>/dev/null | wc -l)
    if (( exports > 0 )); then
        check info "$exports profile(s) kept on the server; each is deleted when its time is up or its client connects $S_ARROW menu 6"
        # Without the timer, a file whose time is up waits for the five-minute check.
        if [[ -e $UNIT_DIR/darban-expire.service ]] && compgen -G "$OUT_DIR/*.share" >/dev/null \
            && ! systemctl is-active --quiet darban-expire.timer 2>/dev/null; then
            check warn "The timer that deletes a kept file at its time is not set, so the five-minute check deletes it, up to five minutes late $S_ARROW sudo systemctl start darban-sweep.service"
        fi
    else
        check ok 'No profiles left on the server'
    fi
    # The exit status tells a script or a monitor the same thing the checklist tells a person.
    (( HEALTH_BAD == 0 ))
}
health_view() {
    # Diagnostics in the menu: one line that says whether all is well, then only what needs attention, and the
    # whole checklist on request. A script and "darban status" get the whole checklist.
    local full rc=0 line
    if (( ! UI_TTY )); then health; return; fi
    full=$(mktemp) || { health; return; }
    darban_tmp_register "$full"
    HEALTH_BAD=0 HEALTH_WARN=0 HEALTH_OK=0 HEALTH_PROBLEMS=()
    health >"$full" 2>&1 || rc=$?
    if (( HEALTH_BAD == 0 && HEALTH_WARN == 0 )); then
        ok "All $HEALTH_OK checks passed."
    else
        if (( HEALTH_BAD > 0 )); then
            fail "$HEALTH_BAD problem(s)$( (( HEALTH_WARN > 0 )) && printf ' and %s warning(s)' "$HEALTH_WARN"), out of $(( HEALTH_OK + HEALTH_BAD + HEALTH_WARN )) checks:"
        else
            warn "$HEALTH_WARN warning(s), out of $(( HEALTH_OK + HEALTH_WARN )) checks:"
        fi
        for line in "${HEALTH_PROBLEMS[@]}"; do printf '%s\n' "$line"; done
    fi
    say
    if choose_one 'See every check?' 'No, back to the menu' 'Show all checks' && (( CHOSEN == 2 )); then
        cat -- "$full"
    fi
    rm -f -- "$full"
    return "$rc"
}
