#!/usr/bin/env bash
# Validation, the action runner and dates.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- validation ----------
# A name of digits only could be confused with a number in a list.
valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ && $1 != server && ! $1 =~ ^[0-9]+$ ]]; }
# Names of certificates that already exist: wider than valid_name (new clients stay strict), yet still
# safe as a file name and as one word of an Easy-RSA argument or a management-interface command.
valid_link_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_client_days() { [[ $1 =~ ^[0-9]{1,4}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 3650 )); }
# A link holds a private key and stays in chat histories, so it lasts three days at most.
valid_link_hours() { [[ $1 =~ ^[0-9]{1,2}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 72 )); }
link_hours() { printf '%s' "${LINK_HOURS:-24}"; }
hours_label() { if (( $1 == 1 )); then printf '1 hour'; else printf '%s hours' "$1"; fi; }
valid_existing_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}$ && $1 != server ]]; }

# ---------- action runner ----------
# Interrupts are ignored while CA/CRL or server.conf changes are half-applied; children inherit this.
# Nested sections are counted, so an inner one cannot let Ctrl+C in before the outer one is done.
critical_begin() { CRITICAL_DEPTH=$((CRITICAL_DEPTH + 1)); trap '' INT TERM HUP; }
critical_end() {
    if (( CRITICAL_DEPTH > 0 )); then CRITICAL_DEPTH=$((CRITICAL_DEPTH - 1)); fi
    if (( CRITICAL_DEPTH == 0 )); then trap 'exit 130' INT TERM HUP; fi
}
ca_lock() {
    # Held only while something changes, never while waiting for an answer, so a person thinking does not
    # hold up the daily CRL renewal. Whatever was checked before asking must be checked again after this.
    if (( ! CA_LOCKED )); then darban_lock || return 1; CA_LOCKED=1; fi
}
ca_unlock() {
    if (( CA_LOCKED )); then flock -u 9 2>/dev/null || true; exec 9>&-; CA_LOCKED=0; fi
}
run_action() {
    # errexit is ignored inside any function called from if/||/&&, so each action runs in its
    # own subshell with errexit really on, temp-file cleanup and Ctrl+C = cancel. The status lands in ACTION_RC.
    local rc=0
    set +e
    ACTION_RUNNING=1
    (
        set -e
        trap 'ui_restore; darban_tmp_cleanup' EXIT
        critical_end
        "$@"
    )
    rc=$?
    set -e
    ACTION_RUNNING=0
    DARBAN_INT=0
    ACTION_RC=$rc
    # A setting the action saved lives only in the file: read it again, so the menu shows it and the next
    # action uses it.
    load_config
    case $rc in
        0|1|"$RC_NO_PAUSE") ;;
        130) say; info 'Cancelled.' ;;
        # The reader went away, as "darban status | head" does: the output stops there, like any command's, and
        # the status says so (141, SIGPIPE) instead of a pass or a fail it could not finish.
        141) ;;
        "$RC_IDLE"|"$RC_QUIT") exit 0 ;;
        *) warn "Operation aborted unexpectedly (status $rc); see messages above." ;;
    esac
}
menu_action() {
    # menu_action <title> <function>: clean screen, run, then let the user read the result.
    local title=$1
    shift
    clear_screen
    section "$title"
    run_action "$@"
    if (( ACTION_RC != RC_NO_PAUSE )); then say; pause; fi
}

# ---------- dates ----------
cert_end_epoch() {
    local line
    line=$(openssl x509 -in "$1" -noout -enddate 2>/dev/null) || return 1
    date -u -d "${line#notAfter=}" +%s
}
days_until() { printf '%d\n' $(( ($1 - $(date -u +%s)) / 86400 )); }
describe_expiry() {
    # "2029-02-05 (820 days)" / "2026-10-01 (EXPIRED)"
    local epoch=$1 days
    days=$(days_until "$epoch")
    if (( epoch <= $(date -u +%s) )); then
        printf '%s (%sEXPIRED%s)\n' "$(date -u -d "@$epoch" +%Y-%m-%d)" "$C_RED" "$C_RESET"
    elif (( days <= EXPIRY_WARN_DAYS )); then
        printf '%s (%s%d days%s)\n' "$(date -u -d "@$epoch" +%Y-%m-%d)" "$C_YELLOW" "$days" "$C_RESET"
    else
        printf '%s (%d days)\n' "$(date -u -d "@$epoch" +%Y-%m-%d)" "$days"
    fi
}
