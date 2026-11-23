#!/usr/bin/env bash
# The screens of the clients: the list, and links and files.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

list_menu() {
    list_clients
    (( UI_TTY && LIST_HIDDEN > 0 )) || return 0
    say
    confirm_choice 'Show revoked clients too?' 'No, back to the menu' "Show $LIST_HIDDEN revoked" normal || no_pause
    clear_screen
    section 'Clients, including revoked'
    LIST_ALL=1
    list_clients
}
links_and_files() {
    # Menu 6: the links still open and the profile files kept on the server. Choosing a row shows what can be
    # done with it; nothing is removed by its number alone.
    local meta name state expires now left i cn path serial label any_read=0
    local -a kinds=() refs=() names=() details=()
    # A file made before this version gets its record, and one whose time is up goes, as the five-minute check
    # would do: the list then shows only what is still there.
    if ca_lock; then sweep_files 2>/dev/null || true; expire_schedule 2>/dev/null || true; ca_unlock; fi
    now=$(date -u +%s)
    if [[ -d $LINK_DIR ]]; then
        for meta in "$LINK_DIR"/*.meta; do
            [[ -e $meta ]] || continue
            expires=$(awk -F= '$1=="expires" {print $2}' "$meta")
            if [[ ! $expires =~ ^[0-9]+$ ]] || (( expires <= now )); then
                links_locked rm -f -- "$meta" "${meta%.meta}.ovpn" "${meta%.meta}.url" || true
                continue
            fi
            name=$(awk -F= '$1=="name" {print $2}' "$meta")
            state=$(awk -F= '$1=="downloads" {print $2}' "$meta")
            if [[ $state =~ ^[1-9][0-9]*$ ]]; then state='downloaded'; else state='not downloaded yet'; fi
            left=$(time_left "$expires" "$now")
            kinds+=(link) refs+=("$meta") names+=("$name") details+=("$left left $S_SEP $state")
        done
    fi
    while IFS=$'\t' read -r cn _ _ serial; do
        if is_server_serial "$serial"; then continue; fi
        path=$(profile_path "$cn") || continue
        if share_record_read "$path"; then
            left="$(time_left "$SR_EXPIRES" "$now") left"
            label=$(kept_read_label "$cn")
            if [[ $label == "file read" ]]; then any_read=1; fi
            kinds+=(file) refs+=("$path") names+=("$cn") details+=("$left${label:+ $S_SEP $label}")
        else
            kinds+=(file) refs+=("$path") names+=("$cn") details+=("$path")
        fi
    done < <(client_effective_rows)
    info 'A link works until its time is up, or until the client connects.'
    info 'A file on the server goes the same way. At its time it is deleted within seconds as a rule, and by the next five-minute check at the latest.'
    if (( any_read )); then info 'file read: the file was read after it was made; Darban cannot tell by whom.'; fi
    say
    if (( ${#kinds[@]} == 0 )); then info 'No open links and no files on the server. Share a profile from menu 5.'; return 0; fi
    for i in "${!kinds[@]}"; do
        if [[ ${kinds[i]} == link ]] && { (( i == 0 )); }; then menu_group 'OPEN LINKS'; fi
        if [[ ${kinds[i]} == file ]] && { (( i == 0 )) || [[ ${kinds[i - 1]} == link ]]; }; then menu_group 'FILES ON THE SERVER'; fi
        printf '  %s%3d%s  %-20s %s\n' "$C_KEY" $((i + 1)) "$C_RESET" "$(safe_text "${names[i]}")" "${details[i]}"
    done
    say
    while :; do
        if ! ask 'Choose one to see what you can do (Enter = back): ' || [[ -z $REPLY ]]; then return 0; fi
        if [[ $REPLY =~ ^[0-9]+$ ]] && (( 10#$REPLY >= 1 && 10#$REPLY <= ${#kinds[@]} )); then break; fi
        warn "\"$REPLY\" is not in the list above."
    done
    i=$(( 10#$REPLY - 1 ))
    say
    if [[ ${kinds[i]} == link ]]; then link_actions "${refs[i]}" "${names[i]}"; else file_actions "${names[i]}"; fi
}
link_actions() {
    # link_actions <meta> <name>: show the link again, or cancel it.
    local meta=$1 name=$2 saved=${1%.meta}.url url='' locked=''
    if [[ -s $saved ]]; then { IFS= read -r url; IFS= read -r locked; } <"$saved" || true; fi
    if [[ -n $url ]]; then
        choose_one "The link for $name" 'Show the link again and copy it' 'Cancel the link' 'Back' || return 0
    else
        info 'This link was made by an earlier version, which did not keep it, so it cannot be shown again.'
        choose_one "The link for $name" 'Cancel the link' 'Back' || return 0
        CHOSEN=$(( CHOSEN + 1 ))
    fi
    case $CHOSEN in
        1)
            say
            if [[ $locked == password=yes ]]; then
                info 'The profile is locked with a password, which is not kept. Send it the way you noted it.'
            fi
            hr
            present_link "$url" '' "$(link_note)" ;;
        2)
            links_locked rm -f -- "$meta" "${meta%.meta}.ovpn" "$saved" || return 1
            audit "temporary link cancelled: $name"
            ok "Link for \"$(safe_text "$name")\" cancelled." ;;
    esac
}
file_actions() {
    # file_actions <name>: show the download commands again, or delete the file.
    local name=$1
    choose_one "The file for $name" 'Show the download commands and copy one' 'Delete the file' 'Back' || return 0
    case $CHOSEN in
        1) say; share_by_download "$name" ;;
        2) delete_server_copy "$name" ;;
    esac
}
