#!/usr/bin/env bash
# The tool itself: updates, the way back, about, and removing it.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

valid_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; }
version_is_newer() {
    # version_is_newer A B: true when A is newer. sort -V alone would put 1.0.0-rc.1 after 1.0.0.
    local a=$1 b=$2 base_a=${1%%-*} base_b=${2%%-*}
    [[ $a != "$b" ]] || return 1
    if [[ $base_a != "$base_b" ]]; then
        [[ $(printf '%s\n%s\n' "$base_a" "$base_b" | sort -V | tail -n 1) == "$base_a" ]]
        return
    fi
    # The same base: a final release is newer than any pre-release of it.
    if [[ $a == "$base_a" ]]; then return 0; fi
    if [[ $b == "$base_b" ]]; then return 1; fi
    [[ $(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1) == "$a" ]]
}
release_fetch() {
    # release_fetch <url> <header file>: the body, or curl's code. The headers tell why GitHub refused.
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 20 -D "$2" "$1"
}
latest_release_version() {
    # latest_release_version [header file]: a final version is offered only final versions. A test version
    # follows test versions too, so a release candidate can be updated to the next one, and then to the final one.
    local headers=${1:-/dev/null}
    if [[ $DARBAN_VERSION == *-* ]]; then newest_release_version "$headers"; return; fi
    release_fetch "$DARBAN_URL/releases/latest/download/VERSION" "$headers"
}
newest_release_version() {
    # The highest version among the published releases, test versions included. GitHub lists no drafts here.
    local list tag newest=''
    list=$(release_fetch "https://api.github.com/repos/$DARBAN_REPO/releases?per_page=20" "${1:-/dev/null}") || return
    while IFS= read -r tag; do
        tag=${tag#v}
        valid_version "$tag" || continue
        if [[ -z $newest ]] || version_is_newer "$tag" "$newest"; then newest=$tag; fi
    done < <(grep -o '"tag_name": *"v[^"]*"' <<<"$list" | sed 's/^.*"\(v[^"]*\)"$/\1/')
    [[ -n $newest ]] || return 22
    printf '%s\n' "$newest"
}
github_wait() {
    # github_wait <header file>: the seconds GitHub asked to wait, when it refused because of its limit. That
    # limit counts every program on this server's address that has no token, the VPN clients' traffic included.
    [[ -s $1 ]] || return 0
    tr -d '\r' <"$1" | awk -v now="$(date -u +%s)" '
        /^HTTP\// { status = $2; after = ""; reset = ""; left = "" }
        tolower($1) == "retry-after:" { after = $2 }
        tolower($1) == "x-ratelimit-reset:" { reset = $2 }
        tolower($1) == "x-ratelimit-remaining:" { left = $2 }
        END {
            if (status != 429 && !(status == 403 && (after != "" || left == "0"))) exit
            if (after ~ /^[0-9]+$/) print after + 0
            else if (reset ~ /^[0-9]+$/ && reset + 0 > now + 0) print reset - now
            else print 60
        }'
}
update_record_success() {
    [[ $UPDATE_CHECK == yes ]] || return 0
    local temp
    temp=$(mktemp "$UPDATE_CACHE.XXXXXX") || return 1
    if printf '%s\n' "$1" >"$temp" && mv -f -- "$temp" "$UPDATE_CACHE"; then rm -f -- "$UPDATE_FAILED"; return 0; fi
    rm -f -- "$temp"
    return 1
}
update_record_failure() {
    # update_record_failure <seconds until the next try> <reason>: the version known before stays.
    [[ $UPDATE_CHECK == yes ]] || return 0
    printf '%s %s\n' "$(( $(date -u +%s) + $1 ))" "$2" >"$UPDATE_FAILED" 2>/dev/null || true
}
check_release() {
    # Asks GitHub for the newest release and remembers the answer. RELEASE_STATE is new, current, none (no
    # release for this channel yet), limited (GitHub asked to wait RELEASE_WAIT seconds), offline, or bad.
    local headers rc=0
    RELEASE_LATEST='' RELEASE_WAIT=0 RELEASE_STATE=offline
    headers=$(mktemp) || return 1
    # curl's own error line would read like a failure, and the caller says what it means.
    RELEASE_LATEST=$(latest_release_version "$headers" 2>/dev/null) || rc=$?
    RELEASE_WAIT=$(github_wait "$headers")
    rm -f -- "$headers"
    if [[ -n $RELEASE_WAIT ]]; then
        RELEASE_STATE=limited
        update_record_failure "$(( RELEASE_WAIT > UPDATE_RETRY ? RELEASE_WAIT : UPDATE_RETRY ))" limited
        return 1
    fi
    RELEASE_WAIT=0
    # curl reports an HTTP error as 22: GitHub answered, and no release for this channel is there.
    if (( rc == 22 )); then RELEASE_STATE=none; update_record_success "$DARBAN_VERSION"; return 0; fi
    if (( rc != 0 )); then update_record_failure "$UPDATE_RETRY" offline; return 1; fi
    if ! valid_version "$RELEASE_LATEST"; then RELEASE_STATE=bad; update_record_failure "$UPDATE_RETRY" bad; return 1; fi
    update_record_success "$RELEASE_LATEST"
    if version_is_newer "$RELEASE_LATEST" "$DARBAN_VERSION"; then RELEASE_STATE=new; else RELEASE_STATE=current; fi
}
update_check_due() {
    local now next='' reason='' checked
    now=$(date -u +%s)
    if [[ -s $UPDATE_FAILED ]]; then
        read -r next reason <"$UPDATE_FAILED" || true
        # A damaged record, or one written while the clock was wrong, never stops the checks for long.
        if [[ $next =~ ^[0-9]+$ ]] && (( now < next && next - now <= 2 * UPDATE_EVERY )); then return 1; fi
        return 0
    fi
    checked=$(stat -c %Y -- "$UPDATE_CACHE" 2>/dev/null) || return 0
    (( now - checked >= UPDATE_EVERY || checked > now ))
}
start_update_check() {
    # In the background, when the menu starts and the last check is older than an hour, or a failed one is
    # due again. One check at a time, even with two menus open.
    UPDATE_PID=''
    [[ $UPDATE_CHECK == yes ]] || return 0
    command -v curl >/dev/null || return 0
    update_check_due || return 0
    (
        if ! mkdir -- "$UPDATE_LOCK" 2>/dev/null; then
            # A lock left by a check that was killed is old: a running check takes about 20 seconds at most.
            [[ -n $(find "$UPDATE_LOCK" -maxdepth 0 -mmin +2 2>/dev/null) ]] || exit 0
            touch -- "$UPDATE_LOCK" || exit 0
        fi
        trap 'rmdir -- "$UPDATE_LOCK" 2>/dev/null' EXIT
        check_release
    ) >/dev/null 2>&1 </dev/null &
    UPDATE_PID=$!
    disown
}
wait_for_update_check() {
    # The first screen waits up to two seconds, so a release found now is shown at once. Without internet, it
    # waits only when a failed check is due again.
    local tries=20
    [[ -n ${UPDATE_PID:-} ]] || return 0
    while (( tries-- > 0 )) && kill -0 "$UPDATE_PID" 2>/dev/null; do sleep 0.1; done
}
update_check_running() { [[ -n ${UPDATE_PID:-} ]] && kill -0 "$UPDATE_PID" 2>/dev/null; }
available_update() {
    # Prints a newer version known from the last check that worked; nothing otherwise.
    local cached=''
    [[ $UPDATE_CHECK == yes && -s $UPDATE_CACHE ]] || return 0
    IFS= read -r cached <"$UPDATE_CACHE" || true
    if valid_version "$cached" && version_is_newer "$cached" "$DARBAN_VERSION"; then printf '%s\n' "$cached"; fi
}
update_summary() {
    # One of four: the notice is off, a new version, up to date, or not known (never checked, or the last
    # check failed).
    local e checked next='' reason=''
    if [[ $UPDATE_CHECK != yes ]]; then printf 'notice off\n'; return; fi
    if e=$(available_update) && [[ -n $e ]]; then printf 'v%s is available\n' "$e"; return; fi
    if [[ -s $UPDATE_FAILED ]]; then
        read -r next reason <"$UPDATE_FAILED" || true
        case $reason in
            limited) e='GitHub asked this server to wait' ;;
            bad) e='the release did not state a version' ;;
            *) e='GitHub could not be reached' ;;
        esac
        if [[ $next =~ ^[0-9]+$ ]]; then e+=", next try $(date -u -d "@$next" '+%H:%M UTC')"; fi
        if [[ -s $UPDATE_CACHE ]] && checked=$(stat -c %Y -- "$UPDATE_CACHE" 2>/dev/null); then
            e+="; up to date on $(date -u -d "@$checked" '+%Y-%m-%d')"
        fi
        printf 'not checked: %s\n' "$e"
        return
    fi
    if [[ -s $UPDATE_CACHE ]] && checked=$(stat -c %Y -- "$UPDATE_CACHE" 2>/dev/null); then
        printf 'up to date, checked %s\n' "$(date -u -d "@$checked" '+%Y-%m-%d %H:%M UTC')"
        return
    fi
    printf 'not checked yet\n'
}
show_release_notes() {
    # Escape sequences are removed: this text comes from the network and goes straight to a root terminal.
    local notes
    notes=$(curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 20 "$DARBAN_URL/releases/download/v$1/RELEASE-NOTES.txt" 2>/dev/null | LC_ALL=C tr -d '\000-\010\013-\037\177') || notes=''
    say
    if [[ -n $notes ]]; then
        printf '%sWhat is new in v%s:%s\n' "$C_BOLD" "$1" "$C_RESET" || true
        printf '%s\n' "$notes" | head -n 25
    else
        info "Release notes: $DARBAN_URL/releases/tag/v$1"
    fi
}
update_tool() {
    local latest
    command -v curl >/dev/null || { fail 'curl is required to check for updates.'; return 1; }
    kv Installed "v$DARBAN_VERSION"
    info "Checking the latest release of $DARBAN_REPO${S_ELL}"
    # The answer is kept, so the menu's notice says the same as this check.
    check_release || true
    case $RELEASE_STATE in
        none)
            ok "v$DARBAN_VERSION is up to date. No stable release is published yet."
            info "Releases: $DARBAN_URL/releases"
            return 0 ;;
        limited)
            fail "GitHub asks this server to wait $(( (RELEASE_WAIT + 59) / 60 )) minutes before the next check. Its limit counts every program on this server's address, the VPN clients' traffic included."
            return 1 ;;
        offline) fail 'Could not reach GitHub. Check the internet connection of this server.'; return 1 ;;
        bad) fail 'The release does not state a valid version.'; return 1 ;;
    esac
    latest=$RELEASE_LATEST
    kv Latest "v$latest"
    if ! version_is_newer "$latest" "$DARBAN_VERSION"; then
        ok 'This is the latest version.'
        return 0
    fi
    show_release_notes "$latest"
    say
    if events_lines_on || events_blocker >/dev/null; then
        info 'Only this tool is replaced. OpenVPN is not restarted, and clients, the PKI and the CRL stay as they are.'
    else
        info 'Only this tool is replaced, and OpenVPN restarts once to turn on connection events: connected users drop for a few seconds and reconnect by themselves. Clients, the PKI and the CRL stay as they are.'
    fi
    say
    confirm_choice "Install v$latest now?" 'No, keep this version' "Install v$latest" caution "$latest" || { cancelled; return 0; }
    bash "$DARBAN_LIB/get.sh" --version "v$latest" || { fail 'The update failed. See the messages above.'; audit "update to v$latest failed"; return 1; }
    audit "updated: v$DARBAN_VERSION -> v$latest"
    say
    ok "Updated to v$latest. Start it again: $(cmd sudo darban)"
    exit "$RC_QUIT"
}
restore_previous() {
    # Backups are named by time, so the last one is what the latest update replaced.
    local newest='' dir version without_events=0 core_new=''
    if [[ -d $BACKUP_ROOT ]]; then
        for dir in "$BACKUP_ROOT"/*; do
            if [[ -f $dir/sbin/darban ]]; then newest=$dir; fi
        done
    fi
    if [[ -z $newest ]]; then info 'No previous version is stored on this server.'; return 0; fi
    version=$(awk -F= '$1=="DARBAN_VERSION" {print $2; exit}' "$newest/sbin/darban")
    kv Installed "v$DARBAN_VERSION"
    kv Previous "v${version:-unknown}"
    say
    info 'Only this tool is replaced. OpenVPN is not restarted, and clients, the PKI and the CRL stay as they are.'
    # A version without connection events: their units go first, by this version, which knows them.
    if events_units_installed && [[ ! -e $newest/units/darban-events.path ]]; then
        without_events=1
        info "v${version:-unknown} does not use connection events: a link then ends when it expires, or when its link service sees the connection."
        if events_lines_on; then
            info "These stay, so connections keep working: $EVENT_SCRIPT, and its lines in server.conf. To remove them $S_ARROW $(event_lines_removal)"
        fi
    fi
    say
    confirm_choice "Go back to v${version:-unknown}?" 'No, keep this version' 'Restore the previous version' caution restore || { cancelled; return 0; }
    ca_lock || return 1
    # Its darban-core, when it has one, runs once from a copy beside the installed one before anything changes: one
    # that does not run here leaves this version whole. A version without one leaves this one's, which it never runs.
    if [[ -e $newest/lib/darban-core ]]; then
        core_new=$(darban_core_stage "$newest/lib/darban-core" "$DARBAN_CORE" "$version") || { fail 'Nothing was changed.'; return 1; }
        darban_tmp_register "$core_new"
    fi
    critical_begin
    # The timer for the next kept file first: the version restored sets its own, if it knows one.
    systemctl stop darban-expire.timer >/dev/null 2>&1 || true
    if (( without_events )); then darban_events_units_remove "$UNIT_DIR"; audit 'connection events turned off for an older version'; fi
    # A version without the daily backup gets no unit that would call a command it does not have.
    if [[ ! -e $newest/units/darban-backup.service ]]; then rm -f -- "$UNIT_DIR/darban-backup.service"; fi
    # The same for the daily list of blocked destinations. The ranges stay in force in NAT, as they are now.
    if [[ ! -e $newest/units/darban-geo.service ]]; then
        systemctl disable --now darban-geo.timer >/dev/null 2>&1 || true
        rm -f -- "$UNIT_DIR/darban-geo.timer" "$UNIT_DIR/darban-geo.service"
    fi
    # The library, with the modules of the manager, before the manager that sources them.
    # darban-core by one rename, the copy that ran, never by a copy over the running file.
    find "$newest/lib" -mindepth 1 -maxdepth 1 ! -name darban-core -exec cp -a -t "$DARBAN_LIB/" -- {} + && darban_core_place "$core_new" "$DARBAN_CORE" && cp -a -- "$newest/sbin/." "$SBIN_DIR/" && cp -a -- "$newest/units/." "$UNIT_DIR/" || {
        critical_end
        urgent "The restore did not finish. The files are in $newest."
        return 1
    }
    systemctl daemon-reload
    rm -rf -- "$newest"
    critical_end
    audit "restored previous version: v$DARBAN_VERSION -> v${version:-unknown}"
    ok "Restored v${version:-unknown}. Start it again: $(cmd sudo darban)"
    exit "$RC_QUIT"
}
toggle_update_notice() {
    if [[ $UPDATE_CHECK == yes ]]; then UPDATE_CHECK=no; else UPDATE_CHECK=yes; fi
    save_config || { fail 'Could not save the setting.'; return 1; }
    if [[ $UPDATE_CHECK == yes ]]; then
        ok 'The menu now looks for a new release when it starts, at most once an hour. Nothing is installed without your confirmation.'
    else
        rm -f -- "$UPDATE_CACHE" "$UPDATE_FAILED"
        ok 'The menu no longer looks for new releases. "Check for updates" still works.'
    fi
}
about_text() {
    say "Darban OVPN v$DARBAN_VERSION"
    say 'OpenVPN server manager for Ubuntu 24.04 and 26.04'
    say
    say "  GitHub   $DARBAN_URL"
    say "  Email    $DARBAN_EMAIL"
    say '  License  MIT'
    say
    say 'Not affiliated with OpenVPN Inc.'
}
uninstall_tool() {
    local expiry=''
    if expiry=$(darban_crl_expiry_epoch "$DARBAN_CRL" 2>/dev/null); then expiry=$(date -u -d "@$expiry" +%Y-%m-%d); else expiry=unknown; fi
    printf '%sThis removes the tool, its menu and its daily CRL renewal.%s\n' "$C_BOLD" "$C_RESET"
    bullet 'OpenVPN, connected users, the PKI, the CRL and server.conf are not touched'
    bullet "$OUT_DIR and $CONFIG_DIR are kept"
    warn "Nothing will renew the CRL after this. It expires on $expiry; renew it yourself before then, or OpenVPN may refuse clients."
    say
    confirm_choice 'Uninstall Darban OVPN?' 'No, keep it' 'Uninstall' danger uninstall || { cancelled; return 0; }
    ca_lock || return 1
    audit 'tool uninstalled'
    bash "$DARBAN_LIB/uninstall.sh" --yes || { fail 'The uninstall did not finish. See the messages above.'; return 1; }
    exit "$RC_QUIT"
}
remove_everything() {
    local status
    local -a options=()
    if [[ ! -e $CONFIG_DIR/.server-setup-started ]]; then
        fail 'OpenVPN on this server was not set up by this tool, so it will not be removed. "Uninstall this tool only" is available.'
        return 1
    fi
    printf '%sThis permanently removes the tool, OpenVPN, the CA, every client certificate and every .ovpn file.%s\n' "$C_BOLD" "$C_RESET"
    bullet 'all VPN users are disconnected now'
    bullet 'every .ovpn file stops working for good, even if OpenVPN is installed again later'
    bullet 'a session reaching this server through this VPN ends too; use direct SSH'
    bullet 'packages are removed only if the setup added them and nothing else needs them'
    say
    # Option 1 is the safe default, so anything but an explicit "No backup" keeps one.
    if confirm_choice 'Keep a backup of the CA, configuration and profiles first?' 'Yes, keep a backup in /root' 'No backup' danger; then
        info 'No backup will be made.'
    else
        options+=(--backup)
    fi
    say
    # Let's Encrypt gives 5 certificates a week for one address, and deleting one does not give it back.
    if [[ -d $LE_DIR/live/$CERT_NAME ]]; then
        info "Let's Encrypt gives at most 5 certificates a week for the same address. A kept certificate is used again by a new install here, without a new request."
        if confirm_choice "Keep the Let's Encrypt certificate of the links?" 'Yes, keep it' 'Delete it' danger; then
            info 'The certificate will be deleted.'
        else
            options+=(--keep-certificate)
        fi
        say
    fi
    status=$(bash "$DARBAN_LIB/remove-server.sh" --kernel-status) || status=none
    case $status in
        running) info 'The Virtual HWE kernel stays: the system is running it now.' ;;
        removable)
            if confirm_choice 'Also remove the Virtual HWE kernel the setup installed?' 'No, keep it' 'Remove the kernel' danger; then
                options+=(--kernel)
            fi ;;
    esac
    say
    confirm_choice 'Remove everything now? This cannot be undone.' 'No, keep everything' 'Remove everything' danger remove-everything || { cancelled; return 0; }
    ca_lock || return 1
    audit 'removing the tool, OpenVPN, the CA and all profiles'
    bash "$DARBAN_LIB/remove-server.sh" --yes "${options[@]}" || { fail 'The removal did not finish. See the messages above.'; return 1; }
    exit "$RC_QUIT"
}
