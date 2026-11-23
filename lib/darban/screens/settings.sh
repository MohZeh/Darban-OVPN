#!/usr/bin/env bash
# The screens of Settings: Settings, Advanced, Blocked destinations and DNS on this server.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

draw_settings() {
    local host port
    host=$(domain)
    port=$(server_port 2>/dev/null || printf '?')
    clear_screen
    title_bar Settings
    printf ' %sWhat clients connect to, and how profiles are shared. Choose one to see what it does before anything changes.%s\n' "$C_DIM" "$C_RESET" || true
    menu_group SERVER
    menu_item 1 "$(printf '%-24s %s' 'Server address' "${host:-not set}")"
    menu_item 2 "$(printf '%-24s %s' 'OpenVPN UDP port *' "$port")"
    menu_group SHARING
    menu_item 3 "$(printf '%-24s %s' 'Shares expire after' "$(hours_label "$(link_hours)")")"
    menu_item 4 "$(printf '%-24s %s' 'Link port' "$(link_port_summary)")"
    menu_item 5 "$(printf '%-24s %s' 'Link certificate' "$(link_cert_summary)")"
    menu_group MORE
    menu_item 6 'Advanced'
    menu_item 7 "$(printf '%-24s %s' 'Blocked destinations' "$(blocked_summary)")"
    menu_item 8 "$(printf '%-24s %s' 'DNS on this server' "$(dns_server_summary)")"
    menu_item 0 'Back'
    hr
    printf ' %s* restarts OpenVPN: connected users drop for a few seconds.%s\n' "$C_DIM" "$C_RESET" || true
}
draw_advanced() {
    local network routing dns ciphers keepalive verb download days
    network=$(awk '$1=="server" {print $2 "/24"; exit}' "$DARBAN_SERVER_CONF")
    if conf_full_tunnel; then routing='full tunnel'; else routing='split tunnel'; fi
    dns=$(conf_dns)
    ciphers=$(conf_value data-ciphers)
    keepalive=$(conf_value keepalive)
    verb=$(conf_value verb)
    download='not set'
    if [[ -n $DOWNLOAD_SSH_HOST ]]; then download=$DOWNLOAD_SSH_USER@$DOWNLOAD_SSH_HOST:$DOWNLOAD_SSH_PORT; fi
    days=${CLIENT_CERT_DAYS:-Easy-RSA default}
    clear_screen
    title_bar "Settings $S_CRUMB Advanced"
    printf ' %sThe defaults suit most servers. Each item says what it changes, and suggests common values.%s\n' "$C_DIM" "$C_RESET" || true
    menu_group VPN
    menu_item 1 "$(printf '%-24s %s' 'Traffic routing *' "$routing")"
    menu_item 2 "$(printf '%-24s %s' 'DNS for clients *' "${dns:-none pushed}")"
    menu_item 3 "$(printf '%-24s %s' 'VPN network *' "${network:-not set}")"
    menu_item 4 "$(printf '%-24s %s' 'Data ciphers *' "${ciphers:-OpenVPN default}")"
    menu_item 5 "$(printf '%-24s %s' 'Keepalive *' "${keepalive:-not set}")"
    menu_item 6 "$(printf '%-24s %s' 'Log detail *' "${verb:-OpenVPN default}")"
    menu_group CLIENTS
    menu_item 7 "$(printf '%-24s %s' 'New client lifetime' "$days")"
    menu_item 8 "$(printf '%-24s %s' 'Download access' "$download")"
    menu_group TRAFFIC
    menu_item 9 "$(printf '%-24s %s' 'TCP MSS' "$(mss_label)")"
    menu_item 0 'Back'
    hr
    printf ' %s* restarts OpenVPN: connected users drop for a few seconds; a change that fails is rolled back.%s\n' "$C_DIM" "$C_RESET" || true
}
advanced_menu() {
    local redraw=1
    while :; do
        if (( redraw )); then draw_advanced || true; fi
        redraw=1
        ask 'Choose [0-9, Enter = back]: ' || return 0
        case $REPLY in
            1) menu_action 'Traffic routing' set_routing ;;
            2) menu_action 'DNS for clients' set_dns ;;
            3) menu_action 'VPN network' set_vpn_network ;;
            4) menu_action 'Data ciphers' set_ciphers ;;
            5) menu_action 'Keepalive' set_keepalive ;;
            6) menu_action 'Log detail' set_verb ;;
            7) menu_action 'New client lifetime' set_client_days ;;
            8) menu_action 'Download access' set_download_access ;;
            9) menu_action 'TCP MSS' set_tcp_mss ;;
            0|'') return 0 ;;
            *) warn "Unknown option \"$REPLY\". Enter a number from 0 to 9."; redraw=0 ;;
        esac
    done
}
settings_menu() {
    local redraw=1
    while :; do
        if (( redraw )); then draw_settings || true; fi
        redraw=1
        ask 'Choose [0-8, Enter = back]: ' || return 0
        case $REPLY in
            1) menu_action 'Change server address' set_domain ;;
            2) menu_action 'Change OpenVPN UDP port' change_port ;;
            3) menu_action 'Shares expire after' set_link_hours ;;
            4) menu_action 'Link port' set_link_port ;;
            5) menu_action 'Link certificate' change_link_cert ;;
            6) advanced_menu ;;
            7) blocked_menu ;;
            8) dns_server_menu ;;
            0|'') return 0 ;;
            *) warn "Unknown option \"$REPLY\". Enter a number from 0 to 8."; redraw=0 ;;
        esac
    done
}
draw_blocked() {
    clear_screen
    title_bar "Settings $S_CRUMB Blocked destinations"
    printf ' %sVPN clients cannot reach these through this server, so they never see its address. Changes apply at once, without a restart.%s\n' "$C_DIM" "$C_RESET" || true
    menu_item 1 "$(printf '%-24s %s' 'Countries' "$(country_names "$BLOCK_COUNTRIES")")"
    menu_item 2 "$(printf '%-24s %s' 'Their sites' "$(mode_label)")"
    menu_item 3 "$(printf '%-24s %s' 'Block an address' "$(address_label "$(blocked_extra_count)") of your own")"
    menu_item 4 'Unblock an address'
    menu_item 5 "$(printf '%-24s %s' 'Update the lists' "$(lists_label)")"
    menu_item 0 'Back'
}
blocked_menu() {
    local redraw=1
    geo_migrate || true
    while :; do
        if (( redraw )); then draw_blocked || true; fi
        redraw=1
        ask 'Choose [0-5, Enter = back]: ' || return 0
        case $REPLY in
            1) menu_action 'Countries' set_countries ;;
            2) menu_action 'Their sites' set_country_mode ;;
            3) menu_action 'Block an address' block_address ;;
            4) menu_action 'Unblock an address' unblock_address ;;
            5) menu_action 'Update the lists' update_lists ;;
            0|'') return 0 ;;
            *) warn "Unknown option \"$REPLY\". Enter a number from 0 to 5."; redraw=0 ;;
        esac
    done
}
draw_dns_server() {
    clear_screen
    title_bar "Settings $S_CRUMB DNS on this server"
    printf ' %sClients ask this server for names, and it asks the upstream DNS. Only Unbound restarts for items 2 to 9.%s\n' "$C_DIM" "$C_RESET" || true
    menu_item 1 "$(printf '%-24s %s' 'DNS on this server *' "$(on_off "$DNS_SERVER")")"
    menu_item 2 "$(printf '%-24s %s' 'Upstream DNS' "$(dns_upstream)")"
    menu_item 3 "$(printf '%-24s %s' 'DNS over TLS' "$(on_off "$DNS_TLS")")"
    menu_item 4 "$(printf '%-24s %s' 'Clients must use it' "$(on_off "$DNS_FORCE")")"
    menu_item 5 "$(printf '%-24s %s' 'DNSSEC check' "$(on_off "$DNS_DNSSEC")")"
    menu_item 6 "$(printf '%-24s %s' 'Name lists' "$(name_lists_label "$NAME_LISTS")")"
    menu_item 7 "$(printf '%-24s %s' 'Names you block' "$(names_count_label "$NAMES_BLOCK")")"
    menu_item 8 "$(printf '%-24s %s' 'Names you allow' "$(names_count_label "$NAMES_ALLOW")")"
    menu_item 9 "$(printf '%-24s %s' 'Update the name lists' "$(name_lists_date)")"
    menu_item 0 'Back'
    hr
    printf ' %s* restarts OpenVPN: connected users drop for a few seconds.%s\n' "$C_DIM" "$C_RESET" || true
}
dns_server_menu() {
    local redraw=1
    while :; do
        if (( redraw )); then draw_dns_server || true; fi
        redraw=1
        ask 'Choose [0-9, Enter = back]: ' || return 0
        case $REPLY in
            1) menu_action 'DNS on this server' set_dns_server ;;
            2) menu_action 'Upstream DNS' set_dns_upstream ;;
            3) menu_action 'DNS over TLS' set_dns_tls ;;
            4) menu_action 'Clients must use it' set_dns_force ;;
            5) menu_action 'DNSSEC check' set_dns_dnssec ;;
            6) menu_action 'Name lists' set_name_lists ;;
            7) menu_action 'Names you block' set_names_block ;;
            8) menu_action 'Names you allow' set_names_allow ;;
            9) menu_action 'Update the name lists' update_name_lists ;;
            0|'') return 0 ;;
            *) warn "Unknown option \"$REPLY\". Enter a number from 0 to 9."; redraw=0 ;;
        esac
    done
}
