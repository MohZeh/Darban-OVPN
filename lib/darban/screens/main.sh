#!/usr/bin/env bash
# The main menu, the recovery menu, the first run and the welcome.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

draw_main() {
    # Ordered by use: creating a client comes first, and revoking, which cannot be undone, ends its group.
    clear_screen
    title_bar
    status_block
    hr
    menu_group CLIENTS
    menu_item 1 'Create client'
    menu_item 2 'List clients'
    menu_item 3 'Connected now'
    menu_item 4 'Revoke client (permanent)' danger
    menu_group SHARING
    menu_item 5 'Share a profile'
    menu_item 6 'Links and files (show, cancel, delete)'
    menu_group SERVER
    menu_item 7 'Settings'
    menu_item 8 'Maintenance'
    menu_item 9 'Setup (update, uninstall, remove all)'
    menu_item 0 'Exit'
    hr
    printf ' %sAn empty answer or Ctrl+C cancels %s %s %s %s%s\n' "$C_HINT" "$S_SEP" "${DARBAN_URL#https://}" "$S_SEP" "$DARBAN_EMAIL" "$C_RESET"
}
program_exit() {
    # Said on the way out, so nobody has to look for how to come back.
    printf '\nTo open this menu again, type: %s\n' "$(cmd sudo darban)" || true
    exit 0
}
draw_recovery() {
    clear_screen
    title_bar
    fail "This server cannot be managed right now: $SERVER_PROBLEM"
    hr
    menu_item 1 'Diagnostics (read-only)'
    menu_item 2 'Check for updates'
    menu_item 3 'Uninstall this tool only' danger
    menu_item 4 'Remove everything (tool, OpenVPN, CA)' danger
    menu_item 0 'Exit'
    hr
    printf ' %sThe other options return when this is fixed.%s\n' "$C_DIM" "$C_RESET" || true
}
menu_traps() {
    # A trapped (not default) SIGINT lets Ctrl+C cancel only the running action. Outside an action it exits
    # from inside the trap: bash resumes an interrupted read afterwards, so a flag would wait for Enter.
    trap 'if (( ACTION_RUNNING )); then DARBAN_INT=1; else program_exit; fi' INT
    trap ui_restore EXIT
}
recovery_menu() {
    local redraw=1
    menu_traps
    while :; do
        if (( redraw )); then draw_recovery || true; fi
        redraw=1
        ask 'Choose [0-4]: ' || program_exit
        case $REPLY in
            1) menu_action 'Diagnostics' health ;;
            2) menu_action 'Check for updates' update_tool ;;
            3) menu_action 'Uninstall this tool' uninstall_tool ;;
            4) menu_action 'Remove everything' remove_everything ;;
            0) program_exit ;;
            '') redraw=0 ;;
            *) warn "Unknown option \"$REPLY\". Enter a number from 0 to 4."; redraw=0 ;;
        esac
    done
}
needs_reboot() {
    # A kernel was added for the ovpn module, and the system is not running one with it yet.
    grep -q '^kernel ' "$CONFIG_DIR/.server-setup-started" 2>/dev/null && ! modinfo -k "$(uname -r)" ovpn >/dev/null 2>&1
}
next_steps() {
    local listeners proto port
    listeners=$(server_listeners 2>/dev/null) || listeners='udp ?'
    say
    section 'Your VPN server is ready'
    kv Address "$(domain)"
    kv Port "$(awk '{printf "%s%s/%s", (NR > 1 ? " + " : ""), $2, toupper($1)} END {print ""}' <<<"$listeners")"
    say
    printf '%sDo this now:%s\n' "$C_BOLD" "$C_RESET" || true
    while read -r proto port; do
        bullet "Open ${proto^^} $port in your server provider's firewall. This tool cannot see or change it."
    done <<<"$listeners"
    if needs_reboot; then
        say
        printf '%sLater:%s\n' "$C_BOLD" "$C_RESET" || true
        bullet "Reboot once when convenient, for a faster VPN: $(cmd sudo reboot)"
    fi
    if iptables -S FORWARD 2>/dev/null | grep '^-P FORWARD DROP' >/dev/null && ! command -v ufw >/dev/null; then
        say
        warn 'The iptables FORWARD policy is DROP, for example because of Docker. Clients may connect but have no internet until it allows tun0.'
    fi
    say
    printf '%sTo manage this server at any time:%s\n' "$C_BOLD" "$C_RESET" || true
    bullet "Connect over SSH, type $(cmd sudo darban) and press Enter. The menu opens, where clients are created, shared and revoked."
    say
}
welcome() {
    # The end of a new setup: what is left to do, and one Enter to the first client.
    next_steps
    if (( ! UI_TTY )); then say 'Next, create a client: sudo darban'; return 0; fi
    if confirm_choice 'Create your first client now?' 'Not now' 'Create a client' normal '' 2; then
        say
        run_action create_client client1
    fi
    main_menu
}
first_run() {
    # Profiles cannot be built without a hostname, so guide a fresh install there first.
    valid_domain "$(domain)" && return 0
    (( UI_TTY )) || return 0
    clear_screen
    title_bar
    info 'Welcome! The server address is not set yet; client profiles need it.'
    if confirm_choice 'Set the server address now?' 'Not now' 'Set it now' normal '' 2; then
        menu_action 'Change server address' set_domain
    fi
}
main_menu() {
    local redraw=1
    menu_traps
    start_update_check
    wait_for_update_check
    first_run
    while :; do
        if (( redraw )); then draw_main || true; fi
        redraw=1
        ask 'Choose [0-9]: ' || program_exit
        case $REPLY in
            1) menu_action 'Create client' create_client ;;
            2) menu_action 'Clients' list_menu ;;
            3) menu_action 'Connected now' connected_clients ;;
            4) menu_action 'Revoke client (permanent)' revoke_client ;;
            5) menu_action 'Share a profile' share_profile ;;
            6) menu_action 'Links and files' links_and_files ;;
            7) settings_menu ;;
            8) maintenance_menu ;;
            9) setup_menu ;;
            0) program_exit ;;
            '') redraw=0 ;;
            *) warn "Unknown option \"$REPLY\". Enter a number from 0 to 9."; redraw=0 ;;
        esac
    done
}
