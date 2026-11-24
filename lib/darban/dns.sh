#!/usr/bin/env bash
# DNS on this server.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- DNS on this server ----------
# Unbound answers clients on this server's VPN address and passes each question to the upstream DNS: it never asks
# the name servers of sites itself, so they see that DNS and never this server. It sends no part of an address on
# (no EDNS Client Subnet), and can reach the upstream over TLS. Clients can be made to use it: their DNS to any other
# server is sent to it. The next part, lists of blocked names, builds on this.
dns_gateway() {
    # This server's address inside the VPN: the first of its /24.
    local net
    net=$(darban_conf_net) || return 1
    valid_ipv4 "${net:-}" || return 1
    printf '%s.1\n' "${net%.0}"
}
dns_upstream() { printf '%s' "${DNS_UPSTREAM:-$DEFAULT_CLIENT_DNS}"; }
dns_tls_name() {
    # The name each known DNS proves with its certificate over TLS; an address without one cannot be checked.
    case $1 in
        1.1.1.1|1.0.0.1) printf cloudflare-dns.com ;;
        9.9.9.9|149.112.112.112) printf dns.quad9.net ;;
        8.8.8.8|8.8.4.4) printf dns.google ;;
        94.140.14.14|94.140.15.15) printf dns.adguard-dns.com ;;
        *) return 1 ;;
    esac
}
dns_tls_possible() { local item; for item in $1; do dns_tls_name "$item" >/dev/null || return 1; done; }
on_off() { if [[ $1 == yes ]]; then printf on; else printf off; fi; }
dns_server_summary() {
    if [[ $DNS_SERVER != yes ]]; then printf off; return 0; fi
    printf 'on, asks %s%s' "$(dns_upstream)" "$([[ $DNS_TLS == yes ]] && printf ' over TLS')"
}
unbound_installed() { command -v unbound-checkconf >/dev/null 2>&1; }
dns_root_data_installed() { [[ -s $DNS_ROOT_DATA ]]; }
unbound_root_key() {
    # Unbound does not start without the root key of DNSSEC, even with the check off: Ubuntu's own file names it.
    # It is taken from dns-root-data when Unbound has none yet, and Unbound keeps it up to date from then on.
    [[ -s $UNBOUND_ROOT_KEY ]] && return 0
    [[ -s $DNS_ROOT_DATA ]] || return 1
    install -d -m 755 "${UNBOUND_ROOT_KEY%/*}" && cp -- "$DNS_ROOT_DATA" "$UNBOUND_ROOT_KEY" && chmod 644 "$UNBOUND_ROOT_KEY" || return 1
    chown unbound:unbound "$UNBOUND_ROOT_KEY" 2>/dev/null || true
}
unbound_conf_text() {
    # unbound_conf_text <gateway>: the tool's own file of Unbound, from the settings in memory.
    local net=${1%.1}.0 item name
    cat <<EOF
# Written by Darban OVPN, Settings > DNS on this server. A change here is written over at the next change there.
server:
    interface: $1
    # The VPN address exists only while OpenVPN runs; Unbound may start first.
    ip-freebind: yes
    access-control: $net/24 allow
    do-ip6: no
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    # No subnetcache module: no part of a client's address, or of this server's, goes to any DNS.
EOF
    # respip applies the zone of blocked names, when there is one.
    if names_in_use && [[ -s $UNBOUND_RPZ ]]; then
        if [[ $DNS_DNSSEC == yes ]]; then printf '    module-config: "respip validator iterator"\n'; else printf '    module-config: "respip iterator"\n'; fi
    elif [[ $DNS_DNSSEC == yes ]]; then
        printf '    module-config: "validator iterator"\n'
    else
        printf '    module-config: "iterator"\n'
    fi
    if [[ $DNS_TLS == yes ]]; then printf '    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt\n'; fi
    if [[ $DNS_FORCE == yes ]]; then
        printf '    # Firefox then keeps its own DNS over HTTPS off, and asks this server.\n    local-zone: "use-application-dns.net." always_nxdomain\n'
    fi
    printf 'forward-zone:\n    name: "."\n'
    if [[ $DNS_TLS == yes ]]; then
        printf '    forward-tls-upstream: yes\n'
        for item in $(dns_upstream); do name=$(dns_tls_name "$item") || return 1; printf '    forward-addr: %s@853#%s\n' "$item" "$name"; done
    else
        for item in $(dns_upstream); do printf '    forward-addr: %s\n' "$item"; done
    fi
    if names_in_use && [[ -s $UNBOUND_RPZ ]]; then
        printf 'rpz:\n    name: "darban.rpz."\n    zonefile: "%s"\n    rpz-log: no\n' "$UNBOUND_RPZ"
    fi
}
unbound_apply() {
    # Unbound's file and its drop-in from the settings in memory, checked, then Unbound started again with them. When
    # anything fails, the file that ran stays and so does Unbound; DNS_WHY says what failed.
    local gateway new old had_old=0 out
    gateway=$(dns_gateway) || { DNS_WHY='server.conf has no single /24 VPN network'; return 1; }
    unbound_root_key || { DNS_WHY="the root key of DNSSEC, $UNBOUND_ROOT_KEY, is missing, and the package dns-root-data that has it is not installed"; return 1; }
    install -d -m 755 "$UNBOUND_DIR" "${UNBOUND_DROPIN%/*}" || { DNS_WHY="could not make $UNBOUND_DIR"; return 1; }
    new=$(mktemp "$UNBOUND_DIR/.darban.XXXXXXXX") || return 1
    darban_tmp_register "$new"
    old=$(mktemp) || return 1
    darban_tmp_register "$old"
    unbound_conf_text "$gateway" >"$new" && chmod 644 "$new" || { DNS_WHY='could not write its file'; return 1; }
    if ! unbound-checkconf "$new" >/dev/null 2>&1; then DNS_WHY='unbound-checkconf refused the new file'; return 1; fi
    printf '[Service]\n# Clients have no DNS while Unbound is down: it starts again at once.\nRestart=always\nRestartSec=2\n' >"$UNBOUND_DROPIN.new" \
        && chmod 644 "$UNBOUND_DROPIN.new" && mv -f -- "$UNBOUND_DROPIN.new" "$UNBOUND_DROPIN" || { DNS_WHY='could not write its drop-in'; return 1; }
    if [[ -f $UNBOUND_CONF ]]; then cp -a -- "$UNBOUND_CONF" "$old" && had_old=1; fi
    mv -f -- "$new" "$UNBOUND_CONF"
    # The whole configuration, with the other files of Unbound, is what it starts with.
    if ! out=$(unbound-checkconf 2>&1); then
        if (( had_old )); then cp -a -- "$old" "$UNBOUND_CONF"; else rm -f -- "$UNBOUND_CONF"; fi
        DNS_WHY="unbound-checkconf refused the whole configuration: $(safe_text "$(tail -n 1 <<<"$out")")"
        return 1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    # Ubuntu's package would make this server itself ask 127.0.0.1, where this Unbound does not answer: the server's
    # own DNS stays as it is.
    systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
    if systemctl enable unbound.service >/dev/null 2>&1 && systemctl restart unbound.service >/dev/null 2>&1 \
        && systemctl is-active --quiet unbound.service; then
        return 0
    fi
    # Its own last words say why, so the menu shows them.
    out=$(journalctl -u unbound.service -n 5 --no-pager -o cat 2>/dev/null | grep -v '^$' | tail -n 1) || out=''
    if (( had_old )); then cp -a -- "$old" "$UNBOUND_CONF"; else rm -f -- "$UNBOUND_CONF"; fi
    systemctl restart unbound.service >/dev/null 2>&1 || true
    DNS_WHY="Unbound did not start with the new file${out:+: $(safe_text "$out")}; see: journalctl -u unbound"
    return 1
}
dns_push_file() {
    # dns_push_file <addresses>: server.conf in CONF_TEMP, pushing those DNS servers instead of the ones it pushes.
    local item
    new_conf_file || return 1
    awk '!($1=="push" && $2=="\"dhcp-option" && $3=="DNS")' "$DARBAN_SERVER_CONF" >"$CONF_TEMP" || return 1
    for item in $1; do printf 'push "dhcp-option DNS %s"\n' "$item" >>"$CONF_TEMP" || return 1; done
}
dns_redirect_apply() {
    # The flag that sends clients' DNS here, then NAT written again from it. Needs the lock.
    if [[ $DNS_SERVER == yes && $DNS_FORCE == yes ]]; then
        : >"$DARBAN_DNS_REDIRECT" && chmod 600 "$DARBAN_DNS_REDIRECT" || return 1
    else
        rm -f -- "$DARBAN_DNS_REDIRECT"
    fi
    blocked_apply
}
ufw_dns_open() {
    # With ufw active, clients' DNS to this server passes only with a rule; the setup's record takes it away again.
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q '^Status: active' || return 0
    ufw status 2>/dev/null | grep -q '53 on tun0' && return 0
    ufw allow in on tun0 to any port 53 comment Darban-OVPN >/dev/null 2>&1 || { warn 'ufw did not take the rule for DNS: ufw allow in on tun0 to any port 53'; return 0; }
    record_added 'ufw_dns tun0 tagged'
}
dns_settings_commit() {
    # Unbound and the redirect from the settings in memory, then the settings saved. Needs the lock.
    unbound_apply || { fail "DNS on this server was not changed: $DNS_WHY."; return 1; }
    dns_redirect_apply || return 1
    save_config || { fail 'The setting could not be saved.'; return 1; }
}
set_dns_server() {
    local gateway installed=0 record_root=0
    conf_ready || return 1
    if [[ $DNS_SERVER == yes ]]; then
        kv Now on
        bullet "clients go back to asking $(dns_upstream) themselves; OpenVPN restarts once"
        say
        confirm_choice 'Turn DNS on this server off?' 'No, keep it on' 'Turn it off' caution || { cancelled; return 0; }
        dns_push_file "$(dns_upstream)" || return 1
        conf_apply "DNS $(dns_upstream)" "$CONF_TEMP" || return 1
        ca_lock || return 1
        DNS_SERVER=no
        dns_redirect_apply || warn 'The rules that send DNS here could not be taken away; see: sudo darban status'
        save_config || { fail 'The setting could not be saved.'; return 1; }
        rm -f -- "$UNBOUND_CONF" "$UNBOUND_DROPIN" "$UNBOUND_RPZ"
        systemctl daemon-reload >/dev/null 2>&1 || true
        # Unbound that the tool installed stops; one that was here before goes on without the tool's file.
        if grep -qx 'package unbound' "$CONFIG_DIR/.server-setup-started" 2>/dev/null || [[ -e $CONFIG_DIR/.unbound-installed ]]; then
            systemctl disable --now unbound.service >/dev/null 2>&1 || true
        else
            systemctl restart unbound.service >/dev/null 2>&1 || true
        fi
        audit 'DNS on this server turned off'
        ok "DNS on this server is off. Clients ask $(dns_upstream) again."
        return 0
    fi
    if ! conf_full_tunnel; then info 'In a split tunnel, clients keep their own DNS. Switch to the full tunnel first (Settings > Advanced > 1).'; return 0; fi
    gateway=$(dns_gateway) || { warn "This works with a single 'server A.B.C.0 255.255.255.0' line in server.conf."; return 1; }
    kv Now off
    info "Clients ask this server, at $gateway, for every name, and it asks $(dns_upstream). It never asks the name servers of sites itself, so they see that DNS and never this server."
    bullet 'this is what blocking names, the next part of this menu, will need'
    bullet 'installs Unbound, if it is not here yet'
    if [[ $DNS_FORCE == yes ]]; then bullet 'DNS that clients send to other servers comes here too (item 4)'; fi
    bullet 'while Unbound is down, clients cannot open any name: it starts again by itself, and Diagnostics watch it'
    restart_notice
    say
    confirm_choice 'Turn DNS on this server on?' 'No, keep it off' 'Turn it on' caution || { cancelled; return 0; }
    if ! unbound_installed || ! dns_root_data_installed; then
        info "Installing Unbound${S_ELL}"
        # dns-root-data holds the root key of DNSSEC: Unbound does not start without it, and only recommends it.
        if ! unbound_installed; then installed=1; fi
        if ! dns_root_data_installed; then record_root=1; fi
        if ! apt-get -o DPkg::Lock::Timeout=120 -y -q --no-install-recommends install unbound dns-root-data >/dev/null; then
            fail 'Unbound could not be installed. Nothing was changed.'
            return 1
        fi
        if (( installed )); then record_added 'package unbound'; : >"$CONFIG_DIR/.unbound-installed" || true; fi
        if (( record_root )); then record_added 'package dns-root-data'; fi
    fi
    ca_lock || return 1
    DNS_SERVER=yes
    # The blocked names chosen while it was off take effect with it.
    if names_in_use && ! names_zone_write; then warn "The blocked names are not used yet: $NAMES_WHY. Settings > DNS on this server > 9 makes them again."; fi
    if ! unbound_apply; then
        fail "Unbound did not start: $DNS_WHY. Nothing else was changed."
        if (( installed )); then systemctl disable --now unbound.service >/dev/null 2>&1 || true; fi
        return 1
    fi
    ufw_dns_open
    dns_push_file "$gateway" || return 1
    if ! conf_apply "DNS on this server, $gateway" "$CONF_TEMP"; then
        rm -f -- "$UNBOUND_CONF"
        systemctl restart unbound.service >/dev/null 2>&1 || true
        return 1
    fi
    ca_lock || return 1
    dns_redirect_apply || warn 'The rules that send DNS here did not load; see: sudo darban status'
    save_config || { fail 'The setting could not be saved.'; return 1; }
    audit "DNS on this server turned on, upstream $(dns_upstream)"
    ok "DNS on this server is on: clients ask $gateway, which asks $(dns_upstream)."
}
set_dns_upstream() {
    local DNS_LIST='' old=$DNS_UPSTREAM old_tls=$DNS_TLS
    kv Current "$(dns_upstream)"
    info 'The DNS this server asks for each name. The name servers of sites see this one, and never this server.'
    # Google passes the first three parts of the address that asks, here this server's, on to each site's DNS
    # (EDNS Client Subnet). Cloudflare and Quad9 on these addresses do not.
    show_presets 'Cloudflare' '1.1.1.1 1.0.0.1' "Google, tells each site's DNS part of this server's address" '8.8.8.8 8.8.4.4' \
        'Quad9, blocks known malicious sites' '9.9.9.9 149.112.112.112' 'AdGuard, blocks ads and trackers' '94.140.14.14 94.140.15.15'
    say
    prompt_valid "Choose 1-${#PRESETS[@]}, or type one or two IPv4 addresses (Enter = cancel): " valid_dns_choice 'Enter a number from the list, or one or two IPv4 addresses, such as 1.1.1.1 9.9.9.9.' || return 0
    if [[ $DNS_LIST == "$(dns_upstream)" ]]; then info 'Same as now; nothing changed.'; return 0; fi
    DNS_UPSTREAM=$DNS_LIST
    if [[ $DNS_TLS == yes ]] && ! dns_tls_possible "$DNS_UPSTREAM"; then
        DNS_TLS=no
        warn "TLS cannot be checked with $DNS_UPSTREAM, so DNS over TLS turns off. The four DNS of the list have it."
    fi
    if [[ $DNS_SERVER != yes ]]; then
        save_config || { fail 'The setting could not be saved.'; return 1; }
        saved "upstream DNS $DNS_UPSTREAM" 'when DNS on this server is turned on'
        return 0
    fi
    ca_lock || return 1
    if ! dns_settings_commit; then DNS_UPSTREAM=$old DNS_TLS=$old_tls; return 1; fi
    audit "DNS on this server asks $DNS_UPSTREAM"
    ok "Applied: this server asks $DNS_UPSTREAM. Nothing restarted but Unbound."
}
dns_toggle() {
    # dns_toggle <setting> <label>: one switch of DNS on this server, applied to Unbound at once when it is on.
    local name=$1 label=$2 old new
    old=${!name}
    if [[ $old == yes ]]; then new=no; else new=yes; fi
    if [[ $name == DNS_TLS && $new == yes ]] && ! dns_tls_possible "$(dns_upstream)"; then
        info "TLS cannot be checked with $(dns_upstream). Choose one of the four DNS of the list first (item 2)."
        return 0
    fi
    printf -v "$name" '%s' "$new"
    if [[ $DNS_SERVER != yes ]]; then
        save_config || { fail 'The setting could not be saved.'; return 1; }
        saved "$label $(on_off "$new")" 'when DNS on this server is turned on'
        return 0
    fi
    ca_lock || return 1
    if ! dns_settings_commit; then printf -v "$name" '%s' "$old"; return 1; fi
    audit "DNS on this server: $label $(on_off "$new")"
    ok "Applied: $label $(on_off "$new"). Nothing restarted but Unbound."
}
set_dns_tls() {
    kv Now "$(on_off "$DNS_TLS")"
    info "This server asks the upstream DNS over TLS, port 853, so the network of this server's provider cannot read or change the names it asks. It works with the four DNS of the list."
    say
    confirm_choice "Turn DNS over TLS $( [[ $DNS_TLS == yes ]] && printf off || printf on)?" 'No, keep it as it is' 'Change it' caution || { cancelled; return 0; }
    dns_toggle DNS_TLS 'DNS over TLS'
}
set_dns_force() {
    kv Now "$(on_off "$DNS_FORCE")"
    info "DNS that a client sends to any other server goes to this one, and DNS over TLS from clients is refused, so the names this server blocks hold. DNS over HTTPS cannot be told from other web traffic, and still passes; Firefox is told to keep its own off."
    say
    confirm_choice "Turn this $( [[ $DNS_FORCE == yes ]] && printf off || printf on)?" 'No, keep it as it is' 'Change it' caution || { cancelled; return 0; }
    dns_toggle DNS_FORCE 'clients use it'
}
set_dns_dnssec() {
    kv Now "$(on_off "$DNS_DNSSEC")"
    info "The answers of signed names are checked, so a forged answer is refused. Turn it off only if a name that should open does not."
    say
    confirm_choice "Turn the DNSSEC check $( [[ $DNS_DNSSEC == yes ]] && printf off || printf on)?" 'No, keep it as it is' 'Change it' caution || { cancelled; return 0; }
    dns_toggle DNS_DNSSEC 'the DNSSEC check'
}
dns_server_health() {
    # dns_server_health <VPN network>: Unbound runs with the tool's file, clients are told to ask it, and the rules
    # that send their DNS here run.
    local gateway=${1%.0}.1 pushed
    [[ $DNS_SERVER == yes ]] || return 0
    if [[ ! -f $UNBOUND_CONF ]] || ! grep -q "^    interface: $gateway\$" "$UNBOUND_CONF"; then
        check bad "DNS on this server is on, but Unbound's file does not answer on $gateway $S_ARROW sudo darban, then Settings > DNS on this server > 2, and choose the same DNS"
    elif ! systemctl is-active --quiet unbound.service 2>/dev/null; then
        check bad "DNS on this server does not run, so clients cannot open any name $S_ARROW sudo systemctl restart unbound; then: journalctl -u unbound"
    else
        check ok "DNS on this server answers on $gateway and asks $(dns_upstream)$([[ $DNS_TLS == yes ]] && printf ' over TLS')"
    fi
    pushed=$(conf_dns)
    if [[ $pushed != "$gateway" ]]; then
        check bad "DNS on this server is on, but clients are told to ask ${pushed:-nothing} $S_ARROW sudo darban, then Settings > DNS on this server > 1, off and on again"
    fi
    if [[ $DNS_FORCE == yes ]] && ! darban_live_dns_redirect_ok "$1"; then
        check warn "Clients can still use another DNS: the rules that send it here are not loaded $S_ARROW sudo systemctl restart darban-nat.service"
    fi
    names_health
}
dns_restore_check() {
    # After a restore: a server.conf that tells clients to ask a DNS on this server, which this server does not run,
    # would leave them without names. They are told to ask the upstream DNS instead, and the setting turns off.
    local net gateway upstream
    net=$(darban_conf_net) || return 0
    valid_ipv4 "${net:-}" || return 0
    gateway=${net%.0}.1
    grep -qx "push \"dhcp-option DNS $gateway\"" "$DARBAN_SERVER_CONF" 2>/dev/null || return 0
    if [[ -f $UNBOUND_CONF ]] && unbound_installed; then return 0; fi
    upstream=$(awk -F= '$1=="DNS_UPSTREAM" {v=$2} END {print v}' "$CONFIG_FILE" 2>/dev/null)
    valid_dns "${upstream:-$DEFAULT_CLIENT_DNS}" || upstream=$DEFAULT_CLIENT_DNS
    upstream=${upstream:-$DEFAULT_CLIENT_DNS}
    awk '!($1=="push" && $2=="\"dhcp-option" && $3=="DNS")' "$DARBAN_SERVER_CONF" >"$DARBAN_SERVER_CONF.dns" || return 1
    for gateway in $upstream; do printf 'push "dhcp-option DNS %s"\n' "$gateway" >>"$DARBAN_SERVER_CONF.dns" || return 1; done
    chmod 644 "$DARBAN_SERVER_CONF.dns" && mv -f -- "$DARBAN_SERVER_CONF.dns" "$DARBAN_SERVER_CONF" || return 1
    sed -i '/^DNS_SERVER=/d' "$CONFIG_FILE" 2>/dev/null || true
    rm -f -- "$DARBAN_DNS_REDIRECT"
    warn "DNS on this server was on in the backup, but this server does not run it: clients ask $upstream instead. Turn it on again in Settings > DNS on this server."
}
