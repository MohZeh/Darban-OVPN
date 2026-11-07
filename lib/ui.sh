#!/usr/bin/env bash
# Terminal presentation and prompts, shared by the manager and the server setup.

# A root tool holding CA access should not stay open unattended.
IDLE_TIMEOUT=900
# Exit status of an action subshell closed by the idle timeout.
RC_IDLE=11
DARBAN_INT=0

# ---------- terminal presentation ----------
UI_TTY=0
[[ -t 0 && -t 1 ]] && UI_TTY=1
UI_CLEAR=$UI_TTY
UI_WIDTH=72
C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_REVERSE=''
S_OK='+' S_BAD='x' S_WARN='!' S_URGENT='!!' S_INFO='-' S_LINE='-' S_DOT='*' S_SEP='|' S_ARROW='->' S_ELL='...' S_CRUMB='>' S_POINTER='>' S_UPDOWN='Up/Down'
UI_CHOOSING=0
UI_SAVED_STTY=''
ui_init() {
    local cols
    # Colors only on a real terminal, and never when NO_COLOR is set (https://no-color.org).
    if (( UI_TTY )) && [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_REVERSE=$'\e[7m'
    fi
    # Box/check symbols only when the locale is UTF-8 (e.g. PuTTY with a legacy charset shows garbage).
    if [[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} =~ [Uu][Tt][Ff]-?8 ]]; then
        S_OK='✓' S_BAD='✗' S_URGENT='‼' S_INFO='•' S_LINE='─' S_DOT='●' S_SEP='·' S_ARROW='→' S_ELL='…' S_CRUMB='›' S_POINTER='❯' S_UPDOWN='↑/↓'
    fi
    cols=$(tput cols 2>/dev/null || echo 80)
    [[ $cols =~ ^[0-9]+$ ]] || cols=80
    UI_WIDTH=$(( cols < 40 ? 40 : cols > 72 ? 72 : cols ))
}
say() { printf '%s\n' "$*" || true; }
info() { printf '%s %s\n' "$S_INFO" "$*" || true; }
ok() { printf '%s%s%s %s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$*" || true; }
warn() { printf '%s%s WARNING:%s %s\n' "$C_YELLOW" "$S_WARN" "$C_RESET" "$*" >&2 || true; }
fail() { printf '%s%s ERROR:%s %s\n' "$C_RED" "$S_BAD" "$C_RESET" "$*" >&2 || true; }
urgent() { printf '%s%s%s URGENT:%s %s\n' "$C_BOLD" "$C_RED" "$S_URGENT" "$C_RESET" "$*" >&2 || true; }
darban_error() { fail "$*"; }
bullet() { printf '    %s %s\n' "$S_INFO" "$*" || true; }
kv() { printf '  %-9s %s\n' "$1" "$2" || true; }
hr() {
    local line
    printf -v line '%*s' "$UI_WIDTH" ''
    printf '%s%s%s\n' "$C_DIM" "${line// /$S_LINE}" "$C_RESET" || true
}
section() { printf '%s %s%s\n' "$C_BOLD" "$1" "$C_RESET" || true; hr; }
clear_screen() {
    # Cursor home + clear visible screen only; scrollback is kept so earlier commands can still be copied.
    if (( UI_CLEAR )); then printf '\e[H\e[2J' || true; fi
}
emit() {
    # Long output goes through a pager on a terminal; short output is printed as is.
    local text=$1 rows
    rows=$(tput lines 2>/dev/null || echo 24)
    [[ $rows =~ ^[0-9]+$ ]] || rows=24
    if (( UI_TTY )) && command -v less >/dev/null && (( $(printf '%s' "$text" | wc -l) > rows - 4 )); then
        printf '%s' "$text" | less -FRX || true
    else
        printf '%s' "$text" || true
    fi
}
audit() {
    # Who did what and when, in the system journal (journalctl -t darban).
    logger -t darban -p authpriv.notice -- "by ${SUDO_USER:-$(id -un 2>/dev/null || echo root)}: $*" 2>/dev/null || true
}

# ---------- input ----------
FA_DIGITS=(۰ ۱ ۲ ۳ ۴ ۵ ۶ ۷ ۸ ۹)
AR_DIGITS=(٠ ١ ٢ ٣ ٤ ٥ ٦ ٧ ٨ ٩)
normalize_reply() {
    # Persian/Arabic-Indic digits (typed with a Persian keyboard layout) become ASCII; outer spaces are trimmed.
    local i
    for i in 0 1 2 3 4 5 6 7 8 9; do
        REPLY=${REPLY//${FA_DIGITS[i]}/$i}
        REPLY=${REPLY//${AR_DIGITS[i]}/$i}
    done
    REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
    REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}
idle_exit() {
    printf '\n' || true
    warn "No input for $((IDLE_TIMEOUT / 60)) minutes; closing the manager."
    if (( BASH_SUBSHELL > 0 )); then exit "$RC_IDLE"; fi
    exit 0
}
ask() {
    # Sets REPLY. Returns 1 on Ctrl+D/EOF or Ctrl+C (at a menu prompt); exits after IDLE_TIMEOUT.
    local rc=0
    REPLY=''
    DARBAN_INT=0
    read -r -t "$IDLE_TIMEOUT" -p "$1" REPLY || rc=$?
    if (( DARBAN_INT )); then DARBAN_INT=0; printf '\n' || true; return 1; fi
    if (( rc > 128 )); then idle_exit; fi
    normalize_reply
    return "$rc"
}
cancelled() { info 'Cancelled; nothing changed.'; }
prompt_valid() {
    # prompt_valid <prompt> <validator> <hint>: re-asks until valid; empty input or EOF cancels.
    local prompt=$1 validator=$2 hint=$3
    while :; do
        if ! ask "$prompt" || [[ -z $REPLY ]]; then cancelled; return 1; fi
        if "$validator" "$REPLY"; then return 0; fi
        warn "$hint"
    done
}
ui_restore() {
    # Runs on every way out of a choice prompt, including Ctrl+C and the idle timeout.
    if (( UI_CHOOSING )); then
        UI_CHOOSING=0
        printf '\e[?7h\e[?25h' || true
        if [[ -n $UI_SAVED_STTY ]]; then stty "$UI_SAVED_STTY" 2>/dev/null || true; fi
    fi
}
choice_row() {
    # choice_row <number> <label> <color> <selected>. Long labels are cut, never wrapped: redrawing counts lines.
    local label=${2:0:UI_WIDTH-8}
    if (( $4 )); then
        printf '\r\e[K %s%s %s  %s %s\n' "$C_BOLD$3$C_REVERSE" "$S_POINTER" "$1" "$label" "$C_RESET" || true
    else
        printf '\r\e[K   %s%s%s  %s%s%s\n' "$C_DIM" "$1" "$C_RESET" "$3" "$label" "$C_RESET" || true
    fi
}
choice_hint() {
    # What Enter does right now, and exactly how to choose something else. Three rows: redrawing counts them.
    printf '\r\e[K %sEnter: %s%s\n' "$C_BOLD" "${1:0:UI_WIDTH-10}" "$C_RESET" || true
    printf '\r\e[K %sAnother option: press %s or its number, then Enter%s\n' "$C_DIM" "$S_UPDOWN" "$C_RESET" || true
    printf '\r\e[K %sEsc: Cancel%s\n' "$C_DIM" "$C_RESET" || true
}
confirm_line() {
    # A script or pipe has no arrow keys: 2 or the exact target agrees, and so does y when there is no target.
    local no=$1 yes=$2 target=$3 selected=$4
    say "  1  $no"
    say "  2  $yes"
    ask "Choose [1-2, Enter = $selected]: " || return 1
    if [[ -z $REPLY ]]; then [[ $selected == 2 ]]; return; fi
    if [[ $REPLY == 2 || ( -n $target && $REPLY == "$target" ) ]]; then return 0; fi
    if [[ -z $target ]] && [[ ${REPLY,,} == y || ${REPLY,,} == yes ]]; then return 0; fi
    if [[ $REPLY != 1 && ${REPLY,,} != n && ${REPLY,,} != no ]]; then warn "Not confirmed: you typed \"$REPLY\" (keyboard layout?)."; fi
    return 1
}
confirm_choice() {
    # confirm_choice <question> <no-label> <yes-label> <danger|caution|normal> [target] [default].
    # Returns 0 only when option 2 is confirmed with Enter. Moving to it does nothing by itself, so a
    # destructive answer always takes two deliberate key presses. Option 1 is the default and the safe one.
    local question=$1 no=$2 yes=$3 style=$4 target=${5:-} selected=${6:-1} color key rest rc answer=''
    printf '%s%s%s\n' "$C_BOLD" "$question" "$C_RESET" || true
    if (( ! UI_TTY )); then confirm_line "$no" "$yes" "$target" "$selected"; return; fi
    case $style in
        danger) color=$C_RED ;;
        caution) color=$C_YELLOW ;;
        *) color=$C_CYAN ;;
    esac
    UI_SAVED_STTY=$(stty -g 2>/dev/null) || UI_SAVED_STTY=''
    UI_CHOOSING=1
    printf '\e[?25l\e[?7l' || true
    # Keys typed before the question was visible must not answer it.
    if [[ -t 0 ]]; then while IFS= read -rsn1 -t 0.01 key; do :; done; fi
    while [[ -z $answer ]]; do
        if (( selected == 1 )); then
            choice_row 1 "$no" "$C_GREEN" 1
            choice_row 2 "$yes" "$color" 0
        else
            choice_row 1 "$no" "$C_GREEN" 0
            choice_row 2 "$yes" "$color" 1
        fi
        if (( selected == 1 )); then choice_hint "$no"; else choice_hint "$yes"; fi
        rc=0; key=''; DARBAN_INT=0
        IFS= read -rsn1 -t "$IDLE_TIMEOUT" key || rc=$?
        if (( DARBAN_INT )); then answer=cancel
        elif (( rc > 128 )); then ui_restore; idle_exit
        elif (( rc != 0 )); then answer=cancel
        else
            case $key in
                '') answer=$selected ;;
                1|۱|١) selected=1 ;;
                2|۲|٢) selected=2 ;;
                $'\t') selected=$(( 3 - selected )) ;;
                $'\x04') answer=cancel ;;
                $'\e')
                    rest=''
                    IFS= read -rsn2 -t 0.05 rest || true
                    case $rest in
                        '') answer=cancel ;;
                        '[A'|OA) selected=1 ;;
                        '[B'|OB) selected=2 ;;
                    esac ;;
            esac
        fi
        # Back to the first row: redraw in place, or replace the rows with the answer once there is one.
        printf '\e[5A\r' || true
    done
    printf '\e[J' || true
    ui_restore
    if [[ $answer == 2 ]]; then
        printf ' %s%s %s%s\n' "$color" "$S_POINTER" "$yes" "$C_RESET" || true
        return 0
    fi
    if [[ $answer == 1 && $selected == 1 ]]; then
        printf ' %s%s %s%s\n' "$C_GREEN" "$S_POINTER" "$no" "$C_RESET" || true
    fi
    return 1
}
choose_one() {
    # choose_one <question> <option>...: sets CHOSEN to the 1-based answer and returns 0; returns 1 when
    # cancelled. Arrows or digits move, Enter confirms, and the first option is the default.
    local question=$1 selected=1 n i key rest rc digit answer=''
    shift
    local -a options=("$@")
    n=${#options[@]}
    CHOSEN=1
    printf '%s%s%s\n' "$C_BOLD" "$question" "$C_RESET" || true
    if (( ! UI_TTY )); then
        for i in "${!options[@]}"; do say "  $((i + 1))  ${options[i]}"; done
        ask "Choose [1-$n, Enter = 1]: " || return 1
        if [[ -z $REPLY ]]; then return 0; fi
        if [[ $REPLY =~ ^[0-9]+$ ]] && (( 10#$REPLY >= 1 && 10#$REPLY <= n )); then CHOSEN=$((10#$REPLY)); return 0; fi
        warn "\"$REPLY\" is not one of the options."
        return 1
    fi
    UI_SAVED_STTY=$(stty -g 2>/dev/null) || UI_SAVED_STTY=''
    UI_CHOOSING=1
    printf '\e[?25l\e[?7l' || true
    if [[ -t 0 ]]; then while IFS= read -rsn1 -t 0.01 key; do :; done; fi
    while [[ -z $answer ]]; do
        for i in "${!options[@]}"; do
            if (( i + 1 == selected )); then choice_row $((i + 1)) "${options[i]}" "$C_CYAN" 1; else choice_row $((i + 1)) "${options[i]}" '' 0; fi
        done
        choice_hint "${options[selected - 1]}"
        rc=0; key=''; digit=''; DARBAN_INT=0
        IFS= read -rsn1 -t "$IDLE_TIMEOUT" key || rc=$?
        if (( DARBAN_INT )); then answer=cancel
        elif (( rc > 128 )); then ui_restore; idle_exit
        elif (( rc != 0 )); then answer=cancel
        else
            for i in 1 2 3 4 5 6 7 8 9; do
                if [[ $key == "$i" || $key == "${FA_DIGITS[i]}" || $key == "${AR_DIGITS[i]}" ]]; then digit=$i; fi
            done
            case $key in
                '') answer=$selected ;;
                $'\t') selected=$(( selected % n + 1 )) ;;
                $'\x04') answer=cancel ;;
                $'\e')
                    rest=''
                    IFS= read -rsn2 -t 0.05 rest || true
                    case $rest in
                        '') answer=cancel ;;
                        '[A'|OA) if (( selected > 1 )); then selected=$((selected - 1)); fi ;;
                        '[B'|OB) if (( selected < n )); then selected=$((selected + 1)); fi ;;
                    esac ;;
            esac
            if [[ -n $digit ]] && (( digit <= n )); then selected=$digit; fi
        fi
        printf '\e[%dA\r' $((n + 3)) || true
    done
    printf '\e[J' || true
    ui_restore
    if [[ $answer == cancel ]]; then return 1; fi
    CHOSEN=$answer
    printf ' %s%s %s%s\n' "$C_CYAN" "$S_POINTER" "${options[answer - 1]}" "$C_RESET" || true
}
pause() {
    if (( UI_TTY )); then ask "${C_DIM}Press Enter to return to the menu${S_ELL}${C_RESET}" || true; fi
}
no_pause() { exit "$RC_NO_PAUSE"; }
