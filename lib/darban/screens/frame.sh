#!/usr/bin/env bash
# The frame of every screen: the title bar, the status block and menu items.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- screens ----------
title_bar() {
    printf '%s Darban OVPN v%s%s%s\n' "$C_TITLE" "$DARBAN_VERSION" "${1:+ $S_CRUMB $1}" "$C_RESET"
    hr
}
status_block() {
    local host port state endpoint e valid revoked expired soon clients alert pending leftovers
    host=$(domain)
    port=$(server_port 2>/dev/null || printf '?')
    state=$(systemctl is-active "$DARBAN_UNIT" 2>/dev/null || true)
    if [[ $state == active ]]; then state="$C_GREEN$S_DOT active$C_RESET"; else state="$C_RED$S_DOT ${state:-not running}$C_RESET"; fi
    if valid_domain "$host"; then
        endpoint="$host:$port/UDP"
    else
        endpoint="${C_YELLOW}address not set $S_ARROW Settings $S_CRUMB 1$C_RESET (port $port/UDP)"
    fi
    # A healthy blocklist is one word on the server line; a problem gets a line of its own.
    if { darban_crl_configured && verify_published_crl "$DARBAN_CRL"; } >/dev/null 2>&1 && e=$(darban_crl_expiry_epoch "$DARBAN_CRL"); then
        kv Server "$state $S_SEP $endpoint $S_SEP blocklist $C_GREEN$S_OK$C_RESET"
    else
        kv Server "$state $S_SEP $endpoint"
        kv Blocklist "$C_RED$S_BAD problem$C_RESET $S_ARROW details: Maintenance $S_CRUMB 1, repair: Maintenance $S_CRUMB 2"
    fi
    pending=$(revocation_pending_names 2>/dev/null | join_lines) || pending=''
    leftovers=$(revoked_share_names 2>/dev/null | join_lines) || leftovers=''
    read -r valid revoked expired soon < <(client_stats)
    clients="$valid valid $S_SEP $revoked revoked"
    if (( expired > 0 )); then clients+=" $S_SEP $expired expired"; fi
    if (( soon > 0 )); then clients+=" $S_SEP $C_YELLOW$soon expiring soon$C_RESET"; fi
    if mgmt_available && e=$(connected_rows 2>/dev/null) && [[ -n $e ]]; then clients+=" $S_SEP $(wc -l <<<"$e") connected"; fi
    kv Clients "$clients"
    # Alerts live in the header so clearing the screen can never hide them.
    {
        if e=$(available_update) && [[ -n $e ]]; then printf '%s\n' "Update available: v$e $S_ARROW Setup $S_CRUMB 2"; fi
        if [[ -n $pending ]]; then printf '%s\n' "Revoked but NOT blocked yet: $(safe_text "$pending") $S_ARROW Maintenance $S_CRUMB 2"; fi
        if [[ -n $leftovers ]]; then printf '%s\n' "Revocation unfinished, link or profile still on server: $(safe_text "$leftovers") $S_ARROW Maintenance $S_CRUMB 2"; fi
        if systemctl is-failed --quiet darban-crl.service 2>/dev/null; then printf '%s\n' "Last automatic CRL run FAILED $S_ARROW Maintenance $S_CRUMB 1"; fi
        if ! systemctl is-active --quiet darban-crl.timer 2>/dev/null; then printf '%s\n' "CRL renewal timer is not active $S_ARROW Maintenance $S_CRUMB 1"; fi
        if e=$(cert_end_epoch "$DARBAN_PKI/ca.crt") && (( $(days_until "$e") <= EXPIRY_WARN_DAYS )); then printf '%s\n' "CA certificate expires $(date -u -d "@$e" +%Y-%m-%d)"; fi
        if e=$(darban_server_cert_pem | openssl x509 -noout -enddate 2>/dev/null) && e=$(date -u -d "${e#notAfter=}" +%s) && (( $(days_until "$e") <= EXPIRY_WARN_DAYS )); then printf '%s\n' "Server certificate expires $(date -u -d "@$e" +%Y-%m-%d); it is not renewed automatically"; fi
        printf '%s\n' "${CONFIG_ISSUES[@]}"
    } | while IFS= read -r alert; do
        if [[ -n $alert ]]; then printf '  %s%s %s%s\n' "$C_YELLOW" "$S_WARN" "$(with_action "$alert")" "$C_RESET"; fi
    done
    # Only when the check takes longer than the first screen waits: the next screen has its answer.
    if update_check_running; then printf '  %sChecking for a new release%s%s\n' "$C_DIM" "$S_ELL" "$C_RESET"; fi
}
menu_item() {
    # menu_item <key> <label> [danger]: a key to press, and its label, red when it cannot be undone.
    local color=''
    if [[ ${3:-} == danger ]]; then color=$C_DANGER; fi
    printf '   %s%2s%s  %s%s%s\n' "$C_KEY" "$1" "$C_RESET" "$color" "$2" "$C_RESET" || true
}
menu_group() { printf ' %s%s%s\n' "$C_GROUP" "$1" "$C_RESET" || true; }
