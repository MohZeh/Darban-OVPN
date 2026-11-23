#!/usr/bin/env bash
# The screens of Maintenance and Setup.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

draw_maintenance() {
    clear_screen
    title_bar Maintenance
    printf ' %sCheck the server, fix what a revocation left unfinished, and back up the CA.%s\n' "$C_DIM" "$C_RESET" || true
    menu_item 1 'Diagnostics (read-only)'
    menu_item 2 'Fix the blocklist (CRL), or finish a revocation'
    menu_item 3 'Restart OpenVPN'
    menu_item 4 'Back up the CA now (encrypted)'
    menu_item 0 'Back'
    hr
}
maintenance_menu() {
    local redraw=1
    while :; do
        if (( redraw )); then draw_maintenance || true; fi
        redraw=1
        ask 'Choose [0-4, Enter = back]: ' || return 0
        case $REPLY in
            1) menu_action 'Diagnostics' health_view ;;
            2) menu_action 'Fix the blocklist' repair_crl ;;
            3) menu_action 'Restart OpenVPN' restart_openvpn ;;
            4) menu_action 'Back up the CA now' backup_now ;;
            0|'') return 0 ;;
            *) warn "Unknown option \"$REPLY\". Enter a number from 0 to 4."; redraw=0 ;;
        esac
    done
}
draw_setup() {
    clear_screen
    title_bar Setup
    menu_item 1 'About'
    menu_item 2 "$(printf '%-24s %s' 'Check for updates' "installed: v$DARBAN_VERSION $S_SEP $(update_summary)")"
    menu_item 3 "$(printf '%-24s %s' 'Update notice' "$([[ $UPDATE_CHECK == yes ]] && echo on || echo off)")"
    menu_item 4 'Restore previous version'
    menu_item 5 'Uninstall this tool only' danger
    menu_item 6 'Remove everything (tool, OpenVPN, CA)' danger
    menu_item 0 'Back'
    hr
}
setup_menu() {
    local redraw=1
    while :; do
        if (( redraw )); then draw_setup || true; fi
        redraw=1
        ask 'Choose [0-6, Enter = back]: ' || return 0
        case $REPLY in
            # Unlocked: the installer's own CRL check takes the same lock and would wait for this one.
            1) menu_action 'About' about_text ;;
            2) menu_action 'Check for updates' update_tool ;;
            3) run_action toggle_update_notice; load_config ;;
            4) menu_action 'Restore previous version' restore_previous ;;
            5) menu_action 'Uninstall this tool' uninstall_tool ;;
            6) menu_action 'Remove everything' remove_everything ;;
            0|'') return 0 ;;
            *) warn "Unknown option \"$REPLY\". Enter a number from 0 to 6."; redraw=0 ;;
        esac
    done
}
