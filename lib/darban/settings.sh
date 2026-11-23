#!/usr/bin/env bash
# The settings of this tool: the server address, the download access, client days and links.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- actions ----------
set_domain() {
    local old value tmp resolved
    old=$(domain)
    kv Current "${old:-not set}"
    say
    info 'Only new or shared-again .ovpn files use this address.'
    info 'Use a DNS-only record (no Cloudflare orange-cloud proxy) for this UDP service.'
    say
    prompt_valid 'New hostname or IP, e.g. vpn.example.com (Enter = cancel): ' valid_endpoint \
        'Enter a hostname such as vpn.example.com, or an IPv4 address such as 203.0.113.10.' || return 0
    value=${REPLY,,}
    [[ $value != "$old" ]] || { info 'Same as the current address; nothing changed.'; return 0; }
    if command -v getent >/dev/null; then
        resolved=$(getent ahostsv4 "$value" 2>/dev/null | awk 'NR==1 {print $1}' || true)
        if [[ -z $resolved ]]; then
            warn 'This name does not resolve to an IPv4 address yet. Check the DNS record before clients use it.'
        elif valid_ipv4 "$DOWNLOAD_SSH_HOST" && [[ $resolved != "$DOWNLOAD_SSH_HOST" ]]; then
            warn "It resolves to $resolved, but this VPS is $DOWNLOAD_SSH_HOST. Make sure that is intentional."
        else
            ok "Resolves to $resolved."
        fi
    fi
    confirm_choice "Save $value as the server address?" 'No, keep the current one' "Save $value" normal || { cancelled; return 0; }
    ca_lock || return 1
    tmp=$(mktemp "$CONFIG_DIR/.domain.XXXXXXXX") || return 1
    darban_tmp_register "$tmp"
    if ! printf '%s\n' "$value" >"$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$DOMAIN_FILE"; then
        fail 'Could not save the address.'; return 1
    fi
    audit "server address changed: ${old:-unset} -> $value"
    ok 'Saved.'
    info 'Profiles downloaded earlier still use the old address; share them again (menu 5).'
}
valid_ssh_host() { valid_ipv4 "$1" || valid_domain "$1"; }
valid_ssh_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_ssh_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
set_download_access() {
    local host=$DOWNLOAD_SSH_HOST port=$DOWNLOAD_SSH_PORT user=$DOWNLOAD_SSH_USER
    info 'The SSH address, port and user that the download commands for a profile kept on the server use (scp, sftp). Set them when you reach this server by another name or port than the one shown. No restart is needed.'
    say
    while :; do
        ask "SSH address${host:+ [$host]} (Enter = keep): " || { cancelled; return 0; }
        if [[ -n $REPLY ]]; then host=$REPLY; fi
        if valid_ssh_host "$host"; then break; fi
        warn 'Enter a hostname or an IPv4 address.'; host=$DOWNLOAD_SSH_HOST
    done
    while :; do
        ask "SSH port [$port] (Enter = keep): " || { cancelled; return 0; }
        if [[ -n $REPLY ]]; then port=$REPLY; fi
        if valid_ssh_port "$port"; then break; fi
        warn 'Enter a number from 1 to 65535.'; port=$DOWNLOAD_SSH_PORT
    done
    while :; do
        ask "SSH user [$user] (Enter = keep): " || { cancelled; return 0; }
        if [[ -n $REPLY ]]; then user=$REPLY; fi
        if valid_ssh_user "$user"; then break; fi
        warn 'Enter a valid Linux user name.'; user=$DOWNLOAD_SSH_USER
    done
    if [[ $user != root ]]; then info "$OUT_DIR is readable by root only, so $user gets a private copy of a profile when it is shared."; fi
    DOWNLOAD_SSH_HOST=$host DOWNLOAD_SSH_PORT=$port DOWNLOAD_SSH_USER=$user
    save_config || { fail 'Could not save the settings.'; return 1; }
    audit "download access changed: $user@$host:$port"
    saved "$user@$host:$port" 'to the download commands shown from now on'
}
set_client_days() {
    kv Current "${CLIENT_CERT_DAYS:-Easy-RSA default}"
    info 'How long a new client profile works. Common values: 365 (one year), 730 (two years), 1825 (five years); 0 keeps the Easy-RSA default of 825 days. Certificates are not renewed automatically.'
    say
    if ! ask 'Days a new client certificate lasts, 1 to 3650; 0 = Easy-RSA default (Enter = cancel): ' || [[ -z $REPLY ]]; then cancelled; return 0; fi
    if [[ $REPLY == 0 ]]; then
        CLIENT_CERT_DAYS=''
    elif valid_client_days "$REPLY"; then
        CLIENT_CERT_DAYS=$((10#$REPLY))
    else
        warn 'Enter a number from 0 to 3650. Nothing changed.'
        return 1
    fi
    save_config || { fail 'Could not save the settings.'; return 1; }
    audit "new client lifetime changed: ${CLIENT_CERT_DAYS:-default}"
    saved "new clients last ${CLIENT_CERT_DAYS:-the Easy-RSA default}${CLIENT_CERT_DAYS:+ days}" 'to clients created from now on'
}
set_link_hours() {
    kv Current "$(hours_label "$(link_hours)")"
    info 'A link or a file kept on the server is removed after this time, or as soon as its client connects, whichever comes first. Common values: 1, 6, 24 (the default), 48 or 72.'
    say
    prompt_valid 'Hours, 1 to 72 (Enter = cancel): ' valid_link_hours 'Enter a whole number of hours from 1 to 72.' || return 0
    LINK_HOURS=$((10#$REPLY))
    save_config || { fail 'Could not save the setting.'; return 1; }
    audit "share lifetime changed: $LINK_HOURS hours"
    saved "shares expire after $(hours_label "$LINK_HOURS")" 'from the next share'
}
set_link_port() {
    kv Current "$(link_port_summary)"
    local free='' candidate
    info 'The TCP port of the link page. It must be open in your provider firewall, and no other program may use it.'
    for candidate in $LINK_PORT_CHOICES; do tcp_port_taken "$candidate" || free+="${free:+, }$candidate"; done
    if [[ -n $free ]]; then info "Free now: $free"; fi
    say
    prompt_valid 'New port, 1 to 65535 (Enter = cancel): ' valid_link_port 'Enter a number from 1 to 65535.' || return 0
    if tcp_port_taken "$((10#$REPLY))"; then
        warn "TCP $((10#$REPLY)) is already used by $(safe_text "$(tcp_port_program "$((10#$REPLY))")"). Nothing changed."
        return 1
    fi
    LINK_PORT=$((10#$REPLY))
    save_config || { fail 'Could not save the setting.'; return 1; }
    audit "share link port changed: $LINK_PORT"
    saved "TCP $LINK_PORT" 'from the next link'
}
restart_openvpn() {
    local state port rc=0
    state=$(systemctl is-active "$DARBAN_UNIT" 2>/dev/null || true)
    kv Service "${state:-unknown}"
    say
    info 'Creating and revoking clients do not need a restart.'
    info 'Use this after editing server.conf by hand, or when the service has stopped.'
    say
    confirm_choice 'Restart OpenVPN now? This drops ALL connected VPN users for a few seconds.' 'No, do not restart' 'Restart OpenVPN' caution restart || { cancelled; return 0; }
    ca_lock || return 1
    info "Restarting OpenVPN${S_ELL}"
    port=$(server_port 2>/dev/null) || port=''
    critical_begin
    systemctl restart "$DARBAN_UNIT" || rc=$?
    if (( rc == 0 )); then
        if [[ -n $port ]]; then
            wait_for_port "$port" || rc=1
        else
            systemctl is-active --quiet "$DARBAN_UNIT" || rc=1
        fi
    fi
    critical_end
    if (( rc != 0 )); then
        urgent "OpenVPN did not come back up${port:+ on UDP $port}. Check: journalctl -u $DARBAN_UNIT -n 50 --no-pager"
        audit 'OpenVPN restart from the menu FAILED'
        return 1
    fi
    audit 'OpenVPN restarted from the menu'
    if [[ -n $port ]]; then
        ok "OpenVPN is running and listening on UDP $port."
    else
        ok 'OpenVPN is running.'
        warn 'Could not read a single port from server.conf, so the UDP listener was not checked.'
    fi
}
